import AudioToolbox
import AVFoundation
import CoreAudioKit

/// AUv3 instrument wrapping the Dexed engine. Lives in DexedKit so it can be unit-tested without a host.
public final class DexedAudioUnit: AUAudioUnit, @unchecked Sendable {
    public let session = HostedSession()

    private var outputBusArray: AUAudioUnitBusArray!
    private var _parameterTree: AUParameterTree!
    private let scratch = RenderScratch(capacity: 16384)

    public override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let bus = try AUAudioUnitBus(format: format)
        bus.maximumChannelCount = 2
        try super.init(componentDescription: componentDescription, options: options)
        outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [bus])
        maximumFramesToRender = 1024
        buildParameterTree()
    }

    public override var outputBusses: AUAudioUnitBusArray { outputBusArray }
    public override var channelCapabilities: [NSNumber]? { [0, 2] }   // no inputs, stereo out
    public override var parameterTree: AUParameterTree? { get { _parameterTree } set {} }

    // MARK: Parameters

    private func buildParameterTree() {
        func make(_ id: String, _ name: String, _ address: Int, _ min: Float, _ max: Float, _ unit: AudioUnitParameterUnit) -> AUParameter {
            AUParameterTree.createParameter(withIdentifier: id, name: name, address: AUParameterAddress(address),
                                            min: min, max: max, unit: unit, unitName: nil, flags: [.flag_IsReadable, .flag_IsWritable],
                                            valueStrings: nil, dependentParameters: nil)
        }
        let params = [
            make("volume", "Volume", HostParameter.volume, 0, 1, .linearGain),
            make("cutoff", "Cutoff", HostParameter.cutoff, 0, 1, .generic),
            make("resonance", "Resonance", HostParameter.resonance, 0, 1, .generic),
            make("tune", "Tune", HostParameter.tune, -100, 100, .cents),
        ]
        params[0].value = 1; params[1].value = 1; params[2].value = 0; params[3].value = 0
        _parameterTree = AUParameterTree.createTree(withChildren: params)
        let session = self.session
        _parameterTree.implementorValueObserver = { param, value in
            session.setHostParameter(Int(param.address), Double(value))
        }
        _parameterTree.implementorValueProvider = { param in
            AUValue(session.hostParameter(Int(param.address)))
        }
    }

    // MARK: Presets (the 32 voices of the loaded bank)

    public override var factoryPresets: [AUAudioUnitPreset]? {
        session.settings.bank.names.enumerated().map { index, name in
            let p = AUAudioUnitPreset()
            p.number = index
            p.name = name.isEmpty ? "Voice \(index + 1)" : name
            return p
        }
    }

    public override var currentPreset: AUAudioUnitPreset? {
        get {
            let s = session.settings
            let p = AUAudioUnitPreset()
            p.number = s.program
            p.name = s.patch.name
            return p
        }
        set {
            guard let preset = newValue, preset.number >= 0 else { return }
            session.selectProgram(preset.number)
        }
    }

    // MARK: State

    public override var fullState: [String: Any]? {
        get {
            var state = super.fullState ?? [:]
            state["iDexed"] = session.serialize()
            return state
        }
        set {
            super.fullState = newValue      // restores the generic parameter values first…
            if let saved = newValue?["iDexed"] as? [String: Any] { session.restore(saved) }   // …then our full state wins
        }
    }

    // MARK: Rendering

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        session.core.resetSampleRate(outputBusArray[0].format.sampleRate)
    }

    public override func deallocateRenderResources() {
        session.core.panic()
        super.deallocateRenderResources()
    }

    public override var internalRenderBlock: AUInternalRenderBlock {
        let core = session.core
        let scratch = self.scratch
        let session = self.session

        return { actionFlags, timestamp, frameCount, _, outputData, realtimeEvents, _ in
            let frames = min(Int(frameCount), scratch.capacity)
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)

            // Some hosts hand us buffers without memory; supply our own.
            for (i, b) in buffers.enumerated() where b.mData == nil && i < 2 {
                buffers[i].mData = UnsafeMutableRawPointer(scratch.channel[i])
                buffers[i].mDataByteSize = UInt32(frames * MemoryLayout<Float>.size)
            }

            var rendered = 0
            func renderUpTo(_ end: Int) {
                guard end > rendered else { return }
                core.render(into: scratch.mono + rendered, frames: end - rendered)
                rendered = end
            }
            func handle(_ status: UInt8, _ d1: UInt8, _ d2: UInt8) {
                if status & 0xF0 == 0xC0 {
                    let program = Int(d1)
                    DispatchQueue.main.async { session.selectProgram(program) }   // allocates; keep off the audio thread
                } else {
                    core.handleMIDI(status: status, data1: d1, data2: d2)
                }
            }

            var event = realtimeEvents
            let now = Int64(timestamp.pointee.mSampleTime)
            while let e = event {
                let offset = Int(max(0, min(Int64(frames), e.pointee.head.eventSampleTime &- now)))
                switch e.pointee.head.eventType {
                case .MIDI:
                    let m = e.pointee.MIDI
                    if m.length >= 2 {
                        renderUpTo(offset)
                        handle(m.data.0, m.data.1, m.length > 2 ? m.data.2 : 0)
                    }
                case .midiEventList:
                    renderUpTo(offset)
                    let base = UnsafeRawPointer(e)
                    let listOffset = MemoryLayout<AUMIDIEventList>.offset(of: \.eventList)!
                    let list = (base + listOffset).assumingMemoryBound(to: MIDIEventList.self)
                    for packet in list.unsafeSequence() {
                        withUnsafePointer(to: packet.pointee.words) { tuple in
                            tuple.withMemoryRebound(to: UInt32.self, capacity: 64) { words in
                                for w in 0..<Int(packet.pointee.wordCount) where (words[w] >> 28) == 0x2 {
                                    handle(UInt8((words[w] >> 16) & 0xFF), UInt8((words[w] >> 8) & 0x7F), UInt8(words[w] & 0x7F))
                                }
                            }
                        }
                    }
                default: break
                }
                event = UnsafePointer(e.pointee.head.next)
            }
            renderUpTo(frames)

            // Mono → every output channel. The plug-in's Volume is applied inside the engine (atomically).
            for b in buffers {
                guard let dst = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let n = min(frames, Int(b.mDataByteSize) / MemoryLayout<Float>.size)
                dst.update(from: scratch.mono, count: n)
            }
            return noErr
        }
    }
}

/// Pre-allocated, real-time-safe working memory for the render block.
final class RenderScratch: @unchecked Sendable {
    let capacity: Int
    let mono: UnsafeMutablePointer<Float>
    let channel: [UnsafeMutablePointer<Float>]

    init(capacity: Int) {
        self.capacity = capacity
        mono = .allocate(capacity: capacity)
        mono.initialize(repeating: 0, count: capacity)
        channel = (0..<2).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
            p.initialize(repeating: 0, count: capacity)
            return p
        }
    }

    deinit {
        mono.deallocate()
        channel.forEach { $0.deallocate() }
    }
}
