import Foundation

/// The Yamaha DX7 system-exclusive messages Dexed understands: voice and bank dumps, single-parameter edits (including the
/// operator on/off switches at offset 155) and requests for a dump.
public enum SysExMessage: Equatable, Sendable {
    public enum RequestKind: Equatable, Sendable { case voice, bank }

    case voice(Patch, checksumOK: Bool)
    case bank(Cartridge)
    case parameterChange(offset: Int, value: Int)
    case request(RequestKind)

    /// Parses a complete message (F0 … F7). Returns nil if it isn't a DX7-style message we handle.
    public static func parse(_ data: Data) -> SysExMessage? {
        let b = [UInt8](data)
        guard b.count >= 5, b[0] == 0xF0, b[1] == 0x43 else { return nil }
        switch b[2] >> 4 {
        case 0:
            if b[3] == 0, b.count >= 161 {                                   // single voice: header 6 + 155 bytes
                let body = Array(b[6 ..< 161])
                let ok = b.count > 161 ? Cartridge.checksum(body) == b[161] : false
                return .voice(Patch(bytes: body), checksumOK: ok)
            }
            if b[3] == 9, b.count >= 4104, let bank = try? Cartridge(sysex: data) { return .bank(bank) }
            return nil
        case 1:
            guard b.count >= 7 else { return nil }
            let offset = Int(b[3]) << 7 | Int(b[4])
            guard offset <= 155 else { return nil }
            return .parameterChange(offset: offset, value: Int(b[5]))
        case 2:
            if b[3] == 0 { return .request(.voice) }
            if b[3] == 9 { return .request(.bank) }
            return nil
        default:
            return nil
        }
    }

    /// F0 43 1n pp pp vv F7 — set one voice parameter (offset 155 = the six operator switches, bit 0 = OP6).
    public static func parameterChange(channel: Int, offset: Int, value: Int) -> Data {
        Data([0xF0, 0x43, 0x10 | UInt8(channel & 0x0F), UInt8((offset >> 7) & 0x7F), UInt8(offset & 0x7F), UInt8(value & 0x7F), 0xF7])
    }

    /// F0 43 2n 00|09 F7 — ask the device to send its current voice or bank.
    public static func request(channel: Int, _ kind: RequestKind) -> Data {
        Data([0xF0, 0x43, 0x20 | UInt8(channel & 0x0F), kind == .voice ? 0x00 : 0x09, 0xF7])
    }
}
