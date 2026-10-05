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
    public var operatorEnabled = [Bool](repeating: true, count: 6) { didSet { core.setOperatorMask(opMask); sendEditToDX7(offset: 155, value: opMask) } }
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

    /// How each MIDI controller drives the sound (like Dexed's controller settings). Vibrato/tremolo depth is still limited
    /// by the voice's own Pitch Mod Sens / Amp Mod Sens.
    public var controllerRouting: [ModSource: ControllerRouting] = SynthEngine.loadRouting() {
        didSet { SynthEngine.saveRouting(controllerRouting); applyControllerSettings() }
    }

    /// Pitch-bend range in semitones (up and down), or a fixed step size when `pitchBendStep` is not 0.
    public var pitchBendUp: Int = UserDefaults.standard.object(forKey: "pitchBendUp") as? Int ?? 3 {
        didSet { UserDefaults.standard.set(pitchBendUp, forKey: "pitchBendUp"); applyControllerSettings() }
    }
    public var pitchBendDown: Int = UserDefaults.standard.object(forKey: "pitchBendDown") as? Int ?? 3 {
        didSet { UserDefaults.standard.set(pitchBendDown, forKey: "pitchBendDown"); applyControllerSettings() }
    }
    public var pitchBendStep: Int = UserDefaults.standard.object(forKey: "pitchBendStep") as? Int ?? 0 {
        didSet { UserDefaults.standard.set(pitchBendStep, forKey: "pitchBendStep"); applyControllerSettings() }
    }

    /// Portamento time 0…99 (0 = off) and glissando (glide in semitone steps).
    public var portamentoTime: Int = UserDefaults.standard.object(forKey: "portamentoTime") as? Int ?? 0 {
        didSet { UserDefaults.standard.set(portamentoTime, forKey: "portamentoTime"); applyControllerSettings() }
    }
    public var glissando: Bool = UserDefaults.standard.object(forKey: "glissando") as? Bool ?? false {
        didSet { UserDefaults.standard.set(glissando, forKey: "glissando"); applyControllerSettings() }
    }

    /// Scale incoming velocities by 100/127, like a DX7 keyboard that tops out at 100.
    public var normalizeVelocity: Bool = UserDefaults.standard.object(forKey: "normalizeVelocity") as? Bool ?? false {
        didSet { UserDefaults.standard.set(normalizeVelocity, forKey: "normalizeVelocity"); applyControllerSettings() }
    }

    /// MPE: pitch bend on MIDI channels 2…16 bends only the note on that channel. Turns itself off if a second
    /// note arrives on one channel (a sign the controller isn't MPE), as Dexed does.
    public var mpeEnabled: Bool = UserDefaults.standard.object(forKey: "mpeEnabled") as? Bool ?? false {
        didSet { UserDefaults.standard.set(mpeEnabled, forKey: "mpeEnabled"); applyControllerSettings() }
    }
    /// Per-note bend range in semitones (MPE default is 24).
    public var mpeBendRange: Int = UserDefaults.standard.object(forKey: "mpeBendRange") as? Int ?? 24 {
        didSet { UserDefaults.standard.set(mpeBendRange, forKey: "mpeBendRange"); applyControllerSettings() }
    }

    /// 0 = Omni (every channel), 1…16 = listen on that channel only. MPE ignores it, since MPE uses a channel per note.
    public var midiChannel: Int = UserDefaults.standard.object(forKey: "midiChannel") as? Int ?? 0 {
        didSet { UserDefaults.standard.set(midiChannel, forKey: "midiChannel"); applyControllerSettings() }
    }
    /// On a custom tuning, make transposes of a whole octave move by whole scale periods (Dexed's default).
    public var transposeAsScale: Bool = UserDefaults.standard.object(forKey: "transposeAsScale") as? Bool ?? true {
        didSet { UserDefaults.standard.set(transposeAsScale, forKey: "transposeAsScale"); applyControllerSettings() }
    }

    /// Follow an MTS-ESP master's tuning when one is running (macOS only; Dexed has this on by default).
    public var mtsEnabled: Bool = UserDefaults.standard.object(forKey: "mtsEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(mtsEnabled, forKey: "mtsEnabled"); applyControllerSettings() }
    }
    /// False on iOS and iPadOS, where MTS-ESP masters don't exist.
    public var mtsSupported: Bool { core.isMTSSupported }
    /// True while an MTS-ESP master is running; polled with the meters.
    public private(set) var mtsConnected = false
    public private(set) var mtsScaleName = ""

    public func routing(_ source: ModSource) -> ControllerRouting {
        controllerRouting[source] ?? ControllerRouting.defaults[source] ?? ControllerRouting(range: 0)
    }

    private func applyControllerSettings() {
        for source in ModSource.allCases {
            let r = routing(source)
            core.setMod(source, range: r.range, pitch: r.pitch, amp: r.amp, eg: r.eg)
        }
        core.setPitchRange(up: pitchBendUp, down: pitchBendDown, step: pitchBendStep)
        core.setPortamento(time: Int((Float(portamentoTime) * 127 / 100).rounded()), glissando: glissando)   // Dexed's 0–99 → 0–127
        core.setNormalizeVelocity(normalizeVelocity)
        core.setMPE(enabled: mpeEnabled, range: mpeBendRange)
        core.setMIDIChannel(midiChannel)
        core.setMTS(mtsEnabled)
        core.setTransposeAsScale(transposeAsScale)
    }

    private static func loadRouting() -> [ModSource: ControllerRouting] {
        guard let data = UserDefaults.standard.data(forKey: "controllerRouting"),
              let saved = try? JSONDecoder().decode([ModSource: ControllerRouting].self, from: data) else { return ControllerRouting.defaults }
        return ControllerRouting.defaults.merging(saved) { _, new in new }
    }

    private static func saveRouting(_ routing: [ModSource: ControllerRouting]) {
        if let data = try? JSONEncoder().encode(routing) { UserDefaults.standard.set(data, forKey: "controllerRouting") }
    }

    /// Wheel positions for the on-screen controllers (pitch bend centre = 8192).
    public private(set) var pitchBendValue = 8192
    public private(set) var modWheelValue = 0

    // MARK: Hardware DX7 SysEx

    /// The MIDI output that voice/bank dumps and edits go to (a DX7's interface, for example). Saved between launches.
    public var sysexDestinationID: Int32? = {
        let v = UserDefaults.standard.object(forKey: "sysexDestination") as? Int
        return v.map { Int32(truncatingIfNeeded: $0) }
    }() {
        didSet { UserDefaults.standard.set(sysexDestinationID.map { Int($0) }, forKey: "sysexDestination") }
    }
    /// The DX7's MIDI channel (0…15; shown to the user as 1…16).
    public var sysexChannel: Int = UserDefaults.standard.object(forKey: "sysexChannel") as? Int ?? 0 {
        didSet { UserDefaults.standard.set(sysexChannel, forKey: "sysexChannel") }
    }
    /// Mirror every edit to the DX7 as a parameter-change message.
    public var sendsEditsToDX7: Bool = UserDefaults.standard.object(forKey: "sendsEditsToDX7") as? Bool ?? false {
        didSet { UserDefaults.standard.set(sendsEditsToDX7, forKey: "sendsEditsToDX7") }
    }
    private let sysexSender = MIDISysExSender()
    private var applyingIncomingSysEx = false

    public func sysexDestinations() -> [MIDIPortInfo] { MIDISysExSender.destinations() }
    public var hasSysExDestination: Bool { sysexDestinationID != nil }

    @discardableResult
    private func sendSysEx(_ data: Data) -> Bool {
        guard hosted == nil, let id = sysexDestinationID else { return false }
        return sysexSender.send(data, to: id)
    }

    public func sendVoiceToDX7() { sendVoiceToDX7(patch) }

    /// Sends any voice, for example one picked from the bank browser, as a single-voice dump.
    public func sendVoiceToDX7(_ voice: Patch) {
        sendSysEx(Cartridge.singleVoiceSysex(voice, channel: sysexChannel))
    }

    public func sendBankToDX7() {
        storeCurrentPatch()
        sendBankToDX7(bank)
    }

    /// Sends any bank, for example one previewed in the browser, as a 32-voice dump.
    public func sendBankToDX7(_ cartridge: Cartridge) {
        var data = [UInt8](cartridge.sysexData())
        data[2] |= UInt8(sysexChannel & 0x0F)
        sendSysEx(Data(data))
    }

    public func requestVoiceFromDX7() { sendSysEx(SysExMessage.request(channel: sysexChannel, .voice)) }
    public func requestBankFromDX7() { sendSysEx(SysExMessage.request(channel: sysexChannel, .bank)) }

    private func sendEditToDX7(offset: Int, value: Int) {
        guard sendsEditsToDX7, !applyingIncomingSysEx else { return }
        sendSysEx(SysExMessage.parameterChange(channel: sysexChannel, offset: offset, value: value))
    }

    /// Handles a complete SysEx message from a MIDI input: voice and bank dumps load, parameter changes edit the voice,
    /// and requests are answered with the current voice or bank (as Dexed does).
    public func handleSysEx(_ data: Data) {
        guard let message = SysExMessage.parse(data) else { return }
        applyingIncomingSysEx = true
        defer { applyingIncomingSysEx = false }
        switch message {
        case .voice(let received, _):
            core.panic()
            activeNotes.removeAll()
            operatorEnabled = [Bool](repeating: true, count: 6)         // a dump resets the operator switches, as on a DX7
            load(patch: received)
        case .bank(let received):
            load(bank: received, name: "DX7 Dump")
        case .parameterChange(let offset, let value):
            if offset == 155 {
                // Bit 0 = OP6 … bit 5 = OP1; our array is OP1 first.
                operatorEnabled = (0..<6).map { (value >> (5 - $0)) & 1 == 1 }
            } else if let limit = Parameters.maxValue(offset: offset) {
                setParameter(offset, min(value, limit))
            }
        case .request(let kind):
            applyingIncomingSysEx = false
            kind == .voice ? sendVoiceToDX7() : sendBankToDX7()
        }
    }

    // MARK: MIDI CC mapping ("MIDI learn")

    /// Which MIDI controller drives which control. Saved between launches.
    public private(set) var midiMapping: MIDIMapping = SynthEngine.loadMapping()
    /// While set, the next mappable controller received is assigned to this control.
    public private(set) var learningControl: MappableControl?

    /// While on, tapping a mappable knob selects it for learning instead of changing its value (handy on touch screens).
    public var midiLearnMode = false { didSet { if !midiLearnMode { learningControl = nil } } }

    public func beginLearning(_ control: MappableControl) { learningControl = control }
    public func cancelLearning() { learningControl = nil }
    public func toggleLearning(_ control: MappableControl) { learningControl = learningControl == control ? nil : control }

    public func mappedController(for control: MappableControl) -> MIDIControllerKey? { midiMapping.key(for: control) }

    public func removeMapping(for control: MappableControl) {
        midiMapping.remove(control)
        SynthEngine.saveMapping(midiMapping)
    }

    public func removeAllMappings() {
        midiMapping.removeAll()
        learningControl = nil
        SynthEngine.saveMapping(midiMapping)
    }

    /// Handles one incoming controller change. Returns true if it was consumed (learned or applied).
    @discardableResult
    public func handleController(channel: Int, cc: Int, value: Int) -> Bool {
        guard !ReservedCC.isReserved(cc) else { return false }
        let key = MIDIControllerKey(channel: channel, cc: cc)
        if let learning = learningControl {
            midiMapping.assign(learning, to: key)
            SynthEngine.saveMapping(midiMapping)
            learningControl = nil
            apply(learning, from: value)           // jump to the controller's current position, like Dexed
            return true
        }
        guard let control = midiMapping.control(for: key) else { return false }
        apply(control, from: value)
        return true
    }

    private func apply(_ control: MappableControl, from cc: Int) {
        let v = control.scaled(cc)
        switch control {
        case .voice(let offset): setParameter(offset, Int(v))
        case .cutoff: filterCutoff = v
        case .resonance: filterResonance = v
        case .masterTune: masterTune = v
        case .volume: masterVolume = Float(v)
        }
    }

    private static func loadMapping() -> MIDIMapping {
        guard let data = UserDefaults.standard.data(forKey: "midiMapping"),
              let saved = try? JSONDecoder().decode(MIDIMapping.self, from: data) else { return MIDIMapping() }
        return saved
    }

    private static func saveMapping(_ mapping: MIDIMapping) {
        if let data = try? JSONEncoder().encode(mapping) { UserDefaults.standard.set(data, forKey: "midiMapping") }
    }

    /// Name of the active microtuning, or nil for standard 12-TET.
    public private(set) var tuningName: String?
    private var currentSCL: String?
    private var currentKBM: String?


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

    /// Remembers the loaded bank, the selected program and the voice being edited between launches (standalone app only;
    /// a plug-in's state belongs to the host's project).
    private var persistsState = false
    private var restoringState = false
    private var saveTask: Task<Void, Never>?
    private enum StateKey {
        static let bank = "state.bank", bankName = "state.bankName", program = "state.program", patch = "state.patch"
    }

    /// - Parameter restoresState: bring back the bank, program and voice from the last run, and keep saving them.
    public init(restoresState: Bool = false) {
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
        applyControllerSettings()
        restoreTuning()
        if restoresState {
            restoreWorkingState()
            persistsState = true
        }

        let core = self.core
        midi.onMessage = { [weak self] status, d1, d2 in
            core.handleMIDI(status: status, data1: d1, data2: d2)
            guard core.acceptsChannel(Int(status & 0x0F) + 1) else { return }     // program change and CC mapping obey the filter too
            if status & 0xF0 == 0xC0 {
                Task { @MainActor in self?.selectProgram(Int(d1), sendMIDI: false) }
            } else if status & 0xF0 == 0xB0 {
                let channel = Int(status & 0x0F) + 1
                Task { @MainActor in self?.handleController(channel: channel, cc: Int(d1), value: Int(d2)) }
            }
        }
        midi.onSysEx = { [weak self] data in
            Task { @MainActor in self?.handleSysEx(data) }
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
        applyControllerSettings()
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
        guard hosted != nil else { scheduleStateSave(); return }
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
                let connected = self.core.isMTSConnected
                if connected != self.mtsConnected { self.mtsConnected = connected }
                let scale = connected ? self.core.mtsScaleName : ""
                if scale != self.mtsScaleName { self.mtsScaleName = scale }
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

    // MARK: Remembering the working state

    /// Saves shortly after the last change, so dragging a knob doesn't write on every step.
    private func scheduleStateSave() {
        guard persistsState, !restoringState else { return }
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveWorkingState()
        }
    }

    /// Writes the working state now. Called after a short delay on changes, and available for a flush on quit.
    public func saveWorkingState() {
        guard persistsState, hosted == nil else { return }
        let d = UserDefaults.standard
        d.set(bank.sysexData(), forKey: StateKey.bank)
        d.set(bankName, forKey: StateKey.bankName)
        d.set(programIndex, forKey: StateKey.program)
        d.set(Data(patch.bytes), forKey: StateKey.patch)
    }

    private func restoreWorkingState() {
        let d = UserDefaults.standard
        guard let data = d.data(forKey: StateKey.bank), let saved = try? Cartridge(sysex: data) else { return }
        restoringState = true
        defer { restoringState = false }
        bank = saved
        bankName = d.string(forKey: StateKey.bankName) ?? "Restored Bank"
        programIndex = max(0, min(Cartridge.voiceCount - 1, d.integer(forKey: StateKey.program)))
        // The voice as it was last edited, which may differ from the stored slot.
        if let bytes = d.data(forKey: StateKey.patch), bytes.count == Patch.initVoice.bytes.count {
            load(patch: Patch(bytes: [UInt8](bytes)))
        } else {
            load(patch: saved.patch(at: programIndex))
        }
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
        sendEditToDX7(offset: offset, value: patch[offset])
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

    // MARK: Operator copy / paste

    /// The operator's values as Dexed-compatible clipboard text.
    public func operatorClipboardText(_ op: Int) -> String {
        OperatorClipboard.encode(patch.operatorBytes(op), description: "iDexed OP\(op + 1) of \(patch.name)")
    }

    /// Pastes clipboard text onto an operator (all values, or just the envelope). Returns false if it isn't operator data.
    @discardableResult
    public func pasteOperator(_ op: Int, from text: String, envelopeOnly: Bool = false) -> Bool {
        guard let bytes = OperatorClipboard.decode(text) else { return false }
        var p = patch
        p.setOperatorBytes(op, bytes, envelopeOnly: envelopeOnly)
        load(patch: p)
        return true
    }

    /// Replaces one slot of the current bank with a voice (for example one dragged in from the bank browser). If the slot is
    /// the one being played, the voice is loaded too.
    public func replaceVoice(at slot: Int, with voice: Patch) {
        guard (0..<Cartridge.voiceCount).contains(slot) else { return }
        bank.setPatch(voice, at: slot)
        if slot == programIndex { load(patch: voice) } else { syncToHost() }
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
