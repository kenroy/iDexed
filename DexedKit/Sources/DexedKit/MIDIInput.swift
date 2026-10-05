import CoreMIDI
import Foundation

/// Listens to every MIDI source (hardware, USB, network, virtual) and forwards channel messages.
public final class MIDIInput: @unchecked Sendable {
    public var onMessage: (@Sendable (UInt8, UInt8, UInt8) -> Void)?
    /// A complete system-exclusive message (F0 … F7), reassembled from the incoming packets.
    public var onSysEx: (@Sendable (Data) -> Void)?
    private var assembler = SysExAssembler()
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var started = false
    /// Endpoints to skip, e.g. our own virtual output, so notes we send aren't played back locally.
    public var ignoredSources: Set<MIDIEndpointRef> = []

    public init() {}

    public func start() {
        guard !started else { return }
        started = true
        MIDIClientCreateWithBlock("Dexed" as CFString, &client) { [weak self] note in
            if note.pointee.messageID == .msgSetupChanged { self?.connectAllSources() }
        }
        MIDIInputPortCreateWithProtocol(client, "Input" as CFString, ._1_0, &port) { [weak self] list, _ in
            self?.handle(list)
        }
        connectAllSources()
    }

    private func connectAllSources() {
        for i in 0..<MIDIGetNumberOfSources() {
            let endpoint = MIDIGetSource(i)
            if ignoredSources.contains(endpoint) { continue }
            MIDIPortConnectSource(port, endpoint, nil)
        }
    }

    private func handle(_ list: UnsafePointer<MIDIEventList>) {
        for packet in list.unsafeSequence() {
            // A packet can hold more than the 64 words its Swift struct declares (SysEx often arrives in packets of
            // 80+ words), so read the words in place instead of through a copy of the struct.
            let count = Int(packet.pointee.wordCount)
            let words = (UnsafeRawPointer(packet) + MemoryLayout<MIDIEventPacket>.offset(of: \.words)!).assumingMemoryBound(to: UInt32.self)
            var i = 0
            while i < count {
                let w = words[i]
                let type = w >> 28
                if type == 0x2 {                                  // MIDI 1.0 channel voice message
                    onMessage?(UInt8((w >> 16) & 0xFF), UInt8((w >> 8) & 0x7F), UInt8(w & 0x7F))
                } else if type == 0x3, i + 1 < count {            // SysEx7 packet (two words)
                    if let message = assembler.consume(w, words[i + 1]) { onSysEx?(message) }
                }
                i += UMPSysEx.wordCount(forType: type)
            }
        }
    }
}
