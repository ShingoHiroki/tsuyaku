import AVFoundation
import CoreMedia
import Foundation
import NaturalLanguage
import Speech
import WhisperKit

/// 文字起こしの途中経過・確定結果。同じ発言は同じ id で更新される
struct TranscriptEvent {
    let id: UUID
    let text: String
    let isFinal: Bool
    /// 話し終わった時刻（確定のときだけ）。遅延の計測に使う
    let speechEnd: Date?
}

typealias TranscriptHandler = (TranscriptEvent) -> Void

protocol LiveTranscriber: AnyObject {
    var engineName: String { get }
    func prepare() async throws
    func start(onEvent: @escaping TranscriptHandler) async throws
    /// 音声スレッドから呼ばれる
    func append(_ buffer: AVAudioPCMBuffer)
    func stop() async
    /// 話し始めと判断する音量（RMS）。自分で区切りを判断しないエンジンは nil
    var speechThreshold: Float? { get }
}

extension LiveTranscriber {
    var speechThreshold: Float? { nil }
}

enum ASREngine: String, CaseIterable, Identifiable {
    case apple = "Apple"
    case whisper = "WhisperKit"
    var id: String { rawValue }
}

/// 時刻の記録を、音声スレッドと結果を受け取るスレッドの間で安全に共有する
private final class Clock {
    private let lock = NSLock()
    private var first: Date?

    func markFirstAudio() {
        lock.lock()
        if first == nil { first = Date() }
        lock.unlock()
    }

    func wallTime(audioSeconds: Double) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        guard audioSeconds.isFinite else { return nil }
        return first?.addingTimeInterval(audioSeconds)
    }
}

// MARK: - Apple（SpeechAnalyzer / SpeechTranscriber）

final class AppleLiveTranscriber: LiveTranscriber {
    let engineName = "Apple"
    private let localeID: String
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var converter: BufferConverter?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private let clock = Clock()

    init(localeID: String) {
        self.localeID = localeID
    }

    func prepare() async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeID)) else {
            throw NSError(domain: "Tsuyaku", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(localeID) は Apple の音声認識で使えません"])
        }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw NSError(domain: "Tsuyaku", code: 2, userInfo: [NSLocalizedDescriptionKey: "音声形式を決められません"])
        }
        self.transcriber = transcriber
        self.converter = BufferConverter(outputFormat: format)
        self.analyzer = SpeechAnalyzer(modules: [transcriber])
    }

    func start(onEvent: @escaping TranscriptHandler) async throws {
        guard let transcriber, let analyzer else { return }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        let clock = self.clock
        resultsTask = Task {
            var currentID = UUID()
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespaces)
                    let end = result.isFinal ? clock.wallTime(audioSeconds: result.range.end.seconds) : nil
                    if !text.isEmpty {
                        onEvent(TranscriptEvent(id: currentID, text: text, isFinal: result.isFinal, speechEnd: end))
                    }
                    if result.isFinal { currentID = UUID() }
                }
            } catch {
                // 停止時に終わる
            }
        }
        try await analyzer.start(inputSequence: stream)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = converter?.convert(buffer) else { return }
        clock.markFirstAudio()
        continuation?.yield(AnalyzerInput(buffer: converted))
    }

    func stop() async {
        continuation?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        continuation = nil
    }
}

// MARK: - WhisperKit

/// WhisperKit のモデルは1つだけ読み込み、相手側・自分側で共有する（同時に動かすと M1 では重いため、処理は順番に行う）
actor WhisperService {
    static let shared = WhisperService()
    static let modelName = "large-v3-v20240930_626MB"
    /// モデルはリポジトリのルートの models/ に置く（ない場合は初回にダウンロードする）
    static let modelsDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("models")

    private var pipe: WhisperKit?
    /// 直前に受け付けた処理。actor は await の間に次の呼び出しを受け付けるため、これを待ってから始めて1件ずつにする
    private var tail: Task<Void, Never>?
    private var waiting = 0

    var isLoaded: Bool { pipe != nil }

    func load() async throws {
        if pipe != nil { return }
        let pipe = try await WhisperKit(WhisperKitConfig(model: Self.modelName, downloadBase: Self.modelsDir, verbose: false))
        // 最初の文字起こしのときに、macOS がニューラルエンジン用にモデルを変換する（このアプリでは初回だけ数分）。
        // 開始後に字幕が止まって見えないよう、準備の段階で1秒の無音を文字起こしして済ませておく
        let started = Date()
        DebugTrace.log("WhisperKit：試し書き起こし（初回はモデルの変換で数分かかる）")
        _ = try await pipe.transcribe(audioArray: [Float](repeating: 0, count: 16_000),
                                      decodeOptions: DecodingOptions(language: "en", detectLanguage: false, withoutTimestamps: true))
        DebugTrace.log(String(format: "WhisperKit：試し書き起こし完了（%.1f秒）", Date().timeIntervalSince(started)))
        self.pipe = pipe
    }

    func transcribe(_ samples: [Float], language: String) async throws -> String {
        guard let pipe else { return "" }
        let previous = tail
        waiting += 1
        let seconds = Double(samples.count) / 16_000
        DebugTrace.detail(String(format: "WhisperKit：受付（%@、%.1f秒分、待ち %d件）", language, seconds, waiting - 1))
        let job = Task { () throws -> String in
            await previous?.value
            let started = Date()
            let options = DecodingOptions(language: language, detectLanguage: false, skipSpecialTokens: true, withoutTimestamps: true)
            let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
            // 自信の低い文・同じ語の繰り返しが多い文は、雑音からの作り話（ハルシネーション）として捨てる（基準は調整の画面で変えられる）。
            // WhisperKit 1.1.1 は無音らしさ（noSpeechProb）を計算しないため使えない
            let tuning = WhisperTuning.current
            let segments = results.flatMap(\.segments)
            let kept = segments.filter {
                Double($0.avgLogprob) >= tuning.minAvgLogprob && Double($0.compressionRatio) <= tuning.maxCompressionRatio
            }
            let text = kept.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let scores = segments.map { String(format: "%.2f", $0.avgLogprob) }.joined(separator: " ")
            DebugTrace.detail(String(format: "WhisperKit：完了（%@、%.1f秒分を %.1f秒で処理、%d文字、文 %d/%d 件を採用、確からしさ %@）",
                                  language, seconds, Date().timeIntervalSince(started), text.count, kept.count, segments.count, scores))
            return text
        }
        tail = Task { _ = try? await job.value }
        defer { waiting -= 1 }
        do {
            return try await job.value
        } catch {
            DebugTrace.log("WhisperKit：失敗（\(error.localizedDescription)）")
            throw error
        }
    }
}

/// 無音で発言を区切り、区切りごとに WhisperKit で文字起こしする
final class WhisperLiveTranscriber: LiveTranscriber {
    let engineName = "WhisperKit"
    private let language: String
    private let converter = BufferConverter(
        outputFormat: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!)
    private let lock = NSLock()
    private var onEvent: TranscriptHandler?

    // 区切りの判定（音声スレッドだけが触る）
    private let sampleRate = 16_000.0
    // 発話とみなす音量（RMS）は、雑音の大きさの数倍にする（マイクごとの音量の違いに合わせるため。倍率と範囲は WhisperTuning）。
    // 実測：Bluetooth のイヤホンの通話用モードでは、声の最大が 0.007〜0.011 しかなく、固定の 0.01 では多くを取りこぼした
    private var noiseFloor: Float = 0.0034         // 最初は基準が 0.01 前後になる値から始め、静かになったらすぐ下げる
    private var threshold: Float = 0.01            // 音声スレッドで更新し、画面のスレッドから lock 越しに読む
    private let silenceToEnd = 0.7                 // この秒数だけ無音が続いたら区切る
    private let longSegment = 4.0                  // 発言がこの秒数を超えたら、
    private let shortSilence = 0.3                 // この秒数の息継ぎでも区切る（文と文の間で区切るため）
    private let maxSegment = 12.0                  // それでも長すぎる発言は、
    private let splitSearch = 4.0                  // 最後のこの秒数の中で一番静かな所で区切る
    private let preRoll = 0.3                      // 話し始めの直前も含める
    private var samples: [Float] = []
    /// samples の中の位置（その音の塊の終わり）ごとの音量。長い発言を静かな所で区切るために使う
    private var levels: [(end: Int, rms: Float)] = []
    private var preRollSamples: [Float] = []
    private var inSpeech = false
    private var silence = 0.0
    private var segmentID = UUID()

    // 誤った字幕（ハルシネーション）の捨て方は WhisperTuning（調整の画面で変えられ、保存するとすぐ反映される）。
    // 短い区切りの相づちは、本当に言ったものも捨てることになるが、訳さなくても話の筋は追えるため、誤った字幕を減らす方を選んだ
    /// 今の区切りの中で、基準を超えた音（声）の秒数
    private var voiced = 0.0

    init(language: String) {
        self.language = language
    }

    func prepare() async throws {
        try await WhisperService.shared.load()
    }

    func start(onEvent: @escaping TranscriptHandler) async throws {
        lock.lock()
        self.onEvent = onEvent
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = converter.convert(buffer), let data = converted.floatChannelData?[0] else { return }
        let chunk = Array(UnsafeBufferPointer(start: data, count: Int(converted.frameLength)))
        let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(max(chunk.count, 1)))
        let seconds = Double(chunk.count) / sampleRate

        // 雑音の大きさ：静かになったらすぐ下げ、上がるときはゆっくり上げる（話している間はさらにゆっくり）
        if rms < noiseFloor {
            noiseFloor = rms
        } else {
            let timeConstant: Float = inSpeech ? 60 : 5
            noiseFloor += (rms - noiseFloor) * min(1, Float(seconds) / timeConstant)
        }
        let tuning = WhisperTuning.current
        let speechThreshold = Float(min(tuning.thresholdMax, max(tuning.thresholdMin, Double(noiseFloor) * tuning.noiseFactor)))
        lock.lock()
        threshold = speechThreshold
        lock.unlock()

        if rms > speechThreshold {
            if !inSpeech {
                inSpeech = true
                segmentID = UUID()
                samples = preRollSamples
                levels = []
                voiced = 0
                emit(TranscriptEvent(id: segmentID, text: "（聞き取り中…）", isFinal: false, speechEnd: nil))
            }
            silence = 0
            voiced += seconds
            samples += chunk
            levels.append((samples.count, rms))
        } else if inSpeech {
            samples += chunk
            levels.append((samples.count, rms))
            silence += seconds
        } else {
            preRollSamples = Array((preRollSamples + chunk).suffix(Int(preRoll * sampleRate)))
        }
        guard inSpeech else { return }

        let length = Double(samples.count) / sampleRate
        if silence >= (length >= longSegment ? shortSilence : silenceToEnd) {
            finishSegment(samples, id: segmentID, speechEnd: Date().addingTimeInterval(-silence), voiced: voiced)
            inSpeech = false
            silence = 0
            samples = []
            levels = []
            preRollSamples = []
        } else if length >= maxSegment {
            splitAtQuietestPoint()
        }
    }

    /// 最大の長さに達した発言を、最後の数秒の中で一番静かな所で区切り、残りを次の区切りの頭にする
    private func splitAtQuietestPoint() {
        let searchFrom = samples.count - Int(splitSearch * sampleRate)
        let candidates = levels.filter { $0.end >= searchFrom && $0.end < samples.count }
        let cut = candidates.min { $0.rms < $1.rms }?.end ?? samples.count
        let rest = Array(samples[cut...])
        // 最大の長さに達するのは話し続けているときなので、声の時間は足りているものとして扱う
        finishSegment(Array(samples[..<cut]), id: segmentID, speechEnd: Date().addingTimeInterval(-Double(rest.count) / sampleRate),
                      voiced: maxSegment)
        voiced = 0

        segmentID = UUID()
        samples = rest
        levels = levels.filter { $0.end > cut }.map { ($0.end - cut, $0.rms) }
        emit(TranscriptEvent(id: segmentID, text: "（聞き取り中…）", isFinal: false, speechEnd: nil))
    }

    private func finishSegment(_ segment: [Float], id: UUID, speechEnd: Date, voiced: Double) {
        // 声の時間が短すぎる区切り（物音・息など）は、文字起こしせずに捨てる（WhisperKit の順番待ちも減らす）
        let tuning = WhisperTuning.current
        if voiced < tuning.minVoiced {
            emit(TranscriptEvent(id: id, text: "", isFinal: true, speechEnd: speechEnd))
            return
        }
        let language = self.language
        let isShort = Double(segment.count) / sampleRate < tuning.shortSegment
        Task { [weak self] in
            let text = (try? await WhisperService.shared.transcribe(segment, language: language)) ?? ""
            // 文字起こしを待つ間に保存された調整も使う
            let tuning = WhisperTuning.current
            let bare = WhisperTuning.normalize(text)
            let isNoise = text.isEmpty
                || tuning.hallucinationPhrases.contains { !$0.isEmpty && text.localizedCaseInsensitiveContains($0) }
                || (isShort && tuning.shortPhrases.contains { WhisperTuning.normalize($0) == bare })
            if isNoise && !text.isEmpty { DebugTrace.detail("WhisperKit：決まり文句のため捨てた（\(language)）") }
            self?.emit(TranscriptEvent(id: id, text: isNoise ? "" : text, isFinal: true, speechEnd: speechEnd))
        }
    }

    var speechThreshold: Float? {
        lock.lock()
        defer { lock.unlock() }
        return threshold
    }

    private func emit(_ event: TranscriptEvent) {
        lock.lock()
        let handler = onEvent
        lock.unlock()
        handler?(event)
    }

    func stop() async {
        lock.lock()
        onEvent = nil
        lock.unlock()
    }
}

/// 文字起こしされた文の言語（"ja" または "en"）。判定できなければ fallback を返す
func detectTextLanguage(_ text: String, fallback: String) -> String {
    let recognizer = NLLanguageRecognizer()
    recognizer.languageConstraints = [.japanese, .english]
    recognizer.processString(text)
    switch recognizer.dominantLanguage {
    case .japanese: return "ja"
    case .english: return "en"
    default: return fallback
    }
}
