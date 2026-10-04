import AVFoundation
import Observation

/// App-facing model: owns the audio graph, the current voice and the loaded bank.
@MainActor
@Observable
public final class SynthEngine {
    public private(set) var patch: Patch = .initVoice
    public private(set) var bank = Cartridge()
    public private(set) var bankName = "Init Bank"
    public private(set) var programIndex = 0
    public private(set) var isRunning = false
    public private(set) var activeNotes: Set<Int> = []
    /// Live metering (operator levels, envelope stages, output level, held notes), refreshed ~30×/s while running.
    public private(set) var status = SynthStatus()
    private var meterTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var isStarting = false
    private var isRecovering = false

    public var engineType: EngineType = .markI { didSet { core.setEngine(engineType); syncToHost() } }
    public var monoMode = false { didSet { core.setMono(monoMode) } }
    public var operatorEnabled = [Bool](repeating: true, count: 6) { didSet { core.setOperatorMask(opMask) } }
    public var masterVolume: Float = 1.0 { didSet { audio?.mainMixerNode.outputVolume = masterVolume; syncToHost() } }
    /// Publish played notes as a virtual MIDI source ("iDexed") for other devices/apps.
    public var sendsMIDI: Bool = UserDefaults.standard.object(forKey: "sendsMIDI") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sendsMIDI, forKey: "sendsMIDI"); if !sendsMIDI { midiOut.allNotesOff() } }
    }
    /// Turn off to play only through MIDI out (e.g. when the sound comes from a Mac).
    public var playsLocalSound: Bool = UserDefaults.standard.object(forKey: "playsLocalSound") as? Bool ?? true {
        didSet { UserDefaults.standard.set(playsLocalSound, forKey: "playsLocalSound"); if !playsLocalSound { core.panic() } }
    }
    /// Global tune (0…1, 0.5 = in tune; ±1 semitone) and the output low-pass filter (cutoff 1 = open).
    public var masterTune: Double = UserDefaults.standard.object(forKey: "masterTune") as? Double ?? 0.5 {
        didSet { UserDefaults.standard.set(masterTune, forKey: "masterTune"); core.setMasterTune(masterTune); syncToHost() }
    }
    public var filterCutoff: Double = UserDefaults.standard.object(forKey: "filterCutoff") as? Double ?? 1 {
        didSet { UserDefaults.standard.set(filterCutoff, forKey: "filterCutoff"); core.setFilter(cutoff: filterCutoff, resonance: filterResonance); syncToHost() }
    }
    public var filterResonance: Double = UserDefaults.standard.object(forKey: "filterResonance") as? Double ?? 0 {
        didSet { UserDefaults.standard.set(filterResonance, forKey: "filterResonance"); core.setFilter(cutoff: filterCutoff, resonance: filterResonance); syncToHost() }
    }

    /// What the mod wheel (MIDI CC 1) controls and how strongly. Like Dexed's controller settings: range 0…127 scales the
    /// wheel, and it can drive vibrato (pitch), tremolo (amp) and/or envelope level (EG). Vibrato/tremolo depth is still
    /// limited by the voice's own Pitch Mod Sens / Amp Mod Sens.
    public var modWheelRange: Int = UserDefaults.standard.object(forKey: "modWheelRange") as? Int ?? 100 {
        didSet { UserDefaults.standard.set(modWheelRange, forKey: "modWheelRange"); applyModWheel() }
    }
    public var modWheelPitch: Bool = UserDefaults.standard.object(forKey: "modWheelPitch") as? Bool ?? true {
        didSet { UserDefaults.standard.set(modWheelPitch, forKey: "modWheelPitch"); applyModWheel() }
    }
    public var modWheelAmp: Bool = UserDefaults.standard.object(forKey: "modWheelAmp") as? Bool ?? false {
        didSet { UserDefaults.standard.set(modWheelAmp, forKey: "modWheelAmp"); applyModWheel() }
    }
    public var modWheelEG: Bool = UserDefaults.standard.object(forKey: "modWheelEG") as? Bool ?? false {
        didSet { UserDefaults.standard.set(modWheelEG, forKey: "modWheelEG"); applyModWheel() }
    }
    private func applyModWheel() {
        core.setMod(.wheel, range: modWheelRange, pitch: modWheelPitch, amp: modWheelAmp, eg: modWheelEG)
    }

    /// Wheel positions for the on-screen controllers (pitch bend centre = 8192).
    public private(set) var pitchBendValue = 8192
    public private(set) var modWheelValue = 0

    /// Name of the active microtuning, or nil for standard 12-TET.
    public private(set) var tuningName: String?
    private var currentSCL: String?
    private var currentKBM: String?

    public var pitchBendRange = 3 { didSet { core.setPitchRange(up: pitchBendRange, down: pitchBendRange, step: 0) } }

    public let core: SynthCore
    private let audio: AVAudioEngine?
    /// Non-nil when running inside the AUv3 plug-in: the host owns the audio, the clock and the saved state.
    private let hosted: HostedSession?
    private var applyingFromHost = false
    public var isHostedPlugin: Bool { hosted != nil }
    private var source: AVAudioSourceNode?
    public let midi: MIDIInput
    public let midiOut = MIDIOutput()

    /// The engine numbers operators in storage order (bit 0 = OP6 … bit 5 = OP1), so flip the UI order.
    private var opMask: Int { operatorEnabled.enumerated().reduce(0) { $0 | ($1.element ? 1 << (5 - $1.offset) : 0) } }

    public init() {
        let audioEngine = AVAudioEngine()
        let hardwareRate = audioEngine.outputNode.outputFormat(forBus: 0).sampleRate
        audio = audioEngine
        hosted = nil
        core = SynthCore(sampleRate: hardwareRate >= 8000 ? hardwareRate : 48000)
        midi = MIDIInput()
        core.setEngine(engineType)
        core.setPatch(patch)
        core.setOperatorMask(0x3F)
        core.setMasterTune(masterTune)
        core.setFilter(cutoff: filterCutoff, resonance: filterResonance)
        applyModWheel()
        restoreTuning()

        let core = self.core
        midi.onMessage = { [weak self] status, d1, d2 in
            core.handleMIDI(status: status, data1: d1, data2: d2)
            if status & 0xF0 == 0xC0 {
                Task { @MainActor in self?.selectProgram(Int(d1), sendMIDI: false) }
            }
        }
    }

    /// Plug-in mode: drives the Audio Unit's engine instead of opening its own audio output.
    public init(hosted session: HostedSession) {
        audio = nil
        hosted = session
        core = session.core
        midi = MIDIInput()
        sendsMIDI = false
        playsLocalSound = true
        applyModWheel()
        applyFromHost()
        session.onExternalChange = { [weak self] in
            MainActor.assumeIsolated { self?.applyFromHost() }
        }
    }

    /// Pulls everything the host may have changed (presets, automation, restored project state).
    private func applyFromHost() {
        guard let hosted else { return }
        applyingFromHost = true
        defer { applyingFromHost = false }
        let s = hosted.settings
        patch = s.patch
        bank = s.bank
        bankName = s.bankName
        programIndex = s.program
        masterVolume = s.volume
        masterTune = s.tune
        filterCutoff = s.cutoff
        filterResonance = s.resonance
        engineType = s.engine
        tuningName = s.tuningName
        currentSCL = s.scl
        currentKBM = s.kbm
    }

           private func syncToHost() {
        guard let hosted, !applyingFromHost else { return }
        hosted.update { s in
            s.patch = patch; s.bank = bank; s.bankName = bankName; s.program = programIndex
            s.volume = masterVolume; s.tune = masterTune; s.cutoff = filterCutoff; s.resonance = filterResonance
            s.engine = engineType
            s.scl = currentSCL; s.kbm = currentKBM; s.tuningName = tuningName
        }
    }

    // MARK: Audio lifecycle

    public func start() {
        guard !isRunning, !isStarting else { return }
        if hosted != nil {
            isRunning = true
            startMetering()
            return
        }
        isStarting = true
        // AVAudioSession calls can block; do them off the main thread, then finish on it.
        Task { @MainActor [weak self] in
            #if os(iOS)
            await Self.configureAudioSession()
            #endif
            self?.finishStart()
        }
    }

    private func finishStart() {
        isStarting = false
        guard let audio, !isRunning else { return }
        if source == nil {
            let format = AVAudioFormat(standardFormatWithSampleRate: core.sampleRate, channels: 2)!
            let node = Self.makeSourceNode(core: core, format: format)
            audio.attach(node)
            audio.connect(node, to: audio.mainMixerNode, format: format)
            source = node
        }
        audio.mainMixerNode.outputVolume = masterVolume
        do {
            try audio.start()
            isRunning = true
        } catch {
            print("Audio engine failed to start: \(error)")
        }
        installRecoveryObservers()
        midiOut.start()
        midi.ignoredSources = [midiOut.endpoint]
        midi.start()
        startMetering()
    }

    #if os(iOS)
    /// AVAudioSession calls can block while the system sets up audio, so they must never run on the main thread.
    /// A plain background dispatch queue is used (rather than a `nonisolated async` function, which newer Swift
    /// versions run on the caller's actor) so this is guaranteed to be off the main thread.
    private nonisolated static func configureAudioSession() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                dispatchPrecondition(condition: .notOnQueue(.main))
                let session = AVAudioSession.sharedInstance()
                try? session.setCategory(.playback, options: [.mixWithOthers])
                try? session.setPreferredIOBufferDuration(0.005)
                try? session.setActive(true)
                continuation.resume()
            }
        }
    }
    #endif

    private func startMetering() {
        meterTask?.cancel()
        meterTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self else { return }
                let s = self.core.status()
                if s != self.status { self.status = s }
            }
        }
    }

    // MARK: Route changes and interruptions

    /// iOS/macOS stop the engine whenever the output device changes (Bluetooth speaker switched off,
    /// headphones unplugged, sample rate change) and after interruptions (calls, Siri). Restart it so sound resumes.
    private func installRecoveryObservers() {
        guard observers.isEmpty, let audio else { return }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: audio, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recoverAudio() }
        })
        #if os(iOS)
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recoverAudio() }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            MainActor.assumeIsolated {
                if type == .began { self?.core.panic(); self?.activeNotes.removeAll() } else { self?.recoverAudio() }
            }
        })
        #endif
    }

    /// Brings the engine back after the system stopped it. Safe to call at any time.
    public func recoverAudio() {
        guard let audio, isRunning, !audio.isRunning, !isRecovering else { return }
        isRecovering = true
        Task { @MainActor [weak self] in
            #if os(iOS)
            await Self.configureAudioSession()      // re-activate off the main thread
            #endif
            guard let self else { return }
            self.isRecovering = false
            guard self.isRunning, !audio.isRunning else { return }
            audio.prepare()
            do { try audio.start() } catch { print("Audio engine failed to restart: \(error)") }
        }
    }

    /// Built outside the main actor on purpose: the render block runs on the real-time audio thread.
    private nonisolated static func makeSourceNode(core: SynthCore, format: AVAudioFormat) -> AVAudioSourceNode {
        let capacity = 4096
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        scratch.initialize(repeating: 0, count: capacity)
        let box = ScratchBox(pointer: scratch)
        return AVAudioSourceNode(format: format) { _, _, frames, abl in
            let n = min(Int(frames), capacity)
            core.render(into: box.pointer, frames: n)
            for b in UnsafeMutableAudioBufferListPointer(abl) {
                if let dst = b.mData?.assumingMemoryBound(to: Float.self) {
                    dst.update(from: box.pointer, count: n)
                }
            }
            return noErr
        }
    }

    public func stop() {
        meterTask?.cancel()
        core.panic()
        audio?.stop()
        isRunning = false
    }

    // MARK: Playing

    public func noteOn(_ note: Int, velocity: Int = 100) {
        activeNotes.insert(note)
        if playsLocalSound { core.noteOn(note, velocity: velocity) }
        if sendsMIDI { midiOut.noteOn(note, velocity: velocity) }
    }

    public func noteOff(_ note: Int) {
        activeNotes.remove(note)
        core.noteOff(note)
        if sendsMIDI { midiOut.noteOff(note) }
    }

    public func panic() {
        activeNotes.removeAll()
        core.panic()
        if sendsMIDI { midiOut.allNotesOff() }
    }

    // MARK: Editing

    public func setParameter(_ offset: Int, _ value: Int) {
        guard patch[offset] != value else { return }
        patch[offset] = value
        core.setParam(offset, patch[offset])
        syncToHost()
    }

    public func setPatchName(_ name: String) {
        patch.name = name
        core.setPatch(patch)
        syncToHost()
    }

    public func load(patch p: Patch) {
        patch = p
        core.setPatch(p)
        syncToHost()
    }

    // MARK: Banks

    public func load(bank b: Cartridge, name: String) {
        bank = b
        bankName = name
        selectProgram(0, sendMIDI: false)
        syncToHost()
    }

    public func selectProgram(_ index: Int, sendMIDI: Bool = true) {
        let i = max(0, min(Cartridge.voiceCount - 1, index))
        programIndex = i
        load(patch: bank.patch(at: i))
        if sendMIDI && sendsMIDI { midiOut.programChange(i) }
        syncToHost()
    }

    // MARK: Wheels

    public func setPitchBend(_ value: Int) {
        pitchBendValue = max(0, min(16383, value))
        if playsLocalSound { core.pitchBend(pitchBendValue) }
        if sendsMIDI { midiOut.pitchBend(pitchBendValue) }
    }

    public func setModWheel(_ value: Int) {
        modWheelValue = max(0, min(127, value))
        if playsLocalSound { core.controlChange(1, modWheelValue) }
        if sendsMIDI { midiOut.controlChange(1, modWheelValue) }
    }

    // MARK: Tuning

    /// Applies Scala (.scl) and optional keyboard-mapping (.kbm) text. Returns an error message on failure.
    @discardableResult
    public func loadTuning(scl: String, kbm: String?, name: String) -> String? {
        if let error = core.setTuning(scl: scl, kbm: kbm) { return error }
        currentSCL = scl; currentKBM = kbm
        tuningName = name
        syncToHost()
        let d = UserDefaults.standard
        d.set(scl, forKey: "tuningSCL"); d.set(kbm, forKey: "tuningKBM"); d.set(name, forKey: "tuningName")
        return nil
    }

    /// Adds a keyboard mapping (.kbm) to the scale that is already loaded.
    @discardableResult
    public func loadMapping(_ kbm: String, name: String) -> String? {
        guard let scl = currentSCL else { return "Load a Scala scale (.scl) first, then add a keyboard mapping." }
        return loadTuning(scl: scl, kbm: kbm, name: "\(tuningName?.components(separatedBy: " + ").first ?? "Scale") + \(name)")
    }

    public func resetTuning() {
        core.setTuning(scl: nil)
        tuningName = nil
        currentSCL = nil; currentKBM = nil
        syncToHost()
        let d = UserDefaults.standard
        ["tuningSCL", "tuningKBM", "tuningName"].forEach(d.removeObject(forKey:))
    }

    private func restoreTuning() {
        let d = UserDefaults.standard
        guard let scl = d.string(forKey: "tuningSCL"), core.setTuning(scl: scl, kbm: d.string(forKey: "tuningKBM")) == nil else { return }
        tuningName = d.string(forKey: "tuningName") ?? "Custom"
        currentSCL = scl; currentKBM = d.string(forKey: "tuningKBM")
    }

    /// Stores the edited voice into the current bank slot.
    public func storeCurrentPatch() {
        bank.setPatch(patch, at: programIndex)
        syncToHost()
    }

    public func importSysEx(_ data: Data, name: String) throws {
        load(bank: try Cartridge(sysex: data), name: name)
    }

    public func exportBank() -> Data {
        storeCurrentPatch()
        return bank.sysexData()
    }

    public func exportVoice() -> Data { Cartridge.singleVoiceSysex(patch) }
}

private final class ScratchBox: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<Float>
    init(pointer: UnsafeMutablePointer<Float>) { self.pointer = pointer }
    deinit { pointer.deallocate() }
}
