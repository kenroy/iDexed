import CoreMIDI
import Foundation

/// SysEx carried in MIDI 1.0 Universal MIDI Packets (message type 3, "SysEx7"): up to six data bytes per 64-bit packet.
enum UMPSysEx {
    /// Packs a complete message (with or without the F0/F7 framing bytes) into UMP words, two per packet.
    static func words(for message: Data) -> [UInt32] {
        var payload = [UInt8](message)
        if payload.first == 0xF0 { payload.removeFirst() }
        if payload.last == 0xF7 { payload.removeLast() }

        var chunks: [[UInt8]] = []
        var i = 0
        repeat {
            chunks.append(Array(payload[i ..< min(i + 6, payload.count)]))
            i += 6
        } while i < payload.count

        var words: [UInt32] = []
        for (n, chunk) in chunks.enumerated() {
            let status: UInt32 = chunks.count == 1 ? 0 : n == 0 ? 1 : n == chunks.count - 1 ? 3 : 2     // complete / start / continue / end
            var b = chunk + [UInt8](repeating: 0, count: 6 - chunk.count)
            b = Array(b.prefix(6))
            words.append(0x3 << 28 | status << 20 | UInt32(chunk.count) << 16 | UInt32(b[0]) << 8 | UInt32(b[1]))
            words.append(UInt32(b[2]) << 24 | UInt32(b[3]) << 16 | UInt32(b[4]) << 8 | UInt32(b[5]))
        }
        return words
    }

    /// Builds MIDI event lists from SysEx words (two words per packet) and hands each to `deliver`. Words go out in batches
    /// of at most 400 packets, which is well inside the 16 KB list buffer even if every packet is stored separately
    /// (400 × (12-byte header + 8 bytes of data) ≈ 8 KB), so a list can never overflow.
    static func sendWords(_ words: [UInt32], deliver: (UnsafePointer<MIDIEventList>) -> Void) {
        let capacity = 16 * 1024
        let packetsPerList = 400
        var storage = [UInt8](repeating: 0, count: capacity)
        storage.withUnsafeMutableBytes { raw in
            let list = raw.baseAddress!.assumingMemoryBound(to: MIDIEventList.self)
            var start = 0
            while start + 1 < words.count {
                let end = min(words.count - words.count % 2, start + packetsPerList * 2)
                var packet = MIDIEventListInit(list, ._1_0)
                var i = start
                while i + 1 < end {
                    var pair = [words[i], words[i + 1]]
                    packet = MIDIEventListAdd(list, capacity, packet, 0, 2, &pair)
                    i += 2
                }
                deliver(UnsafePointer(list))
                start = end
            }
        }
    }

    /// Number of 32-bit words in a UMP message of the given message type.
    static func wordCount(forType type: UInt32) -> Int {
        switch type {
        case 0x0, 0x1, 0x2, 0x6, 0x7: 1
        case 0x3, 0x4, 0x8, 0x9, 0xA: 2
        case 0xB, 0xC: 3
        default: 4
        }
    }
}

/// Reassembles SysEx messages from a stream of UMP SysEx7 packets.
public struct SysExAssembler: Sendable {
    private var buffer: [UInt8] = []
    private var receiving = false
    public init() {}

    /// Feeds one 64-bit SysEx7 packet. Returns the complete message (F0 … F7) when this packet finishes one.
    public mutating func consume(_ w0: UInt32, _ w1: UInt32) -> Data? {
        let status = (w0 >> 20) & 0xF
        let count = min(6, Int((w0 >> 16) & 0xF))
        let bytes = [UInt8(truncatingIfNeeded: w0 >> 8), UInt8(truncatingIfNeeded: w0),
                     UInt8(truncatingIfNeeded: w1 >> 24), UInt8(truncatingIfNeeded: w1 >> 16),
                     UInt8(truncatingIfNeeded: w1 >> 8), UInt8(truncatingIfNeeded: w1)]
        let data = Array(bytes.prefix(count))
        switch status {
        case 0:                                      // complete in one packet
            receiving = false
            return Data([0xF0] + data + [0xF7])
        case 1:                                      // start
            buffer = data
            receiving = true
        case 2:                                      // continue
            if receiving { buffer += data }
        case 3:                                      // end
            guard receiving else { return nil }
            receiving = false
            let message = Data([0xF0] + buffer + data + [0xF7])
            buffer = []
            return message
        default: break
        }
        return nil
    }
}
