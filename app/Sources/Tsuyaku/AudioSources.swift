import AVFoundation
import CoreAudio
import Foundation

// MARK: - Core Audio の補助

struct CoreAudioError: LocalizedError {
    let what: String
    let status: OSStatus
    var errorDescription: String? { "\(what) に失敗（OSStatus \(status)）" }
}

private func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw CoreAudioError(what: what, status: status) }
}

private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}

private func readValue<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) throws -> T {
    var addr = address(selector)
    var size = UInt32(MemoryLayout<T>.size)
    var value = initial
    try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value), "プロパティの取得")
    return value
}

private func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
    var addr = address(selector)
    var size = UInt32(MemoryLayout<CFString>.size)
    var value: CFString = "" as CFString
    try withUnsafeMutablePointer(to: &value) { pointer in
        try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, pointer), "文字列の取得")
    }
    return value as String
}

struct AudioProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
}

func audioProcesses() throws -> [AudioProcess] {
    var addr = address(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    try check(AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size), "プロセス一覧のサイズ取得")
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
    try check(AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids), "プロセス一覧の取得")
    return ids.map { id in
        AudioProcess(
            objectID: id,
            pid: (try? readValue(id, kAudioProcessPropertyPID, initial: pid_t(0))) ?? 0,
            bundleID: (try? readString(id, kAudioProcessPropertyBundleID)) ?? ""
        )
    }
}

/// 会議アプリの選択肢。バンドルID の先頭が一致するプロセスをまとめて取り込む
enum MeetingApp: String, CaseIterable, Identifiable {
    case chrome = "Google Meet（Chrome）"
    case vivaldi = "Google Meet（Vivaldi）"
    case zoom = "Zoom"
    case teams = "Microsoft Teams"
    case system = "システム全体"

    var id: String { rawValue }

    /// Zoom・Teams の値は未確認
    var bundlePrefix: String? {
        switch self {
        case .chrome: "com.google.Chrome"
        case .vivaldi: "com.vivaldi.Vivaldi"
        case .zoom: "us.zoom.xos"
        case .teams: "com.microsoft.teams2"
        case .system: nil
        }
    }

    func matchingProcesses() throws -> [AudioProcess] {
        guard let prefix = bundlePrefix else { return [] }
        return try audioProcesses().filter { $0.bundleID.hasPrefix(prefix) }
    }
}

// MARK: - 音声の取り込み

/// 取り込んだ音声を渡す先。音声スレッドから呼ばれる
typealias BufferHandler = (AVAudioPCMBuffer) -> Void

// MARK: - 音声の装置（マイク・イヤホンなど）

/// 入力・出力の装置。名前には持ち主の名前が入ることがある（「〇〇の AirPods」など）ため、進み具合の記録には書かない
struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transportType: UInt32
    /// 内蔵の出力で、今どこから音が出ているか（スピーカーかヘッドホン端子か）。内蔵以外は nil
    let dataSource: UInt32?

    private static let builtInSpeaker: UInt32 = 0x6973_706B    // 'ispk'
    private static let builtInHeadphones: UInt32 = 0x6864_706E // 'hdpn'

    /// スピーカーから音が出ていると推定されるか（相手の声がマイクに入りやすい）。Bluetooth・USB は判別できないため含めない
    var isLikelySpeaker: Bool {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn: dataSource != Self.builtInHeadphones
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeAirPlay: true
        default: false
        }
    }

    /// 進み具合の記録に書く種類（名前の代わり）
    var kind: String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn: dataSource == Self.builtInHeadphones ? "内蔵（ヘッドホン端子）" : "内蔵"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "Bluetooth"
        case kAudioDeviceTransportTypeUSB: "USB"
        case kAudioDeviceTransportTypeHDMI: "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: "AirPlay"
        case kAudioDeviceTransportTypeVirtual: "仮想"
        case kAudioDeviceTransportTypeAggregate: "集約"
        default: "その他"
        }
    }
}

enum AudioDevices {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    /// 入力（isInput）または出力の装置の一覧。隠れている装置と、取り込みのために作られる装置は除く
    static func list(input isInput: Bool) -> [AudioDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.stride)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        let scope = isInput ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0,
                  (try? readValue(id, kAudioDevicePropertyIsHidden, initial: UInt32(0))) != 1,
                  let uid = try? readString(id, kAudioDevicePropertyDeviceUID),
                  let name = try? readString(id, kAudioObjectPropertyName),
                  !name.hasPrefix("CADefaultDeviceAggregate"), !name.hasPrefix("Tsuyaku") else { return nil }
            let transport = (try? readValue(id, kAudioDevicePropertyTransportType, initial: UInt32(0))) ?? 0
            var source = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var sourceValue: UInt32 = 0
            var sourceSize = UInt32(MemoryLayout<UInt32>.size)
            let hasSource = transport == kAudioDeviceTransportTypeBuiltIn
                && AudioObjectGetPropertyData(id, &source, 0, nil, &sourceSize, &sourceValue) == noErr
            return AudioDevice(id: id, uid: uid, name: name, transportType: transport, dataSource: hasSource ? sourceValue : nil)
        }
    }

    /// macOS で今選ばれている入力・出力の装置
    static func defaultDevice(input isInput: Bool) -> AudioDeviceID? {
        let selector = isInput ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
        let id = (try? readValue(system, selector, initial: AudioDeviceID(0))) ?? 0
        return id == 0 ? nil : id
    }

    /// 装置のサンプリング周波数。Bluetooth のイヤホンは、マイクを使い始めると通話用のモードに切り替わり、これが下がる（例：48000 → 16000）
    static func sampleRate(_ id: AudioDeviceID) -> Double? {
        try? readValue(id, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))
    }

    /// macOS 全体の出力を切り替える（会議アプリ以外の音もこの装置から出るようになる）
    static func setDefaultOutput(_ id: AudioDeviceID) throws {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var value = id
        try check(AudioObjectSetPropertyData(system, &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &value), "出力の切り替え")
    }
}

/// 装置の抜き差し・既定の装置の切り替え・内蔵の出力のスピーカー／ヘッドホン端子の切り替えを見張る
final class AudioDeviceWatcher {
    private let system = AudioObjectID(kAudioObjectSystemObject)
    private let systemSelectors = [
        kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice,
    ]
    private let block: AudioObjectPropertyListenerBlock
    /// 内蔵の出力のデータソース（スピーカー／ヘッドホン端子）を見張っている装置
    private var watchedSources: [AudioDeviceID] = []

    init(onChange: @escaping () -> Void) {
        block = { _, _ in onChange() }
        for selector in systemSelectors {
            var addr = address(selector)
            AudioObjectAddPropertyListenerBlock(system, &addr, .main, block)
        }
    }

    /// 内蔵の出力にヘッドホンを挿した・抜いたことも知るため、見張る装置を一覧に合わせて付け替える
    func watchDataSources(of devices: [AudioDevice]) {
        let ids = devices.filter { $0.dataSource != nil }.map(\.id)
        guard ids != watchedSources else { return }
        for id in watchedSources { removeSourceListener(id) }
        for id in ids {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(id, &addr, .main, block)
        }
        watchedSources = ids
    }

    private func removeSourceListener(_ id: AudioDeviceID) {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(id, &addr, .main, block)
    }

    /// サンプリング周波数を見張っている出力の装置
    private var watchedRateDevice: AudioDeviceID?

    /// 今の出力の装置のサンプリング周波数の変化（Bluetooth のイヤホンの通話用モードへの切り替えなど）を見張る
    func watchSampleRate(of id: AudioDeviceID?) {
        guard id != watchedRateDevice else { return }
        if let old = watchedRateDevice {
            var addr = address(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(old, &addr, .main, block)
        }
        if let id {
            var addr = address(kAudioDevicePropertyNominalSampleRate)
            AudioObjectAddPropertyListenerBlock(id, &addr, .main, block)
        }
        watchedRateDevice = id
    }

    deinit {
        for selector in systemSelectors {
            var addr = address(selector)
            AudioObjectRemovePropertyListenerBlock(system, &addr, .main, block)
        }
        for id in watchedSources { removeSourceListener(id) }
        watchSampleRate(of: nil)
    }
}

/// Core Audio Process Tap で、会議アプリの音声（相手の声）を取り込む
final class ProcessTapSource {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "Tsuyaku.tap")

    /// processObjectIDs が空なら、システム全体の音声を取り込む
    func start(processObjectIDs: [AudioObjectID], handler: @escaping BufferHandler) throws {
        let description = processObjectIDs.isEmpty
            ? CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            : CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.uuid = UUID()
        description.name = "Tsuyaku"
        description.muteBehavior = .unmuted
        description.isPrivate = true
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Process Tap の作成")

        var asbd = try readValue(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
        let tapRate = asbd.mSampleRate

        // 時計役には、会議の音が出ている今の出力の装置を使う（通知音用の出力ではない）
        let outputDevice = try readValue(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, initial: AudioDeviceID(0))
        let outputUID = try readString(outputDevice, kAudioDevicePropertyDeviceUID)
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Tsuyaku-Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "集約デバイスの作成")

        // 届く音声は、Process Tap の形式ではなく集約デバイス（＝時計役の出力の装置）の周波数になる。
        // Bluetooth のイヤホンの通話用モードでは Tap が 48000Hz、集約が 16000Hz と食い違い、Tap の形式で読むと3倍速になる（実測）
        if let rate = AudioDevices.sampleRate(aggregateID), rate > 0 { asbd.mSampleRate = rate }
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw CoreAudioError(what: "音声形式の変換", status: -1)
        }
        formatSummary = describe(format) + (Int(tapRate) == Int(format.sampleRate) ? "" : "（Tap の申告：\(Int(tapRate))Hz）")

        // bufferListNoCopy のバッファは IOProc を抜けると再利用されるため、渡す側（handler）でその場で変換・複製する
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            handler(buffer)
        }, "IOProc の作成")
        try check(AudioDeviceStart(aggregateID, procID), "取り込みの開始")
    }

    /// 取り込んだ音声の形式（進み具合の記録用）
    private(set) var formatSummary = ""

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}

/// 進み具合の記録に書く音声の形式（例：16000Hz・1ch）
private func describe(_ format: AVAudioFormat) -> String {
    "\(Int(format.sampleRate))Hz・\(format.channelCount)ch"
}

/// マイクの音声（自分の声）を取り込む
final class MicSource {
    private let engine = AVAudioEngine()
    private var deviceID: AudioDeviceID?
    private var handler: BufferHandler?
    private var observer: NSObjectProtocol?

    /// 取り込んだ音声の形式（進み具合の記録用）
    private(set) var formatSummary = ""

    /// deviceID が nil なら、macOS で選ばれているマイクを使う
    func start(deviceID: AudioDeviceID?, handler: @escaping BufferHandler) throws {
        self.deviceID = deviceID
        self.handler = handler
        try startEngine()
        // 装置の形式が変わると（Bluetooth のイヤホンが通話用のモードに切り替わったときなど）、AVAudioEngine は止まるので始め直す
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.restartAfterChange() }
    }

    private func startEngine() throws {
        let input = engine.inputNode
        if let deviceID, let unit = input.audioUnit {
            var id = deviceID
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                           &id, UInt32(MemoryLayout<AudioDeviceID>.size)), "マイクの切り替え")
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, let handler else {
            throw CoreAudioError(what: "マイクの音声形式の取得", status: -1)
        }
        formatSummary = describe(format)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in handler(buffer) }
        try engine.start()
    }

    private func restartAfterChange() {
        guard observer != nil else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        do {
            try startEngine()
            DebugTrace.log("マイクの形式が変わったため、マイクを始め直した（\(formatSummary)）")
        } catch {
            DebugTrace.log("マイクの始め直しに失敗：\(error.localizedDescription)")
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

// MARK: - 形式の変換

/// 取り込んだ音声を、文字起こしエンジンが求める形式（サンプリング周波数・チャンネル数）に変換する
final class BufferConverter {
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    let outputFormat: AVAudioFormat

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if sourceFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            sourceFormat = buffer.format
        }
        guard let converter else { return nil }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }
}
