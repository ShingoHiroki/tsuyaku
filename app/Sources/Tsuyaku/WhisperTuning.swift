import Foundation
import SwiftUI

/// WhisperKit の区切り方と、誤った字幕（ハルシネーション）の捨て方の調整値。
/// 調整の画面で保存すると、取り込み中でも次に届く音・次の区切りからすぐ反映される。保存した値は次に起動したときも使う
struct WhisperTuning: Codable, Equatable {
    /// 話し始めと判断する音量（RMS）は「雑音の大きさ × noiseFactor」。ただし thresholdMin〜thresholdMax の範囲に収める
    var thresholdMin = 0.002
    var thresholdMax = 0.01
    var noiseFactor = 3.0
    /// 区切りの中で、基準を超えた音（声）がこの秒数に満たなければ、雑音とみなして文字起こししない
    var minVoiced = 0.3
    /// この秒数より短い区切りで、shortPhrases の言葉だけが出たら捨てる
    var shortSegment = 3.0
    /// 短い区切りで、これだけが出たら捨てる相づち・決まり文句（句読点・空白・大文字小文字の違いは無視して比べる）
    var shortPhrases = ["ありがとうございました", "ありがとうございます", "ありがとう", "はい", "はいはい", "うん", "ええ", "あ", "え",
                        "Thank you", "Thank you very much", "Thanks", "Bye", "You"]
    /// 長さに関係なく、これを含む文は捨てる（Whisper が無音や雑音から作りがちな文）
    var hallucinationPhrases = ["ご視聴ありがとうございました", "Thank you for watching", "Thanks for watching", "字幕"]
    /// Whisper の自信（平均の対数確率）がこれより低い文は捨てる。Whisper で広く使われている値は -1.0
    var minAvgLogprob = -1.0
    /// 同じ語の繰り返しの多さ（圧縮率）がこれより大きい文は捨てる。Whisper で広く使われている値は 2.4
    var maxCompressionRatio = 2.4

    static let defaults = WhisperTuning()

    /// 入力の誤りがあれば、その説明を返す
    var problems: [String] {
        var list: [String] = []
        if thresholdMin <= 0 || thresholdMax <= 0 { list.append("話し始めの基準は 0 より大きくしてください") }
        if thresholdMin > thresholdMax { list.append("話し始めの基準は、下限を上限以下にしてください") }
        if noiseFactor <= 0 { list.append("雑音の倍率は 0 より大きくしてください") }
        if minVoiced < 0 || shortSegment < 0 { list.append("秒数は 0 以上にしてください") }
        if maxCompressionRatio <= 0 { list.append("繰り返しの基準は 0 より大きくしてください") }
        return list
    }

    /// 進み具合の記録に書く要約（数字と件数だけ）
    var summary: String {
        String(format: "基準 %.3f〜%.3f・雑音の%.1f倍・声の最短 %.2f秒・短い区切り %.1f秒・相づち %d件・決まり文句 %d件・自信 %.2f・繰り返し %.1f",
               thresholdMin, thresholdMax, noiseFactor, minVoiced, shortSegment,
               shortPhrases.count, hallucinationPhrases.count, minAvgLogprob, maxCompressionRatio)
    }

    /// 比べるための形（句読点・空白・記号を除き、英字は小文字）
    static func normalize(_ text: String) -> String {
        let ignored = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
        return String(String.UnicodeScalarView(text.lowercased().unicodeScalars.filter { !ignored.contains($0) }))
    }

    // MARK: - 共有の今の値（音声スレッドからも読むため、ロックで守る）

    private static let key = "whisperTuning"
    private static let lock = NSLock()
    private static var stored: WhisperTuning = {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode(WhisperTuning.self, from: data) else { return .defaults }
        return saved
    }()

    static var current: WhisperTuning {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    /// 保存して、すぐ反映する
    static func save(_ tuning: WhisperTuning) {
        lock.lock()
        stored = tuning
        lock.unlock()
        if let data = try? JSONEncoder().encode(tuning) { UserDefaults.standard.set(data, forKey: key) }
        DebugTrace.log("WhisperKit の調整を保存：\(tuning.summary)")
    }
}

// MARK: - 調整の画面

struct WhisperTuningView: View {
    @State private var draft = WhisperTuning.current
    @State private var saved = WhisperTuning.current
    @State private var shortText = WhisperTuning.current.shortPhrases.joined(separator: "\n")
    @State private var hallucinationText = WhisperTuning.current.hallucinationPhrases.joined(separator: "\n")

    /// 一覧の入力欄の内容を反映した、保存する値
    private var edited: WhisperTuning {
        var tuning = draft
        tuning.shortPhrases = Self.lines(shortText)
        tuning.hallucinationPhrases = Self.lines(hallucinationText)
        return tuning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("保存すると、取り込み中でも次の音・次の区切りからすぐ反映されます。相手側・自分側の両方に効きます（WhisperKit を選んでいる側だけ）")
                .font(.callout)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section("話し始めの判断") {
                        numberRow("基準の下限", value: $draft.thresholdMin, format: "%.3f",
                                  note: "小さくすると小さい声も拾うが、雑音も拾いやすい。画面のバーのオレンジの線がこの基準")
                        numberRow("基準の上限", value: $draft.thresholdMax, format: "%.3f",
                                  note: "雑音の多いマイクでも、基準はこれより上がらない")
                        numberRow("雑音の倍率", value: $draft.noiseFactor, format: "%.1f",
                                  note: "しゃべっていないときの音量の何倍を超えたら話し始めとみなすか")
                    }
                    section("雑音の区切りを捨てる") {
                        numberRow("声の最短（秒）", value: $draft.minVoiced, format: "%.2f",
                                  note: "区切りの中で基準を超えた時間がこれ未満なら、文字起こしせずに捨てる（物音・息など）")
                        numberRow("短い区切り（秒）", value: $draft.shortSegment, format: "%.1f",
                                  note: "これより短い区切りで、下の相づちだけが出たら捨てる")
                    }
                    section("捨てる言葉") {
                        listEditor("短い区切りで捨てる相づち（1行に1つ）", text: $shortText,
                                   note: "この言葉だけの字幕を捨てる。句読点・空白・大文字小文字の違いは無視する。本当に言った相づちも出なくなる")
                        listEditor("いつも捨てる決まり文句（1行に1つ）", text: $hallucinationText,
                                   note: "長さに関係なく、これを含む字幕を捨てる")
                    }
                    section("Whisper の自信") {
                        numberRow("自信の下限", value: $draft.minAvgLogprob, format: "%.2f",
                                  note: "これより自信の低い文を捨てる。0 に近づけるほど厳しい（一般的な値は -1.0）")
                        numberRow("繰り返しの上限", value: $draft.maxCompressionRatio, format: "%.1f",
                                  note: "同じ語の繰り返しがこれより多い文を捨てる。小さくするほど厳しい（一般的な値は 2.4）")
                    }
                }
                .padding(.trailing, 8)
            }

            ForEach(edited.problems, id: \.self) { problem in
                Text(problem).font(.callout).foregroundStyle(.red)
            }

            HStack {
                Button("既定に戻す") { load(.defaults) }
                    .help("入力欄を既定の値に戻します（保存するまで反映されません）")
                Button("保存前に戻す") { load(saved) }
                    .disabled(edited == saved)
                Spacer()
                Text(edited == saved ? "保存済み" : "未保存の変更があります")
                    .font(.caption)
                    .foregroundStyle(edited == saved ? Color.secondary : Color.orange)
                Button("保存") {
                    let tuning = edited
                    WhisperTuning.save(tuning)
                    saved = tuning
                }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(edited == saved || !edited.problems.isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 560, minHeight: 620)
    }

    private func load(_ tuning: WhisperTuning) {
        draft = tuning
        shortText = tuning.shortPhrases.joined(separator: "\n")
        hallucinationText = tuning.hallucinationPhrases.joined(separator: "\n")
    }

    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func numberRow(_ label: String, value: Binding<Double>, format: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).frame(width: 140, alignment: .leading)
                TextField("", value: value, format: .number.precision(.fractionLength(0...4)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                Text("既定：" + String(format: format, defaultValue(for: label)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func defaultValue(for label: String) -> Double {
        let d = WhisperTuning.defaults
        switch label {
        case "基準の下限": return d.thresholdMin
        case "基準の上限": return d.thresholdMax
        case "雑音の倍率": return d.noiseFactor
        case "声の最短（秒）": return d.minVoiced
        case "短い区切り（秒）": return d.shortSegment
        case "自信の下限": return d.minAvgLogprob
        default: return d.maxCompressionRatio
        }
    }

    private func listEditor(_ label: String, text: Binding<String>, note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
            TextEditor(text: text)
                .font(.body)
                .frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }
}
