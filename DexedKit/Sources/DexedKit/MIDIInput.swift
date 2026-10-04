import CoreMIDI
import Foundation

/// Listens to every MIDI source (hardware, USB, network, virtual) and forwards channel messages.
public final class MIDIInput: @unchecked Sendable {
    public var onMessage: (@Sendable (UInt8, UInt8, UInt8) -> Void)?
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
            let count = Int(packet.pointee.wordCount)
            withUnsafePointer(to: packet.pointee.words) { tuple in
                tuple.withMemoryRebound(to: UInt32.self, capacity: 64) { words in
                    for i in 0..<count {
                        let w = words[i]
                        guard (w >> 28) == 0x2 else { continue }  // MIDI 1.0 channel voice
                        let status = UInt8((w >> 16) & 0xFF)
                        let d1 = UInt8((w >> 8) & 0x7F)
                        let d2 = UInt8(w & 0x7F)
                        onMessage?(status, d1, d2)
                    }
                }
            }
        }
    }
}
