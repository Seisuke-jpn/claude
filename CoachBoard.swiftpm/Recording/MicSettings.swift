import AVFoundation

/// マイクの選択とノイズ対策の設定
enum MicSettings {
    enum Keys {
        static let input = "mic.input"
        static let noiseReduction = "mic.noiseReduction"
        static let gate = "mic.gate"
    }

    /// iPad 本体のマイク
    static let builtInID = "builtIn"
    /// Bluetooth（AirPods など）のマイク
    static let bluetoothID = "bluetooth"

    static var selectedInput: String {
        UserDefaults.standard.string(forKey: Keys.input) ?? builtInID
    }

    /// 周りの雑音を抑える（iPad の音声処理を使う）
    static var noiseReduction: Bool {
        UserDefaults.standard.object(forKey: Keys.noiseReduction) as? Bool ?? true
    }

    /// 実際にノイズ除去を使うか。
    /// Bluetooth マイク（AirPods など）はイヤホン側で雑音処理をしているうえ、
    /// iPad の音声処理を重ねると音が途切れやすいので使わない。
    static var effectiveNoiseReduction: Bool {
        noiseReduction && selectedInput != bluetoothID
    }

    /// 話していない間はマイクの音を下げる（書き出し時）
    static var gate: Bool {
        UserDefaults.standard.object(forKey: Keys.gate) as? Bool ?? true
    }

    /// 音声設定で選んだマイクで録音できるようにする。
    /// 標準は iPad 本体のマイク（AirPods などは聞く専用：AirPods のマイクを使うと通話モードになり音質が下がるため）。
    /// 選んだマイクがつながっていなければ本体のマイクに戻し、その旨のメッセージを返す。
    static func configureSessionForRecording() async throws -> String? {
        let session = AVAudioSession.sharedInstance()
        let selection = MicSettings.selectedInput
        let options: AVAudioSession.CategoryOptions
        if selection == MicSettings.bluetoothID {
            // Bluetooth のマイクは「通話モード（HFP）」でしか使えない。
            // 高音質モード（A2DP）を許可すると出力が A2DP のまま残り、マイクが有効にならないので外す。
            options = [.allowBluetooth, .defaultToSpeaker]
        } else {
            options = [.defaultToSpeaker, .allowBluetoothA2DP]
        }
        try session.setCategory(.playAndRecord, mode: .default, options: options)
        try session.setActive(true)

        let inputs = session.availableInputs ?? []
        let builtIn = inputs.first { $0.portType == .builtInMic }
        var preferred: AVAudioSessionPortDescription?
        var warning: String?
        switch selection {
        case MicSettings.builtInID:
            preferred = builtIn
        case MicSettings.bluetoothID:
            preferred = inputs.first { $0.portType == .bluetoothHFP }
            if preferred == nil {
                preferred = builtIn
                warning = "Bluetooth のマイクが見つからないため、iPad 本体のマイクで録音します。"
            }
        default:
            preferred = inputs.first { $0.uid == selection }
            if preferred == nil {
                preferred = builtIn
                warning = "選んだマイクがつながっていないため、iPad 本体のマイクで録音します。"
            }
        }
        if let preferred {
            try? session.setPreferredInput(preferred)
            // 経路の切り替えが終わるのを待ってから録音を始める（途中で始めると何度も作り直しになり音が途切れる）
            for _ in 0..<20 {
                if session.currentRoute.inputs.contains(where: { $0.uid == preferred.uid }) { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            try? await Task.sleep(nanoseconds: preferred.portType == .bluetoothHFP ? 400_000_000 : 100_000_000)
        }
        return warning
    }

    static func restorePlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }

    static func kindName(_ type: AVAudioSession.Port) -> String {
        switch type {
        case .builtInMic: return "iPad 本体"
        case .usbAudio: return "USB マイク"
        case .headsetMic: return "有線イヤホンのマイク"
        case .lineIn: return "ライン入力"
        case .bluetoothHFP: return "Bluetooth"
        case .carAudio: return "車載"
        default: return "外部マイク"
        }
    }
}

/// 接続されているマイクの一覧
@MainActor
final class MicInputCatalog: ObservableObject {
    struct Option: Identifiable, Hashable {
        let id: String
        let name: String
        let detail: String?
    }

    @Published private(set) var options: [Option] = []

    /// 一覧を取り直す。マイクの一覧は「録音できる状態」のときしか取れないので、一時的に切り替える。
    func refresh() {
        let session = AVAudioSession.sharedInstance()
        let alreadyRecording = session.category == .playAndRecord
        if !alreadyRecording {
            try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try? session.setActive(true)
        }
        let inputs = session.availableInputs ?? []
        let outputs = session.currentRoute.outputs
        if !alreadyRecording {
            try? session.setCategory(.playback, mode: .moviePlayback)
            try? session.setActive(true)
        }

        var list = [Option(id: MicSettings.builtInID, name: "iPad 本体のマイク", detail: nil)]
        for input in inputs where input.portType != .builtInMic && input.portType != .bluetoothHFP {
            list.append(Option(id: input.uid, name: input.portName, detail: MicSettings.kindName(input.portType)))
        }
        let bluetoothPorts: [AVAudioSession.Port] = [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP]
        let hasBluetooth = outputs.contains { bluetoothPorts.contains($0.portType) }
            || inputs.contains { $0.portType == .bluetoothHFP }
        if hasBluetooth {
            list.append(Option(id: MicSettings.bluetoothID, name: "Bluetooth（AirPods など）のマイク",
                               detail: "録画中は通話モードになり、イヤホンから聞こえる音質が下がります（書き出す動画の音質は変わりません）"))
        }
        // 選んでいたマイクが今つながっていなくても、一覧には残しておく
        let selected = MicSettings.selectedInput
        if !list.contains(where: { $0.id == selected }) {
            list.append(Option(id: selected, name: "前回選んだマイク（未接続）", detail: "つながっていなければ iPad 本体のマイクで録音します"))
        }
        options = list
    }
}
