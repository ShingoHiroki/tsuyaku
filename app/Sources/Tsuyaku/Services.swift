import AppKit
import Foundation
import Translation

// MARK: - 翻訳

/// 画面で選べる翻訳エンジン
enum TranslationEngine: String, CaseIterable, Identifiable {
    case apple = "Apple"
    case plamo08 = "PLaMo 0.8B"
    case plamo2 = "PLaMo 2B"
    case plamo8 = "PLaMo 8B"

    var id: String { rawValue }

    /// 自動テストの引数で使う名前
    var argName: String {
        switch self {
        case .apple: "apple"
        case .plamo08: "plamo-0.8b"
        case .plamo2: "plamo-2b"
        case .plamo8: "plamo-8b"
        }
    }

    var plamoSize: String? {
        switch self {
        case .apple: nil
        case .plamo08: "0.8b"
        case .plamo2: "2b"
        case .plamo8: "8b"
        }
    }
}

/// 訳し終えた原文と訳文の組。PLaMo に直前の流れとして渡す
typealias TranslationPair = (source: String, target: String)

/// 英⇔日の翻訳。選んだエンジンの準備（Apple は言語パックの確認、PLaMo はサーバーの起動）をしてから使う
@MainActor
final class TranslatorService {
    private var enToJa: TranslationSession?
    private var jaToEn: TranslationSession?
    private var plamo: PLaMoServer?
    private(set) var engine: TranslationEngine = .apple

    static let en = Locale.Language(identifier: "en")
    static let ja = Locale.Language(identifier: "ja")

    /// 直前に受け付けた準備。切り替えが重なっても、受け付けた順に1件ずつ準備する
    private var preparing: Task<[String], Never>?

    /// 選んだエンジンの準備をする。使えない理由（未インストールの言語パックなど）を返し、使えるなら空
    func prepare(_ engine: TranslationEngine) async -> [String] {
        let previous = preparing
        let task = Task { () -> [String] in
            _ = await previous?.value
            return await self.switchTo(engine)
        }
        preparing = task
        return await task.value
    }

    private func switchTo(_ engine: TranslationEngine) async -> [String] {
        self.engine = engine
        guard let size = engine.plamoSize else {
            plamo?.stop()
            plamo = nil
            return await refreshApple()
        }
        if plamo?.size != size {
            plamo?.stop()
            plamo = PLaMoServer(size: size)
        }
        do {
            try await plamo?.start()
            return []
        } catch {
            return [error.localizedDescription]
        }
    }

    /// インストール済みなら Apple 翻訳の準備をする。未インストールの言語の向きを返す
    private func refreshApple() async -> [String] {
        let availability = LanguageAvailability()
        var missing: [String] = []
        if await availability.status(from: Self.en, to: Self.ja) == .installed {
            enToJa = enToJa ?? TranslationSession(installedSource: Self.en, target: Self.ja)
        } else {
            missing.append("英→日")
        }
        if await availability.status(from: Self.ja, to: Self.en) == .installed {
            jaToEn = jaToEn ?? TranslationSession(installedSource: Self.ja, target: Self.en)
        } else {
            missing.append("日→英")
        }
        return missing.isEmpty ? [] : ["言語パックが未インストール（\(missing.joined(separator: "・"))）"]
    }

    /// from は "en" か "ja"。反対の言語に訳す。history は同じ向きの直前の対訳（PLaMo だけが使う）
    func translate(_ text: String, from: String, history: [TranslationPair]) async throws -> String? {
        if let plamo {
            return try await plamo.translate(text, from: from, to: from == "en" ? "ja" : "en", history: history)
        }
        guard let session = from == "en" ? enToJa : jaToEn else { return nil }
        return try await session.translate(text).targetText
    }

    func shutdown() {
        plamo?.stop()
        plamo = nil
    }
}

/// PLaMo 3 Translate をこの Mac の中だけで動くサーバー（127.0.0.1）として起動し、翻訳を頼む。
/// サーバーは Python の仮想環境（.venv/）とモデル（models/plamo/）を使う（どちらもリポジトリのルートから。準備は app/README.md）
@MainActor
final class PLaMoServer {
    let size: String
    let port: Int
    private var pid: pid_t?
    /// 起動の処理。同時に何度呼ばれても、起動は1回だけにする（2つ目のサーバーがポートの取り合いで落ちないように）
    private var starting: Task<Void, Error>?

    /// リポジトリのルート（このファイルから4つ上）
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private var modelDir: URL { Self.repoRoot.appendingPathComponent("models/plamo/plamo-3-translate-\(size)-MLX-4bit") }
    private static var python: URL { repoRoot.appendingPathComponent(".venv/bin/python") }

    init(size: String) {
        self.size = size
        // サイズごとにポートを分ける（前回のサーバーが残っていても、別のサイズとつながらないように）
        self.port = ["0.8b": 8130, "2b": 8131, "8b": 8132][size] ?? 8139
    }

    func start() async throws {
        if let starting { return try await starting.value }
        let task = Task { try await self.launch() }
        starting = task
        do {
            try await task.value
        } catch {
            starting = nil
            throw error
        }
    }

    private func launch() async throws {
        if await isReady() { return }  // 前回起動したものが動いていれば使う
        guard FileManager.default.fileExists(atPath: Self.python.path),
              FileManager.default.fileExists(atPath: modelDir.appendingPathComponent("serve.py").path) else {
            throw NSError(domain: "Tsuyaku", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "PLaMo \(size) のモデルか Python の環境が見つかりません（app/README.md の「PLaMo の準備」を参照）"])
        }
        let log = AppFolders.base.appendingPathComponent("plamo-server.log")
        let pid = try Self.spawnDisclaimed(
            Self.python.path,
            ["serve.py", "--model", ".", "--trust-remote-code", "--host", "127.0.0.1", "--port", String(port)],
            directory: modelDir.path, log: log.path)
        self.pid = pid
        DebugTrace.log("PLaMo \(size)：サーバーを起動中")

        let started = Date()
        while Date().timeIntervalSince(started) < 180 {
            if !isRunning(pid) {
                throw NSError(domain: "Tsuyaku", code: 11, userInfo: [
                    NSLocalizedDescriptionKey: "PLaMo \(size) のサーバーが終了しました（\(log.path) を参照）"])
            }
            if await isReady() {
                DebugTrace.log(String(format: "PLaMo %@：起動完了（%.1f秒）", size, Date().timeIntervalSince(started)))
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        stop()
        throw NSError(domain: "Tsuyaku", code: 12, userInfo: [NSLocalizedDescriptionKey: "PLaMo \(size) のサーバーの起動が3分以内に終わりませんでした"])
    }

    func stop() {
        starting?.cancel()
        starting = nil
        if let pid {
            kill(pid, SIGTERM)
            DispatchQueue.global().async {
                var status: Int32 = 0
                waitpid(pid, &status, 0)  // 終了したプロセスの後始末（ゾンビとして残さない）
            }
        }
        pid = nil
    }

    private func isRunning(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        return waitpid(pid, &status, WNOHANG) == 0
    }

    /// サーバーを「このアプリが責任を持たないプロセス」として起動する（macOS が許可などをこのアプリと切り離して扱う）。
    /// 音声の取り込み（Process Tap）の開始・停止が約90秒止まる現象の対策として入れたが、
    /// その後の調査で、止まる原因は「システムオーディオの録音」の許可の確認に答えていないことだと分かった。
    /// この起動方法が必要かは未確認（普通の子プロセスでも問題ないと確かめられたら、外してよい）。
    /// responsibility_spawnattrs_setdisclaim は macOS の非公開の関数（試作版のため使う。将来使えなくなるおそれがある）
    private static func spawnDisclaimed(_ executable: String, _ arguments: [String], directory: String, log: String) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") {
            _ = unsafeBitCast(symbol, to: SetDisclaim.self)(&attributes, 1)
        } else {
            DebugTrace.log("PLaMo：責任を持たない起動ができないため、普通に起動します（音声の取り込みが遅れるおそれ）")
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addchdir_np(&actions, directory)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, log, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
        guard result == 0 else {
            throw NSError(domain: "Tsuyaku", code: 14, userInfo: [
                NSLocalizedDescriptionKey: "PLaMo のサーバーを起動できません（エラー \(result)）"])
        }
        return pid
    }

    private func isReady() async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/models")!)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    func translate(_ text: String, from: String, to: String, history: [TranslationPair]) async throws -> String {
        var messages: [[String: String]] = []
        for pair in history {
            messages.append(["role": "user", "content": pair.source])
            messages.append(["role": "assistant", "content": pair.target])
        }
        messages.append(["role": "user", "content": text])
        let body: [String: Any] = [
            "model": ".",
            "messages": messages,
            "chat_template_kwargs": ["source_lang": from, "target_lang": to],
            "temperature": 0,
            "max_tokens": 256,
            "stop": ["<|plamo:tag|>", "<|plamo:bos|>"],
        ]
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(domain: "Tsuyaku", code: 13, userInfo: [NSLocalizedDescriptionKey: "PLaMo の応答を読めません"])
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 保存先（アプリ専用の場所）

enum AppFolders {
    static let base: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tsuyaku", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var records: URL {
        let url = base.appendingPathComponent("records", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([base])
    }
}

// MARK: - 字幕の記録（Markdown と JSON）

struct RecordEntry: Codable {
    let time: Date
    let speaker: String
    let engine: String
    let language: String
    let original: String
    let translation: String?
    let recognitionLatency: Double?
    let totalLatency: Double?
}

enum RecordWriter {
    /// 会議1回分を保存し、保存したファイルを返す
    static func save(_ entries: [RecordEntry], meetingApp: String, startedAt: Date) throws -> [URL] {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd_HHmm"
        let name = stamp.string(from: startedAt)
        let json = AppFolders.records.appendingPathComponent("\(name).json")
        let markdown = AppFolders.records.appendingPathComponent("\(name).md")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: json)

        let time = DateFormatter()
        time.dateFormat = "HH:mm:ss"
        var lines = ["# 会議の字幕 \(name)", "", "- 会議アプリ: \(meetingApp)", ""]
        for entry in entries {
            lines.append("**\(time.string(from: entry.time)) \(entry.speaker)**（\(entry.engine)）")
            lines.append("")
            lines.append("> \(entry.original)")
            if let translation = entry.translation { lines.append(">"); lines.append("> \(translation)") }
            lines.append("")
        }
        try lines.joined(separator: "\n").write(to: markdown, atomically: true, encoding: .utf8)
        return [markdown, json]
    }
}

// MARK: - 進み具合の記録（発言の中身は書かない）
//
// 普段：保存先フォルダーの trace.log に、準備・権限・取り込みの開始と停止などの段階だけを書く（起動のたびに書き直す）。
//      取り込みの開始・停止で止まったときに、どの段階で止まったかを調べるため。
// 自動テスト：指定したファイルに、段階に加えて発言ごとの数字（秒数・文字数など）も書く。

enum DebugTrace {
    private static let lock = NSLock()
    private static var url: URL?
    /// 発言ごとの数字も書くか（自動テストのときだけ）
    private static var detailed = false
    private static var last = "（記録なし）"

    /// 普段の記録を始める（起動時）
    static func beginDefault() {
        start(AppFolders.base.appendingPathComponent("trace.log"), detailed: false)
    }

    /// 自動テストの記録を始める
    static func begin(_ file: URL) {
        start(file, detailed: true)
    }

    private static func start(_ file: URL, detailed: Bool) {
        lock.lock()
        url = file
        self.detailed = detailed
        lock.unlock()
        try? "".write(to: file, atomically: true, encoding: .utf8)
    }

    /// 段階の記録（普段も書く）
    static func log(_ message: String) {
        write(message, isDetail: false)
    }

    /// 発言ごとの記録（自動テストのときだけ書く）
    static func detail(_ message: String) {
        write(message, isDetail: true)
    }

    private static func write(_ message: String, isDetail: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isDetail && !detailed { return }
        last = message
        guard let url, let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        handle.write("\(ISO8601DateFormatter().string(from: Date())) \(message)\n".data(using: .utf8)!)
        try? handle.close()
    }

    /// 最後に記録した段階（止まった場所を知るため）
    static var lastStep: String {
        lock.lock()
        defer { lock.unlock() }
        return last
    }
}

// MARK: - 遅延の計測（発言の中身は書かない）

enum MetricsLog {
    private static let url = AppFolders.base.appendingPathComponent("metrics.csv")

    static func append(side: String, engine: String, characters: Int, recognition: Double?, translation: Double?, total: Double?) {
        let header = "日時,話者,エンジン,文字数,認識の遅れ(秒),翻訳にかかった時間(秒),話し終わりから訳文まで(秒)\n"
        let format: (Double?) -> String = { $0.map { String(format: "%.2f", $0) } ?? "" }
        let line = "\(ISO8601DateFormatter().string(from: Date())),\(side),\(engine),\(characters),\(format(recognition)),\(format(translation)),\(format(total))\n"
        if !FileManager.default.fileExists(atPath: url.path) {
            try? header.write(to: url, atomically: true, encoding: .utf8)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        }
    }
}
