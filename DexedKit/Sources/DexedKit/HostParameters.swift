import Foundation

/// One parameter the plug-in offers to the host for automation. Values are integers in the range the host shows
/// (for example Algorithm 1…32, Transpose −24…+24); `shift` converts them to the stored DX7 byte.
public struct HostParameterSpec: Sendable, Identifiable {
    public enum Target: Sendable {
        /// A byte of the voice (offset into the 156-byte patch).
        case voice(offset: Int)
        /// The engine type, kept in the session settings.
        case engine
        /// Everything else the editor owns (controllers, portamento, operator switches…), kept in `HostedSettings.extra`.
        case extra
    }

    public var id: Int { address }
    public let address: Int
    public let identifier: String
    public let name: String
    /// "Op1"…"Op6", "Voice" or "Controllers": how a host groups it.
    public let group: String
    public let min: Int
    public let max: Int
    public let defaultValue: Int
    /// Names for each value from `min`, which makes the parameter a list in the host.
    public let labels: [String]?
    public let isBoolean: Bool
    public let target: Target
}

/// Addresses of the parameters beyond the four the first versions exposed. They are part of saved automation, so they
/// must not change.
public extension HostParameter {
    static let voiceBase = 1000            // + patch byte offset
    static let engine = 2000
    static let mono = 2001, glissando = 2002, portamentoTime = 2003, transposeAsScale = 2004
    static let bendUp = 2005, bendDown = 2006, bendStep = 2007
    static func controller(_ source: Int, _ field: Int) -> Int { 2100 + 10 * source + field }   // field: 0 range, 1 pitch, 2 amp, 3 EG
    static func operatorSwitch(_ op: Int) -> Int { 2200 + op }                                  // op 0 = OP1
}

public enum HostParameters {
    private static func breakpointName(_ value: Int) -> String {
        let names = ["A", "A#", "B", "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#"]
        return "\(names[value % 12])\((value + 9) / 12 - 1)"
    }

    /// Every voice, engine and controller parameter, in the order a host lists them. (Volume, Cutoff, Resonance and Tune
    /// are separate: they are floats with their own addresses 0…3.)
    public static let all: [HostParameterSpec] = {
        var list: [HostParameterSpec] = []
        let initial = Patch.initVoice

        func voice(_ offset: Int, _ id: String, _ name: String, group: String, min: Int = 0, max: Int,
                   labels: [String]? = nil, boolean: Bool = false) {
            let stored = Int(initial.bytes[offset])
            list.append(HostParameterSpec(address: HostParameter.voiceBase + offset, identifier: id, name: name, group: group,
                                          min: min, max: max, defaultValue: stored + min, labels: labels, isBoolean: boolean,
                                          target: .voice(offset: offset)))
        }
        func extra(_ address: Int, _ id: String, _ name: String, max: Int, defaultValue: Int, labels: [String]? = nil, boolean: Bool = false) {
            list.append(HostParameterSpec(address: address, identifier: id, name: name, group: "Controllers", min: 0, max: max,
                                          defaultValue: defaultValue, labels: labels, isBoolean: boolean, target: .extra))
        }

        // Global voice
        voice(134, "algorithm", "Algorithm", group: "Voice", min: 1, max: 32)
        voice(135, "feedback", "Feedback", group: "Voice", max: 7)
        voice(137, "lfoRate", "LFO Rate", group: "Voice", max: 99)
        voice(138, "lfoDelay", "LFO Delay", group: "Voice", max: 99)
        voice(139, "lfoPitchModDepth", "LFO Pitch Mod Depth", group: "Voice", max: 99)
        voice(140, "lfoAmpModDepth", "LFO Amp Mod Depth", group: "Voice", max: 99)
        voice(141, "lfoKeySync", "LFO Key Sync", group: "Voice", max: 1, boolean: true)
        voice(136, "oscKeySync", "OSC Key Sync", group: "Voice", max: 1, boolean: true)
        voice(142, "lfoWaveform", "LFO Waveform", group: "Voice", max: 5, labels: ["Triangle", "Saw Down", "Saw Up", "Square", "Sine", "S&H"])
        voice(144, "transpose", "Transpose", group: "Voice", min: -24, max: 24)
        voice(143, "pitchModSens", "Pitch Mod Sens", group: "Voice", max: 7)
        for i in 0..<4 {
            voice(126 + i, "pitchEgRate\(i + 1)", "Pitch EG Rate \(i + 1)", group: "Voice", max: 99)
            voice(130 + i, "pitchEgLevel\(i + 1)", "Pitch EG Level \(i + 1)", group: "Voice", max: 99)
        }

        // Operators: OP1 is stored last in the patch.
        for op in 0..<6 {
            let g = "Op\(op + 1)", p = "op\(op + 1)", n = "Op\(op + 1) "
            func at(_ f: OperatorField) -> Int { Patch.offset(op: op, f) }
            let rates: [OperatorField] = [.rate1, .rate2, .rate3, .rate4], levels: [OperatorField] = [.level1, .level2, .level3, .level4]
            for j in 0..<4 {
                voice(at(rates[j]), "\(p)_egRate\(j + 1)", "\(n)EG Rate \(j + 1)", group: g, max: 99)
                voice(at(levels[j]), "\(p)_egLevel\(j + 1)", "\(n)EG Level \(j + 1)", group: g, max: 99)
            }
            voice(at(.oscMode), "\(p)_oscMode", "\(n)Osc Mode", group: g, max: 1, labels: ["Ratio", "Fixed"])
            voice(at(.freqCoarse), "\(p)_freqCoarse", "\(n)Freq Coarse", group: g, max: 31)
            voice(at(.freqFine), "\(p)_freqFine", "\(n)Freq Fine", group: g, max: 99)
            voice(at(.detune), "\(p)_detune", "\(n)Detune", group: g, min: -7, max: 7)
            voice(at(.breakPoint), "\(p)_breakpoint", "\(n)Breakpoint", group: g, max: 99, labels: (0...99).map(breakpointName))
            voice(at(.leftDepth), "\(p)_leftDepth", "\(n)L Scale Depth", group: g, max: 99)
            voice(at(.rightDepth), "\(p)_rightDepth", "\(n)R Scale Depth", group: g, max: 99)
            voice(at(.leftCurve), "\(p)_leftCurve", "\(n)L Key Scale", group: g, max: 3, labels: Parameters.curves)
            voice(at(.rightCurve), "\(p)_rightCurve", "\(n)R Key Scale", group: g, max: 3, labels: Parameters.curves)
            voice(at(.rateScaling), "\(p)_rateScaling", "\(n)Rate Scaling", group: g, max: 7)
            voice(at(.ampModSens), "\(p)_ampModSens", "\(n)Amp Mod Sens", group: g, max: 3)
            voice(at(.keyVelSens), "\(p)_keyVelocity", "\(n)Key Velocity", group: g, max: 7)
            list.append(HostParameterSpec(address: HostParameter.operatorSwitch(op), identifier: "\(p)_switch", name: "\(n)Switch", group: g,
                                          min: 0, max: 1, defaultValue: 1, labels: nil, isBoolean: true, target: .extra))
            voice(at(.outputLevel), "\(p)_outputLevel", "\(n)Output Level", group: g, max: 99)
        }

        // Modes, bend and controllers
        list.append(HostParameterSpec(address: HostParameter.engine, identifier: "engine", name: "Engine Type", group: "Controllers", min: 0, max: 2,
                                      defaultValue: EngineType.markI.rawValue, labels: ["Modern (24-bit)", "Mark I", "OPL Series"],
                                      isBoolean: false, target: .engine))
        extra(HostParameter.mono, "mono", "Mono Mode", max: 1, defaultValue: 0, boolean: true)
        extra(HostParameter.glissando, "glissando", "Glissando", max: 1, defaultValue: 0, boolean: true)
        extra(HostParameter.portamentoTime, "portamentoTime", "Portamento Time", max: 99, defaultValue: 0)
        extra(HostParameter.transposeAsScale, "transposeAsScale", "Transpose 12 as Scale", max: 1, defaultValue: 1, boolean: true)
        extra(HostParameter.bendUp, "pitchBendUp", "Pitch Bend Up", max: 48, defaultValue: 3)
        extra(HostParameter.bendDown, "pitchBendDown", "Pitch Bend Down", max: 48, defaultValue: 3)
        extra(HostParameter.bendStep, "pitchBendStep", "Pitch Bend Step", max: 12, defaultValue: 0)
        for source in ModSource.allCases {
            let d = ControllerRouting.defaults[source] ?? ControllerRouting(range: 0)
            let k = source.rawValue, t = source.title, i = t.lowercased().replacingOccurrences(of: " ", with: "")
            extra(HostParameter.controller(k, 0), "\(i)_range", "\(t) Range", max: 127, defaultValue: d.range)
            extra(HostParameter.controller(k, 1), "\(i)_pitch", "\(t) Pitch", max: 1, defaultValue: d.pitch ? 1 : 0, boolean: true)
            extra(HostParameter.controller(k, 2), "\(i)_amp", "\(t) Amp", max: 1, defaultValue: d.amp ? 1 : 0, boolean: true)
            extra(HostParameter.controller(k, 3), "\(i)_eg", "\(t) EG Bias", max: 1, defaultValue: d.eg ? 1 : 0, boolean: true)
        }
        return list
    }()

    private static let byAddress: [Int: HostParameterSpec] = Dictionary(uniqueKeysWithValues: all.map { ($0.address, $0) })

    public static func spec(for address: Int) -> HostParameterSpec? { byAddress[address] }

    /// The values of every `.extra` parameter at their defaults.
    public static let defaultExtras: [Int: Int] = Dictionary(uniqueKeysWithValues:
        all.filter { if case .extra = $0.target { true } else { false } }.map { ($0.address, $0.defaultValue) })

    /// Pushes the extras (mono, operator switches, portamento, bend, controller routing…) into the engine.
    public static func applyExtras(_ extra: [Int: Int], to core: SynthCore) {
        func v(_ address: Int) -> Int { extra[address] ?? defaultExtras[address] ?? 0 }
        core.setMono(v(HostParameter.mono) != 0)
        var mask = 0
        for op in 0..<6 where v(HostParameter.operatorSwitch(op)) != 0 { mask |= 1 << (5 - op) }
        core.setOperatorMask(mask)
        core.setPortamento(time: Int((Float(v(HostParameter.portamentoTime)) * 127 / 100).rounded()), glissando: v(HostParameter.glissando) != 0)
        core.setPitchRange(up: v(HostParameter.bendUp), down: v(HostParameter.bendDown), step: v(HostParameter.bendStep))
        core.setTransposeAsScale(v(HostParameter.transposeAsScale) != 0)
        for source in ModSource.allCases {
            let k = source.rawValue
            core.setMod(source, range: v(HostParameter.controller(k, 0)), pitch: v(HostParameter.controller(k, 1)) != 0,
                        amp: v(HostParameter.controller(k, 2)) != 0, eg: v(HostParameter.controller(k, 3)) != 0)
        }
    }
}
