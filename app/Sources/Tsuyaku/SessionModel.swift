import AppKit
import AVFoundation
import Foundation
import SwiftUI

enum Side: String {
    case remote = "相手"
    case me = "自分"
}

/// 画面の音量のバー（0〜1 は -60dB〜0dB）
struct LevelMeter {
    var level: Double = 0
    /// 話し始めと判断する音量の位置（WhisperKit のとき）
    var threshold: Double?
    /// 話している（音が出ている）と判断しているか
    var active = false

    static func position(_ rms: Float) -> Double {
        let db = 20 * log10(Double(max(rms, 0.00001)))
        return min(1, max(0, (db + 60) / 60))
    }
}

struct Entry: Identifiable {
    let id: UUID
    let side: Side
    let engine: String
    let time: Date
    var original: String
    var isFinal: Bool
    var language: String?
    var translation: String?
    /// 訳した翻訳エンジン
    var translator: String?
    /// 話し終わってから原文が確定するまで
    var recognitionLatency: Double?
    /// 話し終わってから訳文が出るまで（目標は1〜3秒）
    var totalLatency: Double?
}

/// 会議1回分の取り込み → 文字起こし → 翻訳 → 表示をまとめる
@MainActor
final class SessionModel: ObservableObject {
    @Published var meetingApp: MeetingApp = .chrome
    @Published var remoteEngine: ASREngine = .apple
    @Published var meEngine: ASREngine = .whisper
    /// 相手が話す言語（Apple の音声認識の地域を含む）。日本語なら、相手の発言を英語に訳す
    @Published var remoteLocale = "en-US"
    /// 既定は PLaMo 2B（速さ・メモリ・訳の質のつり合いがよいため）
    @Published var translationEngine: TranslationEngine = .plamo2
    @Published var useMic = true
    /// 使うマイクの UID。空ならシステムの設定に従う。次に起動したときも使うため覚えておく
    @Published var selectedInputUID: String = UserDefaults.standard.string(forKey: "selectedInputUID") ?? "" {
        didSet { UserDefaults.standard.set(selectedInputUID, forKey: "selectedInputUID") }
    }
    @Published var saveRecord = false
    @Published var toldParticipants = false

    @Published private(set) var inputDevices: [AudioDevice] = []
    @Published private(set) var outputDevices: [AudioDevice] = []
    /// macOS で今選ばれている出力
    @Published private(set) var currentOutput: AudioDevice?

    @Published private(set) var isRunning = false
    @Published private(set) var isBusy = false
    @Published private(set) var status = "停止中"
    @Published private(set) var translationStatus = "確認中…"
    @Published private(set) var translationReady = false
    @Published private(set) var entries: [Entry] = []
    @Published var lastError: String?
    @Published private(set) var remoteMeter = LevelMeter()
    @Published private(set) var meMeter = LevelMeter()

    static let remoteLocales: [(id: String, label: String)] = [
        ("en-US", "英語（米国）"), ("en-IN", "英語（インド）"), ("en-GB", "英語（英国）"), ("en-AU", "英語（オーストラリア）"),
        ("ja-JP", "日本語"),
    ]
    /// 相手が話す言語の2文字の記号（en / ja）
    private var remoteLanguage: String { remoteLocale.hasPrefix("ja") ? "ja" : "en" }

    private let translator = TranslatorService()
    private var tap: ProcessTapSource?
    private var mic: MicSource?
    /// 30秒ごとの集計（届いた音の量と、確定・捨てた件数。話した内容は持たない）
    private let remoteStats = AudioStats()
    private let meStats = AudioStats()
    private var statsTask: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?
    private var remoteASR: LiveTranscriber?
    private var meASR: LiveTranscriber?
    private var startedAt = Date()
    private var savingThisSession = false
    private var deviceWatcher: AudioDeviceWatcher?
    private var deviceSummary = ""
    /// 取り込み中の会議アプリのプロセスと、時計役にしている出力（出力が変わったら取り込みを始め直すため）
    private var tapProcessIDs: [AudioObjectID] = []
    private var tapOutputID: AudioDeviceID?
    /// 相手側の取り込みを始めたときの出力の装置のサンプリング周波数
    private var tapOutputRate: Double?
    /// 今の出力の装置のサンプリング周波数
    private var outputRate: Double?
    private var isRestartingTap = false
    private var runningStatus = ""

    init() {
        refreshDevices()
        deviceWatcher = AudioDeviceWatcher { [weak self] in
            Task { @MainActor in await self?.devicesChanged() }
        }
        deviceWatcher?.watchDataSources(of: outputDevices)
        deviceWatcher?.watchSampleRate(of: currentOutput?.id)
    }

    /// 「相手に伝えた」を確認したときだけ保存できる
    var willSave: Bool { saveRecord && toldParticipants }

    // MARK: - 装置（マイク・出力）

    /// スピーカーから音が出ているときの警告（相手の声がマイクに入り、自分側に誤った字幕が出るため）
    var outputWarning: String? {
        guard useMic, currentOutput?.isLikelySpeaker == true else { return nil }
        return "スピーカーから音が出ています。相手の声がマイクに入るので、イヤホンに切り替えてください"
    }

    /// 選んだマイクが今つながっていないとき true（システムの設定のマイクを使う）
    var selectedInputMissing: Bool {
        !selectedInputUID.isEmpty && !inputDevices.contains { $0.uid == selectedInputUID }
    }

    /// macOS 全体の出力を切り替える。取り込み中なら、装置の見張りが気づいて相手側の取り込みを始め直す
    func selectOutput(uid: String) {
        guard let device = outputDevices.first(where: { $0.uid == uid }), device.id != currentOutput?.id else { return }
        do {
            try AudioDevices.setDefaultOutput(device.id)
            DebugTrace.log("出力を切り替えた（種類：\(device.kind)）")
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func refreshDevices() {
        inputDevices = AudioDevices.list(input: true)
        outputDevices = AudioDevices.list(input: false)
        let outputID = AudioDevices.defaultDevice(input: false)
        currentOutput = outputDevices.first { $0.id == outputID }
        outputRate = currentOutput.flatMap { AudioDevices.sampleRate($0.id) }
        // 装置の名前は書かない（持ち主の名前が入ることがあるため）
        let rate = outputRate.map { "・\(Int($0))Hz" } ?? ""
        let summary = "装置：入力 \(inputDevices.count)件・出力 \(outputDevices.count)件、今の出力の種類：\(currentOutput?.kind ?? "不明")\(rate)"
        if summary != deviceSummary {
            deviceSummary = summary
            DebugTrace.log(summary)
        }
    }

    private func devicesChanged() async {
        refreshDevices()
        deviceWatcher?.watchDataSources(of: outputDevices)
        deviceWatcher?.watchSampleRate(of: currentOutput?.id)
        // 出力の装置が変わったときと、同じ装置でも形式が変わったとき（Bluetooth のイヤホンが通話用のモードになったときなど）、
        // 取り込みは始めたときの形式のままなので、始め直す
        if isRunning, !isBusy, let output = currentOutput, output.id != tapOutputID || outputRate != tapOutputRate {
            await restartTap()
        }
    }

    /// 出力の装置や形式が変わったとき、相手側の取り込みを今の出力に合わせて始め直す
    private func restartTap() async {
        guard !isRestartingTap, let remote = remoteASR else { return }
        // 始め直しの途中で停止されると取り込みが残るため、その間はほかの操作を受け付けない
        isRestartingTap = true
        isBusy = true
        defer {
            isRestartingTap = false
            isBusy = false
        }
        DebugTrace.log("出力の装置または形式が変わったため、相手側の取り込みを始め直す")
        status = "出力の切り替えに合わせて、相手側の取り込みを始め直しています…" + Self.permissionHint
        let oldTap = tap
        tap = nil
        await Task.detached { oldTap?.stop() }.value
        let newTap = ProcessTapSource()
        let objectIDs = tapProcessIDs
        let remoteStats = self.remoteStats
        // 始める前の装置と周波数を覚える（始めている途中に変わったら、終わったあとの確認で始め直せるように）
        let outputID = AudioDevices.defaultDevice(input: false)
        let outputRate = outputID.flatMap { AudioDevices.sampleRate($0) }
        do {
            try await Task.detached {
                try newTap.start(processObjectIDs: objectIDs) { buffer in
                    remoteStats.add(buffer)
                    remote.append(buffer)
                }
            }.value
            tap = newTap
            tapOutputID = outputID
            tapOutputRate = outputRate
            DebugTrace.log("相手側の取り込みを始め直した（\(newTap.formatSummary)）")
            status = runningStatus
            Task { [weak self] in await self?.devicesChanged() }
        } catch {
            lastError = "出力の切り替え後に相手側の取り込みを始め直せませんでした：\(error.localizedDescription)。停止して開始し直してください"
            DebugTrace.log("相手側の取り込みの始め直しに失敗：\(error.localizedDescription)")
        }
    }

    /// 選んでいる翻訳エンジンの準備をする（起動時と、エンジンを切り替えたとき）
    func refreshTranslation() async {
        var engine: TranslationEngine
        var problems: [String]
        // 準備の間に別のエンジンに切り替えられたら、今選ばれているもので準備し直す
        repeat {
            engine = translationEngine
            DebugTrace.log("翻訳（\(engine.rawValue)）の準備中")
            translationReady = false
            translationStatus = engine == .apple ? "確認中…" : "\(engine.rawValue) を起動中…（数秒〜数十秒）"
            problems = await translator.prepare(engine)
        } while engine != translationEngine
        DebugTrace.log("翻訳（\(engine.rawValue)）：\(problems.isEmpty ? "準備済み" : problems.joined(separator: "・"))")
        translationReady = problems.isEmpty
        translationStatus = problems.isEmpty ? "\(engine.rawValue)（準備済み）" : problems.joined(separator: "・")
    }

    func shutdown() {
        translator.shutdown()
    }

    func start() async {
        guard !isRunning, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        lastError = nil
        entries = []
        startedAt = Date()
        savingThisSession = willSave
        do {
            let processes = try meetingApp.matchingProcesses()
            DebugTrace.log("開始：対象のプロセス \(processes.count)件")
            if meetingApp != .system && processes.isEmpty {
                throw NSError(domain: "Tsuyaku", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "\(meetingApp.rawValue) の音声のプロセスが見つかりません。会議に参加して音が出ている状態で開始してください"])
            }
            if useMic {
                DebugTrace.log("マイクの権限を確認中（現在：\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)）")
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    throw NSError(domain: "Tsuyaku", code: 4, userInfo: [
                        NSLocalizedDescriptionKey: "マイクの権限がありません（システム設定 → プライバシーとセキュリティ → マイク）"])
                }
                DebugTrace.log("マイクの権限：許可")
            }

            status = "準備中…（WhisperKit は初回とアプリを作り直した後に、モデルの準備で数分かかることがあります）"
            let remote = makeTranscriber(remoteEngine, side: .remote)
            DebugTrace.log("相手側（\(remote.engineName)）の準備中")
            try await remote.prepare()
            let me = useMic ? makeTranscriber(meEngine, side: .me) : nil
            if let me {
                DebugTrace.log("自分側（\(me.engineName)）の準備中")
                try await me.prepare()
            }

            DebugTrace.log("相手側の認識を開始中")
            try await remote.start { [weak self] event in
                Task { @MainActor in self?.handle(event, side: .remote, engine: remote.engineName) }
            }
            if let me {
                DebugTrace.log("自分側の認識を開始中")
                try await me.start { [weak self] event in
                    Task { @MainActor in self?.handle(event, side: .me, engine: me.engineName) }
                }
            }
            remoteASR = remote
            meASR = me

            // マイクを先に開く（Bluetooth のイヤホンはマイクを開くと出力の形式も変わるため、相手側の取り込みはそのあとに始める）
            if let me {
                // 選んだマイクが抜かれていたら、システムの設定のマイクを使う
                let micDevice = inputDevices.first { $0.uid == selectedInputUID }
                if selectedInputMissing {
                    lastError = "選んだマイクが見つからないため、システムの設定のマイクを使います"
                }
                DebugTrace.log("マイク：\(micDevice.map { "選んだ装置（種類：\($0.kind)）" } ?? "システムの設定")")
                let mic = MicSource()
                let meStats = self.meStats
                try mic.start(deviceID: micDevice?.id) { buffer in
                    meStats.add(buffer)
                    me.append(buffer)
                }
                self.mic = mic
                DebugTrace.log("マイクの形式：\(mic.formatSummary)")
            }
            DebugTrace.log("音声の取り込みを開始中")
            status = "音声の取り込みを開始中…" + Self.permissionHint
            // 許可の確認への答えを最大90秒待つことがあるため、画面が固まらないよう別のスレッドで始める
            let tap = ProcessTapSource()
            let objectIDs = processes.map(\.objectID)
            let tapStarted = Date()
            // 始める前の装置と周波数を覚える（始めている途中に変わったら、終わったあとの確認で始め直せるように）
            let outputID = AudioDevices.defaultDevice(input: false)
            let outputRate = outputID.flatMap { AudioDevices.sampleRate($0) }
            let remoteStats = self.remoteStats
            try await Task.detached {
                try tap.start(processObjectIDs: objectIDs) { buffer in
                    remoteStats.add(buffer)
                    remote.append(buffer)
                }
            }.value
            self.tap = tap
            tapProcessIDs = objectIDs
            tapOutputID = outputID
            tapOutputRate = outputRate
            DebugTrace.log("相手側の形式：\(tap.formatSummary)")
            if Date().timeIntervalSince(tapStarted) >= Self.permissionTimeout {
                lastError = "許可の確認に答えがなかったため、相手側の音声が取れていない可能性があります。確認の画面で「許可」を押してから、停止して開始し直してください"
            }

            DebugTrace.log("取り込み中")
            isRunning = true
            let targets = processes.isEmpty ? "システム全体" : "\(meetingApp.rawValue)（\(processes.count)プロセス）"
            runningStatus = "取り込み中：\(targets)" + (savingThisSession ? "／字幕を保存します" : "／保存しません")
            status = runningStatus
            // 開始の途中で出力の装置や形式が変わっていたら（マイクを開いたことによる切り替えなど）、ここで気づいて始め直す
            Task { [weak self] in await self?.devicesChanged() }
            startStats()
            startMeters()
        } catch {
            lastError = error.localizedDescription
            DebugTrace.log("開始に失敗：\(error.localizedDescription)")
            await teardown()
            status = "停止中"
        }
    }

    func stop() async {
        guard isRunning, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        await teardown()
        status = "停止中"
        if savingThisSession { writeRecord() }
    }

    /// 音声の取り込みの開始・停止のとき、macOS がシステムオーディオの録音の許可の確認に答えるのを待つことがある。
    /// 確認の画面がほかのウィンドウに隠れて気づけないことがあるため、待っている間に案内する
    private static let permissionHint = "（「システムオーディオの録音」の許可の確認が出ていたら「許可」を押してください。答えないと最大90秒待ちます）"
    /// macOS が答えを待つ上限（実測で約90秒）。これに近い時間がかかったら、答えがなかったとみなす
    private static let permissionTimeout = 85.0

    private func teardown() async {
        DebugTrace.log("停止中：音声の取り込みを止める")
        statsTask?.cancel()
        statsTask = nil
        meterTask?.cancel()
        meterTask = nil
        remoteMeter = LevelMeter()
        meMeter = LevelMeter()
        let tap = self.tap
        let mic = self.mic
        self.tap = nil
        self.mic = nil
        tapOutputID = nil
        tapOutputRate = nil
        if tap != nil { status = "停止中…" + Self.permissionHint }
        await Task.detached {
            tap?.stop()
            mic?.stop()
        }.value
        DebugTrace.log("停止中：相手側の認識を止める")
        await remoteASR?.stop()
        DebugTrace.log("停止中：自分側の認識を止める")
        await meASR?.stop()
        remoteASR = nil
        meASR = nil
        isRunning = false
        DebugTrace.log("停止しました")
    }

    private func makeTranscriber(_ engine: ASREngine, side: Side) -> LiveTranscriber {
        switch (engine, side) {
        case (.apple, .remote): AppleLiveTranscriber(localeID: remoteLocale)
        case (.apple, .me): AppleLiveTranscriber(localeID: "ja-JP")
        // 実測では、自分側は日本語の指定のままでも、英語の発言を英文で書き出せた
        case (.whisper, .remote): WhisperLiveTranscriber(language: remoteLanguage)
        case (.whisper, .me): WhisperLiveTranscriber(language: "ja")
        }
    }

    // MARK: - 結果の受け取り

    /// 30秒ごとに、届いた音の量と確定・捨てた件数を記録する（マイクの音が届いていないのか、届いているのに捨てられているのかを見分けるため）
    private func startStats() {
        _ = remoteStats.take()
        _ = meStats.take()
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self else { return }
                let me = meASR.map { Self.describe(meStats.take(), threshold: $0.speechThreshold) } ?? "マイクなし"
                let remote = Self.describe(remoteStats.take(), threshold: remoteASR?.speechThreshold)
                DebugTrace.log("30秒の集計：相手 \(remote)／自分 \(me)")
            }
        }
    }

    /// 0.1秒ごとに、直近の音量を画面のバーに反映する
    private func startMeters() {
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                remoteMeter = Self.meter(remoteStats.takeRecentLevel(), threshold: remoteASR?.speechThreshold)
                meMeter = meASR == nil ? LevelMeter() : Self.meter(meStats.takeRecentLevel(), threshold: meASR?.speechThreshold)
            }
        }
    }

    /// 区切りを自分で判断しないエンジン（Apple）は、0.01 を超えたら音が出ているとみなす
    private static func meter(_ rms: Float, threshold: Float?) -> LevelMeter {
        LevelMeter(level: LevelMeter.position(rms), threshold: threshold.map { LevelMeter.position($0) },
                   active: rms > (threshold ?? 0.01))
    }

    private static func describe(_ s: AudioStats.Snapshot, threshold: Float?) -> String {
        String(format: "音声 %.0f秒・最大音量 %.3f・確定 %d件・捨てた %d件", s.seconds, s.maxLevel, s.shown, s.dropped)
            + (threshold.map { String(format: "・話し始めの基準 %.3f", $0) } ?? "")
    }

    private func handle(_ event: TranscriptEvent, side: Side, engine: String) {
        if event.isFinal {
            (side == .remote ? remoteStats : meStats).countFinal(dropped: event.text.isEmpty)
        }
        if let i = entries.firstIndex(where: { $0.id == event.id }) {
            if event.isFinal && event.text.isEmpty {
                entries.remove(at: i)
                return
            }
            entries[i].original = event.text
            entries[i].isFinal = event.isFinal
        } else {
            guard !event.text.isEmpty else { return }
            entries.append(Entry(id: event.id, side: side, engine: engine, time: Date(), original: event.text, isFinal: event.isFinal))
        }
        if event.isFinal { translate(id: event.id, speechEnd: event.speechEnd) }
    }

    private func translate(id: UUID, speechEnd: Date?) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries[i]
        let finalizedAt = Date()
        // 書き出された文字の言語で、訳す向きを決める（自分が英語で話したときも正しく訳すため）
        let language = detectTextLanguage(entry.original, fallback: entry.side == .remote ? remoteLanguage : "ja")
        entries[i].language = language
        entries[i].recognitionLatency = speechEnd.map { finalizedAt.timeIntervalSince($0) }

        // 同じ向きで直前に訳し終えた2組を、話の流れとして渡す（PLaMo だけが使う）
        let history: [TranslationPair] = entries[..<i]
            .filter { $0.language == language && $0.translation != nil && $0.totalLatency != nil }
            .suffix(2)
            .map { ($0.original, $0.translation!) }
        let translatorName = translationEngine.rawValue

        Task {
            let started = Date()
            let translated: String?
            do {
                translated = try await translator.translate(entry.original, from: language, history: history)
            } catch {
                translated = "（翻訳に失敗：\(error.localizedDescription)）"
            }
            let done = Date()
            guard let j = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[j].translation = translated ?? "（翻訳の準備ができていません：\(translationStatus)）"
            entries[j].translator = translatorName
            entries[j].totalLatency = translated == nil ? nil : speechEnd.map { done.timeIntervalSince($0) }
            MetricsLog.append(
                side: entry.side.rawValue, engine: "\(entry.engine)＋\(translatorName)", characters: entry.original.count,
                recognition: entries[j].recognitionLatency,
                translation: translated == nil ? nil : done.timeIntervalSince(started),
                total: entries[j].totalLatency)
        }
    }

    // MARK: - 動作確認用の自動実行

    /// 起動引数 `--autotest <秒> <結果ファイル> [<相手のエンジン> <自分のエンジン> [<翻訳エンジン>]]` で、
    /// システム全体の音声を指定秒数だけ処理し、結果をファイルに書いて終了する（画面を操作せずに確かめるため）
    func runAutoTestIfRequested() async {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--autotest"), i + 2 < args.count, let seconds = Double(args[i + 1]) else { return }
        let output = URL(fileURLWithPath: args[i + 2])
        DebugTrace.begin(output.appendingPathExtension("trace"))
        // 見張り：予定より大幅に長引いたら、止まった段階を書いて終了する（権限の確認待ちなどで放置されないように）
        // WhisperKit の初回はモデルの変換に数分〜十数分かかるため、その分も見込む
        let limit = seconds + 600
        Task.detached {
            try? await Task.sleep(for: .seconds(limit))
            let message = "時間切れ（\(Int(limit))秒）。最後に記録した段階：\(DebugTrace.lastStep)"
            try? message.write(to: output, atomically: true, encoding: .utf8)
            await MainActor.run { NSApplication.shared.terminate(nil) }  // サーバーは applicationWillTerminate で止める
        }
        if i + 4 < args.count {
            remoteEngine = ASREngine(rawValue: args[i + 3]) ?? remoteEngine
            meEngine = ASREngine(rawValue: args[i + 4]) ?? meEngine
        }
        if i + 5 < args.count {
            translationEngine = TranslationEngine.allCases.first { $0.argName == args[i + 5] } ?? translationEngine
        }
        meetingApp = .system
        await refreshTranslation()
        await start()
        if isRunning { try? await Task.sleep(for: .seconds(seconds)) }
        await stop()
        try? await Task.sleep(for: .seconds(3))  // 最後の翻訳を待つ
        var lines = ["status: \(status)", "error: \(lastError ?? "なし")", "translation: \(translationStatus)",
                     "latency remote: \(latencySummary(for: .remote))", "latency me: \(latencySummary(for: .me))"]
        for e in entries {
            lines.append("[\(e.side.rawValue)/\(e.engine)/\(e.isFinal ? "確定" : "途中")/\(e.language ?? "-")] \(e.original)")
            lines.append("    訳（\(e.translator ?? "-")）: \(e.translation ?? "-") / 確定まで \(e.recognitionLatency.map { String(format: "%.2f", $0) } ?? "-")秒 / 訳文まで \(e.totalLatency.map { String(format: "%.2f", $0) } ?? "-")秒")
        }
        try? lines.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)
        shutdown()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - 集計・保存

    /// 話し終わりから訳文までの秒数の中央値と、遅い方から1割の値
    func latencySummary(for side: Side) -> String {
        let values = entries.filter { $0.side == side }.compactMap(\.totalLatency).sorted()
        guard !values.isEmpty else { return "—" }
        let median = values[values.count / 2]
        let p90 = values[min(values.count - 1, Int(Double(values.count) * 0.9))]
        return String(format: "中央値 %.1f秒／遅い方から1割 %.1f秒（%d件）", median, p90, values.count)
    }

    private func writeRecord() {
        let records = entries.filter(\.isFinal).map {
            RecordEntry(time: $0.time, speaker: $0.side.rawValue, engine: "\($0.engine)＋\($0.translator ?? "-")", language: $0.language ?? "",
                        original: $0.original, translation: $0.translation,
                        recognitionLatency: $0.recognitionLatency, totalLatency: $0.totalLatency)
        }
        guard !records.isEmpty else { return }
        do {
            let files = try RecordWriter.save(records, meetingApp: meetingApp.rawValue, startedAt: startedAt)
            status = "停止中（字幕を保存しました：\(files.map(\.lastPathComponent).joined(separator: "、"))）"
        } catch {
            lastError = "保存に失敗：\(error.localizedDescription)"
        }
    }
}

/// 取り込みの集計。音声スレッドと画面のスレッドの両方から触るため、ロックで守る
final class AudioStats: @unchecked Sendable {
    struct Snapshot {
        var seconds = 0.0
        /// 音の塊ごとの音量（RMS）の最大値。WhisperKit は 0.01 を超えると発話とみなす
        var maxLevel: Float = 0
        var shown = 0
        var dropped = 0
    }

    private let lock = NSLock()
    private var current = Snapshot()
    /// 画面のバー用の、前回読んでからの最大の音量
    private var recentLevel: Float = 0

    func add(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        var level: Float = 0
        if frames > 0, let data = buffer.floatChannelData?[0] {
            var sum: Float = 0
            for i in 0..<frames { sum += data[i] * data[i] }
            level = (sum / Float(frames)).squareRoot()
        }
        lock.lock()
        current.seconds += Double(frames) / buffer.format.sampleRate
        current.maxLevel = max(current.maxLevel, level)
        recentLevel = max(recentLevel, level)
        lock.unlock()
    }

    func countFinal(dropped: Bool) {
        lock.lock()
        if dropped { current.dropped += 1 } else { current.shown += 1 }
        lock.unlock()
    }

    func takeRecentLevel() -> Float {
        lock.lock()
        defer { lock.unlock() }
        let level = recentLevel
        recentLevel = 0
        return level
    }

    /// 今までの集計を返して、0 に戻す
    func take() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        let snapshot = current
        current = Snapshot()
        return snapshot
    }
}
