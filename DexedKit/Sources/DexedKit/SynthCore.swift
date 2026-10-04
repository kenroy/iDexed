import CDexedEngine
import Foundation

public struct SynthStatus: Equatable, Sendable {
    public var operatorLevels = [Float](repeating: 0, count: 6)   // 0…1 per operator, OP1 first
    public var operatorStages = [Int](repeating: -1, count: 6)    // envelope stage 0…3, −1 when silent
    public var pitchStage = -1
    public var outputLevel: Float = 0                              // 0…1 peak with decay
    public var heldNotes = Set<Int>()
    public init(operatorLevels: [Float] = [Float](repeating: 0, count: 6), operatorStages: [Int] = [Int](repeating: -1, count: 6),
                pitchStage: Int = -1, outputLevel: Float = 0, heldNotes: Set<Int> = []) {
        self.operatorLevels = operatorLevels; self.operatorStages = operatorStages
        self.pitchStage = pitchStage; self.outputLevel = outputLevel; self.heldNotes = heldNotes
    }
}

public enum EngineType: Int, CaseIterable, Identifiable, Sendable {
    case modern = 0, markI = 1, opl = 2
    public var id: Int { rawValue }
    public var title: String {
        switch self {
        case .modern: "Modern"
        case .markI: "Mark I"
        case .opl: "OPL"
        }
    }
}

public enum ModSource: Int, CaseIterable, Identifiable, Sendable {
    case wheel = 0, foot, breath, aftertouch
    public var id: Int { rawValue }
    public var title: String { ["Mod Wheel", "Foot", "Breath", "Aftertouch"][rawValue] }
}

/// Thin thread-safe wrapper over the C engine. Every call may be made from any thread
/// (MIDI callback, UI, tests); the engine applies them on the audio thread.
public final class SynthCore: @unchecked Sendable {
    private let synth: OpaquePointer
    public private(set) var sampleRate: Double

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        synth = dexed_create(sampleRate)
    }

    deinit { dexed_destroy(synth) }

    /// Changes the sample rate and silences all voices. Only call while nothing is rendering.
    public func resetSampleRate(_ rate: Double) {
        guard rate != sampleRate else { return }
        dexed_set_sample_rate(synth, rate)
        sampleRate = rate
    }

    public func setPatch(_ p: Patch) { p.bytes.withUnsafeBufferPointer { dexed_set_patch(synth, $0.baseAddress) } }
    public func setParam(_ offset: Int, _ value: Int) { dexed_set_param(synth, Int32(offset), Int32(value)) }
    public func noteOn(_ note: Int, velocity: Int, channel: Int = 1) { dexed_note_on(synth, Int32(channel), Int32(note), Int32(velocity)) }
    public func noteOff(_ note: Int, channel: Int = 1) { dexed_note_off(synth, Int32(channel), Int32(note)) }
    public func pitchBend(_ v14: Int) { dexed_pitch_bend(synth, Int32(v14)) }
    public func controlChange(_ cc: Int, _ v: Int) { dexed_control_change(synth, Int32(cc), Int32(v)) }
    public func aftertouch(_ v: Int) { dexed_aftertouch(synth, Int32(v)) }
    public func panic() { dexed_panic(synth) }
    public func setMono(_ on: Bool) { dexed_set_mono(synth, on) }
    public func setEngine(_ e: EngineType) { dexed_set_engine(synth, Int32(e.rawValue)) }
    public func setOperatorMask(_ mask: Int) { dexed_set_op_mask(synth, Int32(mask)) }
    /// Master tune, normalised 0…1 (0.5 = in tune; the full range is ±1 semitone, as in Dexed).
    public func setMasterTune(_ value: Double) { dexed_set_master_tune(synth, Float(value)) }
    /// Output low-pass filter. `cutoff` 1 = open (bypassed); both are normalised 0…1.
    public func setFilter(cutoff: Double, resonance: Double) { dexed_set_filter(synth, Float(cutoff), Float(resonance)) }
    /// Applies Scala microtuning. Pass `nil` for `scl` to return to standard 12-TET.
    /// Returns an error message if the files can't be parsed, otherwise `nil`.
    @discardableResult
    public func setTuning(scl: String?, kbm: String? = nil) -> String? {
        var error = [CChar](repeating: 0, count: 256)
        let ok = dexed_set_tuning(synth, scl, kbm, &error, 256)
        guard !ok else { return nil }
        let bytes = error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }     // up to the C string's terminator
        return String(decoding: bytes, as: UTF8.self)
    }
    public func setPitchRange(up: Int, down: Int, step: Int) { dexed_set_pitch_range(synth, Int32(up), Int32(down), Int32(step)) }
    public func setMod(_ s: ModSource, range: Int, pitch: Bool, amp: Bool, eg: Bool) {
        dexed_set_mod(synth, Int32(s.rawValue), Int32(range), pitch, amp, eg)
    }

    /// Renders mono samples. Call from one thread only (the audio render thread, or a test).
    public func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        dexed_render(synth, buffer, Int32(frames))
    }

    public func render(frames: Int) -> [Float] {
        var out = [Float](repeating: 0, count: frames)
        out.withUnsafeMutableBufferPointer { render(into: $0.baseAddress!, frames: frames) }
        return out
    }

    /// Latest metering snapshot. Operator arrays are indexed OP1 … OP6.
    public func status() -> SynthStatus {
        var raw = DexedStatus()
        dexed_get_status(synth, &raw)
        let amps = withUnsafeBytes(of: raw.opAmp) { Array($0.bindMemory(to: UInt32.self)) }
        let stages = withUnsafeBytes(of: raw.opStage) { Array($0.bindMemory(to: Int8.self)) }
        // Normalisation constants from Dexed's editor (determined from the OPL engine's range).
        let minAmp: Double = 1_036_152, maxAmp: Double = 259_037_922
        var levels = [Float](repeating: 0, count: 6), steps = [Int](repeating: -1, count: 6)
        for op in 0..<6 {
            let i = 5 - op
            levels[op] = Float(max(0, min(1, (Double(amps[i]) - minAmp) / (maxAmp - minAmp))))
            steps[op] = Int(stages[i])
        }
        var held = Set<Int>()
        withUnsafeBytes(of: raw.heldNotes) { words in
            let w = words.bindMemory(to: UInt64.self)
            for n in 0..<128 where w[n >> 6] & (1 << UInt64(n & 63)) != 0 { held.insert(n) }
        }
        return SynthStatus(operatorLevels: levels, operatorStages: steps, pitchStage: Int(raw.pitchStage),
                           outputLevel: raw.outputLevel, heldNotes: held)
    }

    /// Dispatches a raw 3-byte MIDI 1.0 channel message.
    public func handleMIDI(status: UInt8, data1: UInt8, data2: UInt8) {
        let ch = Int(status & 0x0F) + 1
        switch status & 0xF0 {
        case 0x80: noteOff(Int(data1), channel: ch)
        case 0x90: data2 == 0 ? noteOff(Int(data1), channel: ch) : noteOn(Int(data1), velocity: Int(data2), channel: ch)
        case 0xB0: controlChange(Int(data1), Int(data2))
        case 0xD0: aftertouch(Int(data1))
        case 0xE0: pitchBend(Int(data1) | (Int(data2) << 7))
        default: break
        }
    }
}
