import CoreMIDI
import Foundation

/// Publishes a virtual MIDI source named "iDexed". Other apps on the device see it directly, and a Mac sees it
/// across a USB cable (or Network MIDI), so the on-screen keyboard can play a synth running elsewhere with
/// very little delay.
public final class MIDIOutput: @unchecked Sendable {
    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()
    private var started = false

    public init() {}

    /// The endpoint other code (e.g. `MIDIInput`) should ignore so we never hear ourselves.
    public var endpoint: MIDIEndpointRef { source }

    public func start() {
        guard !started else { return }
        started = true
        MIDIClientCreateWithBlock("iDexed Out" as CFString, &client) { _ in }
        MIDISourceCreateWithProtocol(client, "iDexed" as CFString, ._1_0, &source)
    }

    public func stop() {
        guard started else { return }
        started = false
        if source != 0 { MIDIEndpointDispose(source); source = 0 }
        if client != 0 { MIDIClientDispose(client); client = 0 }
    }

    public func noteOn(_ note: Int, velocity: Int, channel: Int = 1) { send(0x90, channel, note, velocity) }
    public func noteOff(_ note: Int, channel: Int = 1) { send(0x80, channel, note, 0) }
    public func controlChange(_ cc: Int, _ value: Int, channel: Int = 1) { send(0xB0, channel, cc, value) }
    public func pitchBend(_ value14: Int, channel: Int = 1) { send(0xE0, channel, value14 & 0x7F, (value14 >> 7) & 0x7F) }
    public func programChange(_ program: Int, channel: Int = 1) { send(0xC0, channel, program, 0) }
    public func allNotesOff(channel: Int = 1) { controlChange(123, 0, channel: channel) }

    /// Sends a complete system-exclusive message (with or without F0/F7) through the virtual source.
    public func sendSysEx(_ message: Data) {
        guard started, source != 0 else { return }
        let target = source
        UMPSysEx.sendWords(UMPSysEx.words(for: message)) { MIDIReceivedEventList(target, $0) }
    }

    private func send(_ status: UInt32, _ channel: Int, _ d1: Int, _ d2: Int) {
        guard started, source != 0 else { return }
        // UMP "MIDI 1.0 channel voice" word: message type 2, group 0.
        var word: UInt32 = (0x2 << 28) | ((status | UInt32((channel - 1) & 0x0F)) << 16)
            | (UInt32(d1 & 0x7F) << 8) | UInt32(d2 & 0x7F)
        var storage = [UInt8](repeating: 0, count: 256)
        storage.withUnsafeMutableBytes { raw in
            let list = raw.baseAddress!.assumingMemoryBound(to: MIDIEventList.self)
            let packet = MIDIEventListInit(list, ._1_0)
            _ = MIDIEventListAdd(list, raw.count, packet, 0, 1, &word)
            MIDIReceivedEventList(source, list)
        }
    }
}
