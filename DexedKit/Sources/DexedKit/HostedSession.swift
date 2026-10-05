import Foundation

/// Everything a hosted (plugin) instance remembers. It is what DAWs save into projects.
public struct HostedSettings: Sendable, Equatable {
    public var patch = Patch.initVoice
    public var bank = Cartridge()
    public var bankName = "Init Bank"
    public var program = 0
    public var volume: Float = 1
    public var tune: Double = 0.5
    public var cutoff: Double = 1
    public var resonance: Double = 0
    public var engine = EngineType.markI
    public var scl: String?
    public var kbm: String?
    public var tuningName: String?
    public init() {}
}

/// Shared between the Audio Unit (real-time side) and the plugin's SwiftUI editor, either of which may not exist.
/// The Audio Unit owns the session; the editor attaches to it when the host opens the plug-in window.
public final class HostedSession: @unchecked Sendable {
    public let core: SynthCore
    /// Called on the main queue when the host (not the editor) changed something: presets, parameters, state restore.
    public var onExternalChange: (@Sendable () -> Void)?

    private let lock = NSLock()
    private var _settings = HostedSettings()

    public init() {
        core = SynthCore(sampleRate: 48000)
        core.setPatch(_settings.patch)
        core.setEngine(_settings.engine)
    }

    public var settings: HostedSettings {
        lock.lock(); defer { lock.unlock() }
        return _settings
    }

    /// Editor → session. Does not touch the core (the editor already did).
    public func update(_ change: (inout HostedSettings) -> Void) {
        lock.lock()
        change(&_settings)
        let volume = _settings.volume
        lock.unlock()
        core.setOutputGain(volume)
    }

    /// Host → session: pushes the new settings into the engine and tells the editor.
    public func apply(_ new: HostedSettings) {
        lock.lock(); _settings = new; lock.unlock()
        core.setOutputGain(new.volume)
        core.setPatch(new.patch)
        core.setEngine(new.engine)
        core.setMasterTune(new.tune)
        core.setFilter(cutoff: new.cutoff, resonance: new.resonance)
        core.setTuning(scl: new.scl, kbm: new.kbm)
        notifyEditor()
    }

    /// Host selected a voice (MIDI program change or a preset in the host UI).
    public func selectProgram(_ index: Int) {
        var s = settings
        let i = max(0, min(Cartridge.voiceCount - 1, index))
        s.program = i
        s.patch = s.bank.patch(at: i)
        apply(s)
    }

    /// Host automation of the exposed parameters.
    public func setHostParameter(_ address: Int, _ value: Double) {
        var s = settings
        switch address {
        case HostParameter.volume: s.volume = Float(value); core.setOutputGain(s.volume)
        case HostParameter.cutoff: s.cutoff = value; core.setFilter(cutoff: value, resonance: s.resonance)
        case HostParameter.resonance: s.resonance = value; core.setFilter(cutoff: s.cutoff, resonance: value)
        case HostParameter.tune: s.tune = (value + 100) / 200; core.setMasterTune(s.tune)
        default: return
        }
        lock.lock(); _settings = s; lock.unlock()
        notifyEditor()
    }

    public func hostParameter(_ address: Int) -> Double {
        let s = settings
        switch address {
        case HostParameter.volume: return Double(s.volume)
        case HostParameter.cutoff: return s.cutoff
        case HostParameter.resonance: return s.resonance
        case HostParameter.tune: return s.tune * 200 - 100
        default: return 0
        }
    }

    private func notifyEditor() {
        guard let handler = onExternalChange else { return }
        DispatchQueue.main.async { handler() }
    }

    // MARK: Saved state (what a DAW stores in a project)

    public func serialize() -> [String: Any] {
        let s = settings
        var d: [String: Any] = [
            "version": 1,
            "patch": Data(s.patch.bytes),
            "bank": s.bank.sysexData(),
            "bankName": s.bankName,
            "program": s.program,
            "volume": Double(s.volume),
            "tune": s.tune, "cutoff": s.cutoff, "resonance": s.resonance,
            "engine": s.engine.rawValue,
        ]
        if let scl = s.scl { d["scl"] = scl }
        if let kbm = s.kbm { d["kbm"] = kbm }
        if let name = s.tuningName { d["tuningName"] = name }
        return d
    }

    public func restore(_ d: [String: Any]) {
        var s = HostedSettings()
        if let b = d["patch"] as? Data { s.patch = Patch(bytes: [UInt8](b)) }
        if let b = d["bank"] as? Data, let bank = try? Cartridge(sysex: b) { s.bank = bank }
        s.bankName = d["bankName"] as? String ?? s.bankName
        s.program = d["program"] as? Int ?? 0
        s.volume = Float(d["volume"] as? Double ?? 1)
        s.tune = d["tune"] as? Double ?? 0.5
        s.cutoff = d["cutoff"] as? Double ?? 1
        s.resonance = d["resonance"] as? Double ?? 0
        s.engine = EngineType(rawValue: d["engine"] as? Int ?? 1) ?? .markI
        s.scl = d["scl"] as? String
        s.kbm = d["kbm"] as? String
        s.tuningName = d["tuningName"] as? String
        apply(s)
    }
}

/// Parameter addresses exposed to the host for automation.
public enum HostParameter {
    public static let volume = 0, cutoff = 1, resonance = 2, tune = 3
}
