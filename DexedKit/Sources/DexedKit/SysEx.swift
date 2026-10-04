import Foundation

public enum SysExError: Error, LocalizedError {
    case noVoiceData
    public var errorDescription: String? { "No DX7 voice data found in this file." }
}

/// A 32-voice DX7 bank (the packed 4096-byte bulk dump).
public struct Cartridge: Equatable, Sendable {
    public static let voiceCount = 32
    public static let packedVoiceSize = 128
    public static let bulkHeader: [UInt8] = [0xF0, 0x43, 0x00, 0x09, 0x20, 0x00]

    /// 32 × 128 bytes of packed voice data.
    public var packed: [UInt8]

    public init() {
        packed = []
        for _ in 0..<Cartridge.voiceCount { packed += Cartridge.pack(.initVoice) }
    }

    public init(patches: [Patch]) {
        packed = []
        for i in 0..<Cartridge.voiceCount {
            packed += Cartridge.pack(i < patches.count ? patches[i] : .initVoice)
        }
    }

    /// Parses a `.syx` file/stream: a 32-voice bulk dump or a single-voice dump.
    /// Tolerates leading/trailing junk, like Dexed does.
    public init(sysex data: Data) throws {
        let b = [UInt8](data)
        if let start = Cartridge.find(Cartridge.bulkHeader, in: b), b.count >= start + 6 + 4096 {
            self.init()
            packed = Array(b[(start + 6) ..< (start + 6 + 4096)])
            return
        }
        // Single voice: F0 43 0n 00 01 1B <155 bytes> cs F7
        let single: [UInt8] = [0xF0, 0x43]
        if let s = Cartridge.find(single, in: b), b.count >= s + 163, b[s + 3] == 0x00, b[s + 4] == 0x01 {
            let p = Patch(bytes: Array(b[(s + 6) ..< (s + 6 + 155)]))
            var all = [Patch](repeating: .initVoice, count: Cartridge.voiceCount)
            all[0] = p
            self.init(patches: all)
            return
        }
        throw SysExError.noVoiceData
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard hay.count >= needle.count else { return nil }
        for i in 0...(hay.count - needle.count) where Array(hay[i ..< i + needle.count]) == needle { return i }
        return nil
    }

    public func patch(at index: Int) -> Patch { Cartridge.unpack(packed, voice: index) }

    public mutating func setPatch(_ patch: Patch, at index: Int) {
        let o = index * Cartridge.packedVoiceSize
        packed.replaceSubrange(o ..< o + Cartridge.packedVoiceSize, with: Cartridge.pack(patch))
    }

    public var names: [String] { (0..<Cartridge.voiceCount).map { patch(at: $0).name } }

    /// Full bulk-dump `.syx` bytes (with header, checksum and EOX).
    public func sysexData() -> Data {
        var out = Cartridge.bulkHeader
        out += packed
        out.append(Cartridge.checksum(packed))
        out.append(0xF7)
        return Data(out)
    }

    /// Single-voice edit-buffer dump for sending to hardware.
    public static func singleVoiceSysex(_ p: Patch, channel: Int = 0) -> Data {
        var out: [UInt8] = [0xF0, 0x43, UInt8(channel & 0x0F), 0x00, 0x01, 0x1B]
        let body = Array(p.bytes.prefix(155))
        out += body
        out.append(checksum(body))
        out.append(0xF7)
        return Data(out)
    }

    static func checksum(_ bytes: [UInt8]) -> UInt8 {
        var sum = 0
        for b in bytes { sum -= Int(b) }
        return UInt8(sum & 0x7F)
    }

    // MARK: Packing (mirrors Cartridge::packProgram / unpackProgram in Dexed)

    static func pack(_ p: Patch) -> [UInt8] {
        let s = p.bytes
        var d = [UInt8](repeating: 0, count: 128)
        for op in 0..<6 {
            let pp = op * 17, up = op * 21
            for i in 0..<11 { d[pp + i] = s[up + i] }
            d[pp + 11] = (s[up + 11] & 0x03) | ((s[up + 12] & 0x03) << 2)
            d[pp + 12] = (s[up + 13] & 0x07) | ((s[up + 20] & 0x0F) << 3)
            d[pp + 13] = (s[up + 14] & 0x03) | ((s[up + 15] & 0x07) << 2)
            d[pp + 14] = s[up + 16]
            d[pp + 15] = (s[up + 17] & 0x01) | ((s[up + 18] & 0x1F) << 1)
            d[pp + 16] = s[up + 19]
        }
        for i in 0..<9 { d[102 + i] = s[126 + i] }
        d[111] = (s[135] & 0x07) | ((s[136] & 0x01) << 3)
        for i in 0..<4 { d[112 + i] = s[137 + i] }
        d[116] = (s[141] & 0x01) | ((s[142] & 0x07) << 1) | ((s[143] & 0x07) << 4)
        d[117] = s[144]
        for i in 0..<10 { d[118 + i] = s[145 + i] }
        return d
    }

    static func unpack(_ packed: [UInt8], voice: Int) -> Patch {
        let base = voice * packedVoiceSize
        let b = Array(packed[base ..< base + packedVoiceSize])
        var u = [UInt8](repeating: 0, count: Patch.size)
        func clampMax(_ v: UInt8, _ m: UInt8) -> UInt8 { v <= m ? v : UInt8(Float(v) / 255 * Float(m)) }
        for op in 0..<6 {
            let pp = op * 17, up = op * 21
            for i in 0..<11 { u[up + i] = clampMax(b[pp + i] & 0x7F, 99) }
            let curves = b[pp + 11] & 0x0F
            u[up + 11] = curves & 3
            u[up + 12] = (curves >> 2) & 3
            let detuneRS = b[pp + 12] & 0x7F
            u[up + 13] = detuneRS & 7
            let kvsAms = b[pp + 13] & 0x1F
            u[up + 14] = kvsAms & 3
            u[up + 15] = (kvsAms >> 2) & 7
            u[up + 16] = min(b[pp + 14] & 0x7F, 99)
            let fc = b[pp + 15] & 0x3F
            u[up + 17] = fc & 1
            u[up + 18] = (fc >> 1) & 0x1F
            u[up + 19] = min(b[pp + 16] & 0x7F, 99)
            u[up + 20] = min((detuneRS >> 3) & 0x0F, 14)
        }
        for i in 0..<8 { u[126 + i] = min(b[102 + i] & 0x7F, 99) }
        u[134] = min(b[110] & 0x1F, 31)
        u[135] = b[111] & 0x07
        u[136] = (b[111] >> 3) & 1
        for i in 0..<4 { u[137 + i] = min(b[112 + i] & 0x7F, 99) }
        u[141] = b[116] & 1
        u[142] = min((b[116] >> 1) & 7, 5)
        u[143] = (b[116] >> 4) & 7
        u[144] = min(b[117] & 0x7F, 48)
        for i in 0..<10 { u[145 + i] = b[118 + i] & 0x7F }
        return Patch(bytes: u)
    }
}
