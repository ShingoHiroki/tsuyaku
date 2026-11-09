import SwiftUI
import Translation

@main
struct TsuyakuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Tsuyaku") {
            ContentView(model: appDelegate.model)
        }
        // WhisperKit の調整は別のウィンドウで行う（会議中も字幕を見ながら変えられるように）
        Window("WhisperKit の調整", id: "whisper-tuning") {
            WhisperTuningView()
        }
        .windowResizability(.contentMinSize)
    }
}

/// 自動テストは、ウィンドウの表示を待たずに起動直後から始める
/// （起動引数にファイルのパスがあると、macOS がウィンドウを自動で開かないことがあるため）
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: SessionModel

    /// 進み具合の記録は、SessionModel（装置の確認）や画面の準備より先に始める
    override init() {
        DebugTrace.beginDefault()
        model = SessionModel()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await model.runAutoTestIfRequested() }
    }

    /// PLaMo のサーバーはアプリとは別のプロセスなので、終了時に止める
    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }
}

struct ContentView: View {
    @ObservedObject var model: SessionModel
    @State private var enToJaSetup: TranslationSession.Configuration?
    @State private var jaToEnSetup: TranslationSession.Configuration?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            settings
            statusBar
            Divider()
            transcript
        }
        .padding()
        .frame(minWidth: 760, minHeight: 560)
        .task {
            await model.refreshTranslation()
        }
        .onChange(of: model.translationEngine) {
            Task { await model.refreshTranslation() }
        }
        // 言語パックのインストールは、画面から Apple の確認を出す必要がある
        .translationTask(enToJaSetup) { session in
            try? await session.prepareTranslation()
            await model.refreshTranslation()
        }
        .translationTask(jaToEnSetup) { session in
            try? await session.prepareTranslation()
            await model.refreshTranslation()
        }
    }

    // MARK: - 設定

    /// 設定の表。左の列は項目名、右の列は操作で、どの行も左の端をそろえる
    /// （選択の欄に決まった幅を付けると、macOS 26 では欄がその幅の真ん中に置かれて左の端がずれるため、幅は中身に任せる）
    private var settings: some View {
        let locked = model.isRunning || model.isBusy
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text("会議アプリ")
                Picker("", selection: $model.meetingApp) {
                    ForEach(MeetingApp.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(locked)
            }
            GridRow {
                Text("相手の認識")
                HStack(spacing: 16) {
                    enginePicker($model.remoteEngine)
                    // 日本語を選ぶと、相手の発言を英語に訳す（訳す向きは、書き出された文字の言語で決まる）
                    Picker("相手の言語", selection: $model.remoteLocale) {
                        ForEach(SessionModel.remoteLocales, id: \.id) { Text($0.label).tag($0.id) }
                    }
                    .fixedSize()
                }
                .disabled(locked)
            }
            GridRow {
                Text("自分の認識")
                HStack(spacing: 16) {
                    enginePicker($model.meEngine)
                    Toggle("マイクを使う", isOn: $model.useMic)
                }
                .disabled(locked)
            }
            GridRow {
                Text("マイク")
                HStack {
                    Picker("", selection: $model.selectedInputUID) {
                        Text("システムの設定に従う").tag("")
                        ForEach(model.inputDevices) { Text($0.name).tag($0.uid) }
                        if model.selectedInputMissing {
                            Text("（前に選んだ装置：見つかりません）").tag(model.selectedInputUID)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    if model.selectedInputMissing {
                        Text("見つからないため、システムの設定のマイクを使います")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .disabled(locked || !model.useMic)
            }
            // 出力（イヤホンなど）は会議中でも切り替えられるよう、取り込み中も操作できるようにする
            GridRow {
                Text("出力")
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Picker("", selection: Binding(
                            get: { model.currentOutput?.uid ?? "" },
                            set: { model.selectOutput(uid: $0) }
                        )) {
                            if model.currentOutput == nil { Text("（不明）").tag("") }
                            ForEach(model.outputDevices) { Text($0.name).tag($0.uid) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(model.isBusy)
                        Text("切り替えると、Mac 全体の出力が変わります（会議アプリでスピーカーを選んでいる場合は、そちらが優先されます）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let warning = model.outputWarning {
                        Text(warning)
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
            }
            GridRow {
                Text("翻訳")
                HStack {
                    Picker("", selection: $model.translationEngine) {
                        ForEach(TranslationEngine.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    Text("PLaMo は大きいほど訳が丁寧で、遅くなります")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(locked)
            }
            GridRow {
                Text("記録")
                HStack {
                    Toggle("字幕を保存する（文字だけ）", isOn: $model.saveRecord)
                    Toggle("相手に伝えた", isOn: $model.toldParticipants)
                        .disabled(!model.saveRecord)
                    if model.saveRecord && !model.toldParticipants {
                        Text("相手に伝えるまで保存されません")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .disabled(locked)
            }
        }
    }

    /// 文字起こしのエンジン（Apple・WhisperKit）の切り替え
    private func enginePicker(_ selection: Binding<ASREngine>) -> some View {
        Picker("", selection: selection) {
            ForEach(ASREngine.allCases) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(model.isRunning ? "停止" : "開始") {
                    Task { model.isRunning ? await model.stop() : await model.start() }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .tint(model.isRunning ? .red : .accentColor)
                .disabled(model.isBusy)
                if model.isBusy { ProgressView().controlSize(.small) }
                Text(model.status).font(.callout)
                Spacer()
                Button("WhisperKit の調整…") { openWindow(id: "whisper-tuning") }
                    .help("話し始めの判断や、誤った字幕の捨て方を変えます。保存するとすぐ反映されます")
                Button("保存先を Finder で開く") { AppFolders.revealInFinder() }
            }
            HStack {
                Text("翻訳：\(model.translationStatus)")
                if !model.translationReady && model.translationEngine == .apple {
                    Button("言語パックをインストール") {
                        enToJaSetup = .init(source: TranslatorService.en, target: TranslatorService.ja)
                        jaToEnSetup = .init(source: TranslatorService.ja, target: TranslatorService.en)
                    }
                }
                Spacer()
                Text("遅延 相手：\(model.latencySummary(for: .remote))　自分：\(model.latencySummary(for: .me))")
            }
            .font(.caption)
            HStack(spacing: 24) {
                MeterView(label: "相手の音", meter: model.remoteMeter)
                MeterView(label: "自分の声", meter: model.meMeter)
            }
            if let error = model.lastError {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        }
    }

    // MARK: - 字幕

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.entries) { entry in
                        EntryRow(entry: entry).id(entry.id)
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.entries.count) {
                if let last = model.entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}

/// 音量のバー。話している（音が出ている）と判断している間は緑に光る。縦線は話し始めと判断する音量
struct MeterView: View {
    let label: String
    let meter: LevelMeter

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(meter.active ? Color.green : Color.secondary.opacity(0.3))
                .frame(width: 10, height: 10)
            Text(label).font(.caption)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule()
                        .fill(meter.active ? Color.green : Color.secondary.opacity(0.6))
                        .frame(width: geometry.size.width * meter.level)
                    if let threshold = meter.threshold {
                        Rectangle()
                            .fill(Color.orange)
                            .frame(width: 2)
                            .offset(x: geometry.size.width * threshold - 1)
                    }
                }
            }
            .frame(width: 160, height: 8)
        }
        .animation(.linear(duration: 0.1), value: meter.level)
        .help("緑に光っている間は、話している（音が出ている）と判断しています。オレンジの線は、話し始めと判断する音量です（WhisperKit のとき）")
    }
}

struct EntryRow: View {
    let entry: Entry

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.side.rawValue)
                    .font(.caption.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(entry.side == .remote ? Color.blue.opacity(0.2) : Color.green.opacity(0.2), in: Capsule())
                Text(Self.timeFormat.string(from: entry.time)).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 64, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.original)
                    .foregroundStyle(entry.isFinal ? .primary : .secondary)
                if let translation = entry.translation {
                    Text(translation).font(.title3).fontWeight(.medium)
                } else if entry.isFinal {
                    Text("（翻訳中…）").foregroundStyle(.secondary)
                }
                Text(latencyText).font(.caption2).foregroundStyle(.secondary)
            }
            .textSelection(.enabled)
        }
    }

    private var latencyText: String {
        var parts = [entry.engine]
        if let r = entry.recognitionLatency { parts.append(String(format: "確定まで %.1f秒", r)) }
        if let t = entry.totalLatency { parts.append(String(format: "訳文まで %.1f秒", t)) }
        return parts.joined(separator: "・")
    }
}
