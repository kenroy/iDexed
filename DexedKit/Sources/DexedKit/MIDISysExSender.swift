import CoreMIDI
import Foundation

/// A MIDI output the user can send to (a hardware DX7's interface, another app's input, a network session…).
public struct MIDIPortInfo: Identifiable, Hashable, Sendable {
    public let id: Int32            // CoreMIDI unique ID: stable across launches and re-plugging
    public let name: String
    public init(id: Int32, name: String) { self.id = id; self.name = name }
}

/// Sends system-exclusive messages to a chosen MIDI destination, for example a real DX7.
///
/// Uses CoreMIDI's byte-oriented `MIDISendSysex`, which is made for large messages: the system paces the bytes to the
/// device (a DX7 bank takes over a second at MIDI speed) and delivers them intact. The list-based API dropped packets
/// when sending a full bank.
public final class MIDISysExSender: @unchecked Sendable {
    public init() {}

    /// Every MIDI destination currently available.
    public static func destinations() -> [MIDIPortInfo] {
        (0..<MIDIGetNumberOfDestinations()).compactMap { index in
            let endpoint = MIDIGetDestination(index)
            var uid: Int32 = 0
            guard MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uid) == noErr else { return nil }
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name)
            return MIDIPortInfo(id: uid, name: (name?.takeRetainedValue() as String?) ?? "MIDI Port \(index + 1)")
        }
    }

    /// Sends a complete message (F0 … F7) to the destination with this unique ID. Returns false if it isn't available.
    /// The send is asynchronous. CoreMIDI advances the request's data pointer while sending, so the original buffers are
    /// tracked separately and released a moment after it reports completion.
    @discardableResult
    public func send(_ message: Data, to destinationID: Int32) -> Bool {
        var object = MIDIObjectRef()
        var type = MIDIObjectType.other
        guard !message.isEmpty, MIDIObjectFindByUniqueID(destinationID, &object, &type) == noErr, type == .destination else { return false }

        let context = SysExRequestContext(message)
        context.request.initialize(to: MIDISysexSendRequest(
            destination: object, data: UnsafePointer(context.bytes), bytesToSend: UInt32(message.count), complete: false,
            reserved: (0, 0, 0),
            completionProc: { done in
                guard let refCon = done.pointee.completionRefCon else { return }
                // Release after CoreMIDI has fully finished with the request, not from inside its callback.
                let box = SendableRetained(Unmanaged<SysExRequestContext>.fromOpaque(refCon))
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) { box.value.release() }
            },
            completionRefCon: Unmanaged.passRetained(context).toOpaque()))
        guard MIDISendSysex(context.request) == noErr else {
            Unmanaged.passUnretained(context).release()      // balance the retain taken for the refcon
            return false
        }
        return true
    }
}

private struct SendableRetained: @unchecked Sendable {
    let value: Unmanaged<SysExRequestContext>
    init(_ value: Unmanaged<SysExRequestContext>) { self.value = value }
}

/// Owns the memory behind one asynchronous SysEx send.
private final class SysExRequestContext {
    let bytes: UnsafeMutablePointer<UInt8>
    let request = UnsafeMutablePointer<MIDISysexSendRequest>.allocate(capacity: 1)

    init(_ message: Data) {
        bytes = .allocate(capacity: message.count)
        message.copyBytes(to: bytes, count: message.count)
    }

    deinit {
        bytes.deallocate()
        request.deallocate()
    }
}
