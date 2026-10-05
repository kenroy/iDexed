import Foundation
import Testing
@testable import DexedKit
import AVFoundation
import AudioToolbox

/// The engine keeps sample-rate-dependent lookup tables in shared global state (inherited from Dexed's msfa),
/// so tests that use different sample rates must not overlap. Everything lives under one serialized parent.
@Suite(.serialized) struct AllEngineTests {
    @Suite struct EngineTests {
        @Test func initVoiceMakesSound() {
            let core = SynthCore(sampleRate: 48000)
            core.setPatch(.initVoice)
            core.noteOn(69, velocity: 100)
            _ = core.render(frames: 64)
            let out = core.render(frames: 4800)
            let peak = out.map(abs).max() ?? 0
            #expect(peak > 0.05)
            // 440 Hz sine → ~880 zero crossings per second → ~88 in 0.1 s.
            var crossings = 0
            for i in 1..<out.count where (out[i - 1] < 0) != (out[i] < 0) { crossings += 1 }
            #expect((80...96).contains(crossings), "crossings=\(crossings)")
        }

        @Test func silenceWithoutNotes() {
            let core = SynthCore(sampleRate: 48000)
            #expect((core.render(frames: 512).map(abs).max() ?? 0) == 0)
        }

        @Test func noteOffEventuallyDecays() {
            let core = SynthCore(sampleRate: 48000)
            core.noteOn(60, velocity: 100)
            _ = core.render(frames: 4800)
            core.noteOff(60)
            _ = core.render(frames: 48000 * 4)
            #expect((core.render(frames: 512).map(abs).max() ?? 0) < 0.001)
        }

        @Test func sysexRoundTrip() throws {
            var cart = Cartridge()
            var p = Patch.initVoice
            p.name = "TEST PATCH"
            p.algorithm = 21
            p.feedback = 5
            p[op: 2, field: .freqCoarse] = 7
            p[op: 5, field: .detune] = 11
            p[op: 0, field: .leftCurve] = 3
            cart.setPatch(p, at: 3)
            let data = cart.sysexData()
            #expect(data.count == 4104)
            let back = try Cartridge(sysex: data)
            #expect(back.patch(at: 3) == p)
            #expect(back.names[3] == "TEST PATCH")
        }

        @Test func singleVoiceImport() throws {
            var p = Patch.initVoice
            p.name = "SOLO"
            p.algorithm = 4
            let cart = try Cartridge(sysex: Cartridge.singleVoiceSysex(p))
            #expect(cart.patch(at: 0).algorithm == 4)
            #expect(cart.patch(at: 0).name == "SOLO")
        }
    }

    @Suite struct AlgorithmTests {
        @Test func algorithmOne() {
            let g = AlgorithmGraph(index: 0)
            #expect(g.carriers == [1, 3])
            #expect(g.edges.contains(.init(from: 2, to: 1, isFeedback: false)))
            #expect(g.edges.contains(.init(from: 6, to: 5, isFeedback: false)))
            #expect(g.edges.contains(.init(from: 6, to: 6, isFeedback: true)))
        }

        @Test func algorithmThirtyTwoIsAllCarriers() {
            let g = AlgorithmGraph(index: 31)
            #expect(g.carriers == [1, 2, 3, 4, 5, 6])
            #expect(g.rowCount == 1)
        }

        @Test func everyAlgorithmHasCarrierAndUniqueSlots() {
            for (i, g) in AlgorithmGraph.all.enumerated() {
                #expect(!g.carriers.isEmpty, "algo \(i + 1)")
                let slots = Set((1...6).map { "\(g.rows[$0]!),\(g.columns[$0]!)" })
                #expect(slots.count == 6, "algo \(i + 1) overlaps")
            }
        }
    }

    @Suite struct TapTests {
        @Test func instantTapStillSounds() {
            let core = SynthCore(sampleRate: 48000)
            core.noteOn(60, velocity: 100)
            core.noteOff(60)   // both arrive before any audio is rendered
            let out = core.render(frames: 2400)
            #expect((out.map(abs).max() ?? 0) > 0.05)
        }
    }

    @Suite struct MeterTests {
        @Test func statusTracksNotesAndLevels() {
            let core = SynthCore(sampleRate: 48000)
            #expect(core.status().outputLevel == 0)
            core.noteOn(60, velocity: 100)
            _ = core.render(frames: 4800)
            let s = core.status()
            #expect(s.heldNotes == [60])
            #expect(s.outputLevel > 0.05)
            #expect(s.operatorLevels[0] > 0.1)      // init voice: OP1 audible
            #expect(s.operatorLevels[1] < 0.01)     // OP2 silent
            core.noteOff(60)
            _ = core.render(frames: 4800)
            #expect(core.status().heldNotes.isEmpty)
        }
    }

    @Suite struct FrequencyDisplayTests {
        @Test func matchesDexedReadout() {
            var p = Patch.initVoice
            p[op: 0, field: .freqCoarse] = 2; p[op: 0, field: .freqFine] = 0; p[op: 0, field: .detune] = 8
            #expect(p.frequencyDescription(op: 0) == "f = 2 +1")
            p[op: 0, field: .freqCoarse] = 0
            #expect(p.frequencyDescription(op: 0) == "f = 0.5 +1")
            p[op: 0, field: .oscMode] = 1; p[op: 0, field: .freqCoarse] = 2; p[op: 0, field: .freqFine] = 50; p[op: 0, field: .detune] = 6
            #expect(p.frequencyDescription(op: 0) == "316.228 Hz -1")   // 100 × 10^0.5
        }
    }

    @Suite struct OperatorMuteTests {
        @Test func mutingOP1SilencesInitVoice() {
            // The init voice only has OP1 audible (storage index 5 → mask bit 5 when numbered from OP6).
            let core = SynthCore(sampleRate: 48000)
            core.setOperatorMask(0b011111)           // OP6 … bit0 … OP1 = bit5 cleared → OP1 off
            core.noteOn(60, velocity: 100)
            _ = core.render(frames: 256)
            let out = core.render(frames: 4800)
            #expect((out.map(abs).max() ?? 0) < 0.001)
            #expect(core.status().operatorLevels[0] < 0.01)
        }
    }

    @Suite struct MIDIOutTests {
        final class Box: @unchecked Sendable { var messages: [[UInt8]] = [] }

        @Test func virtualSourceDeliversNotes() async throws {
            let out = MIDIOutput()
            out.start()
            let box = Box()
            let input = MIDIInput()
            input.onMessage = { s, a, b in box.messages.append([s, a, b]) }
            input.start()
            try await Task.sleep(for: .milliseconds(300))
            out.noteOn(64, velocity: 90, channel: 2)
            out.noteOff(64, channel: 2)
            try await Task.sleep(for: .milliseconds(500))
            #expect(box.messages.contains([0x91, 64, 90]))
            #expect(box.messages.contains([0x81, 64, 0]))
            out.stop()
        }

        @Test func ignoredSourceIsNotHeard() async throws {
            let out = MIDIOutput()
            out.start()
            let box = Box()
            let input = MIDIInput()
            input.ignoredSources = [out.endpoint]
            input.onMessage = { s, a, b in box.messages.append([s, a, b]) }
            input.start()
            try await Task.sleep(for: .milliseconds(300))
            out.noteOn(60, velocity: 100)
            try await Task.sleep(for: .milliseconds(400))
            #expect(box.messages.isEmpty)
            out.stop()
        }
    }

    @Suite struct TuningFilterTests {
        /// Estimates frequency from zero crossings over one second.
        func frequency(_ core: SynthCore, note: Int) -> Double {
            core.noteOn(note, velocity: 100)
            _ = core.render(frames: 2400)
            let out = core.render(frames: 48000)
            var crossings = 0
            for i in 1..<out.count where (out[i - 1] < 0) != (out[i] < 0) { crossings += 1 }
            core.noteOff(note)
            core.panic()
            return Double(crossings) / 2
        }

        @Test func standardPitch() {
            let core = SynthCore(sampleRate: 48000)
            #expect(abs(frequency(core, note: 69) - 440) < 6)
        }

        @Test func scalaOneNotePerOctaveMapsKeysToOctaves() {
            let core = SynthCore(sampleRate: 48000)
            let scl = "! test\none step per octave\n 1\n 2/1\n"
            #expect(core.setTuning(scl: scl) == nil)
            _ = core.render(frames: 64)            // apply
            let c4 = frequency(core, note: 60), c5 = frequency(core, note: 61)
            #expect(abs(c4 - 261.6) < 5, "c4=\(c4)")
            #expect(abs(c5 / c4 - 2) < 0.03, "ratio=\(c5 / c4)")
        }

        @Test func keyboardMappingSetsReferenceFrequency() {
            let core = SynthCore(sampleRate: 48000)
            let scl = "! 12 edo\n12 edo\n 12\n" + (1...12).map { "\($0 * 100).0" }.joined(separator: "\n") + "\n"
            let kbm = "12\n0\n127\n69\n69\n432.0\n12\n" + (0..<12).map(String.init).joined(separator: "\n") + "\n"
            #expect(core.setTuning(scl: scl, kbm: kbm) == nil)
            _ = core.render(frames: 64)
            #expect(abs(frequency(core, note: 69) - 432) < 6)
        }

        @Test func badScalaFileReportsError() {
            let core = SynthCore(sampleRate: 48000)
            #expect(core.setTuning(scl: "nonsense") != nil)
            #expect(core.setTuning(scl: nil) == nil)    // back to standard
        }

        @Test func masterTuneShiftsBySemitone() {
            let core = SynthCore(sampleRate: 48000)
            core.setMasterTune(1.0)
            _ = core.render(frames: 64)
            #expect(abs(frequency(core, note: 69) - 466.2) < 7)
        }

        @Test func lowCutoffRemovesHighs() {
            let open = SynthCore(sampleRate: 48000)
            open.noteOn(96, velocity: 100)
            _ = open.render(frames: 4800)
            let openPeak = open.render(frames: 4800).map(abs).max() ?? 0

            let closed = SynthCore(sampleRate: 48000)
            closed.setFilter(cutoff: 0.15, resonance: 0)
            closed.noteOn(96, velocity: 100)
            _ = closed.render(frames: 4800)
            let closedPeak = closed.render(frames: 4800).map(abs).max() ?? 0
            #expect(openPeak > 0.05)
            #expect(closedPeak < openPeak * 0.5, "open=\(openPeak) closed=\(closedPeak)")
        }
    }


    @Suite struct AudioUnitTests {
        static func fourCC(_ s: String) -> FourCharCode { s.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) } }

        func makeUnit() throws -> DexedAudioUnit {
            let desc = AudioComponentDescription(componentType: kAudioUnitType_MusicDevice,
                                                 componentSubType: Self.fourCC("iDxd"), componentManufacturer: Self.fourCC("Kenr"),
                                                 componentFlags: 0, componentFlagsMask: 0)
            return try DexedAudioUnit(componentDescription: desc)
        }

        /// Renders one block through the unit's real render block, the way a host would.
        func render(_ au: DexedAudioUnit, frames: AVAudioFrameCount = 1024, at time: Double = 0) -> AVAudioPCMBuffer {
            let buffer = AVAudioPCMBuffer(pcmFormat: au.outputBusses[0].format, frameCapacity: frames)!
            buffer.frameLength = frames
            var flags = AudioUnitRenderActionFlags()
            var ts = AudioTimeStamp()
            ts.mSampleTime = time
            ts.mFlags = .sampleTimeValid
            let status = au.renderBlock(&flags, &ts, frames, 0, buffer.mutableAudioBufferList, nil)
            #expect(status == noErr)
            return buffer
        }

        func peak(_ b: AVAudioPCMBuffer, channel: Int = 0) -> Float {
            let p = b.floatChannelData![channel]
            return (0..<Int(b.frameLength)).map { abs(p[$0]) }.max() ?? 0
        }

        func send(_ au: DexedAudioUnit, _ bytes: [UInt8]) {
            bytes.withUnsafeBufferPointer { au.scheduleMIDIEventBlock?(AUEventSampleTimeImmediate, 0, bytes.count, $0.baseAddress!) }
        }

        @Test func rendersNotesFromHostMIDI() throws {
            let au = try makeUnit()
            try au.allocateRenderResources()
            #expect(peak(render(au)) == 0)
            send(au, [0x90, 69, 110])
            _ = render(au, at: 1024)
            let out = render(au, at: 2048)
            #expect(peak(out, channel: 0) > 0.05)
            #expect(peak(out, channel: 1) > 0.05)
            au.deallocateRenderResources()
        }

        @Test func followsHostSampleRate() throws {
            let au = try makeUnit()
            try au.outputBusses[0].setFormat(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!)
            try au.allocateRenderResources()
            #expect(au.session.core.sampleRate == 44100)
            send(au, [0x90, 69, 100])
            _ = render(au)
            // 440 Hz at 44.1 kHz: ~100 samples per cycle; count zero crossings over ~0.1 s.
            let out = render(au, frames: 4410, at: 1024)
            let p = out.floatChannelData![0]
            var crossings = 0
            for i in 1..<Int(out.frameLength) where (p[i - 1] < 0) != (p[i] < 0) { crossings += 1 }
            #expect((80...96).contains(crossings), "crossings=\(crossings)")
            au.deallocateRenderResources()
        }

        @Test func exposesTheBankAsPresets() throws {
            let au = try makeUnit()
            var s = HostedSettings()
            var bank = Cartridge()
            var p = Patch.initVoice
            p.name = "BELLS"
            bank.setPatch(p, at: 5)
            s.bank = bank
            au.session.apply(s)
            #expect(au.factoryPresets?.count == 32)
            #expect(au.factoryPresets?[5].name == "BELLS")
            let preset = AUAudioUnitPreset()
            preset.number = 5
            au.currentPreset = preset
            #expect(au.session.settings.patch.name == "BELLS")
        }

        @Test func savesAndRestoresStateForTheProject() throws {
            let au = try makeUnit()
            var s = HostedSettings()
            s.patch.name = "MY SOUND"
            s.patch.algorithm = 12
            s.cutoff = 0.4
            s.tuningName = "just"
            s.scl = "! j\nj\n 1\n 2/1\n"
            au.session.apply(s)
            let saved = try #require(au.fullState)

            let other = try makeUnit()
            other.fullState = saved
            let r = other.session.settings
            #expect(r.patch.name == "MY SOUND")
            #expect(r.patch.algorithm == 12)
            #expect(abs(r.cutoff - 0.4) < 1e-9)
            #expect(r.scl == s.scl)
        }

        @Test func hostParametersReachTheEngine() throws {
            let au = try makeUnit()
            let tree = try #require(au.parameterTree)
            let cutoff = try #require(tree.parameter(withAddress: AUParameterAddress(HostParameter.cutoff)))
            cutoff.value = 0.25
            #expect(abs(au.session.settings.cutoff - 0.25) < 1e-6)
            let volume = try #require(tree.parameter(withAddress: AUParameterAddress(HostParameter.volume)))
            volume.value = 0
            try au.allocateRenderResources()
            send(au, [0x90, 60, 100])
            _ = render(au)
            #expect(peak(render(au, at: 1024)) == 0)     // volume 0 → silent
            au.deallocateRenderResources()
        }
    }

    @Suite struct HostedEditorTests {
        @Test @MainActor func editsFlowToTheSessionAndHostChangesFlowBack() async throws {
            let session = HostedSession()
            let engine = SynthEngine(hosted: session)
            #expect(engine.isHostedPlugin)

            // Editor → session (what the DAW will save)
            engine.setParameter(134, 9)
            engine.setPatchName("EDITED")
            engine.filterCutoff = 0.3
            #expect(session.settings.patch.algorithm == 9)
            #expect(session.settings.patch.name == "EDITED")
            #expect(abs(session.settings.cutoff - 0.3) < 1e-9)

            // Host → editor (preset change, e.g. a program change from the DAW)
            var bank = Cartridge()
            var p = Patch.initVoice
            p.name = "FROM HOST"
            bank.setPatch(p, at: 7)
            var s = session.settings
            s.bank = bank
            session.apply(s)
            session.selectProgram(7)
            try await Task.sleep(for: .milliseconds(100))     // external changes arrive on the main queue
            #expect(engine.patch.name == "FROM HOST")
            #expect(engine.programIndex == 7)

            // The plug-in editor plays the plug-in's engine
            engine.noteOn(69)
            _ = session.core.render(frames: 256)
            #expect(session.core.status().heldNotes == [69])
            engine.noteOff(69)
        }
    }

    /// Fingerprint of the engine's exact output. Guards the fixed-point maths: refactors (e.g. making integer
    /// conversions explicit to silence compiler warnings) must not change a single sample.
    @Suite struct BitExactnessTests {
        static func fingerprint(_ engine: EngineType) -> UInt64 {
            var p = Patch.initVoice
            p.algorithm = 4
            p.feedback = 6
            p[137] = 40; p[139] = 30; p[140] = 20; p[143] = 4          // LFO speed, pitch/amp depth, pitch sens
            for op in 0..<6 {
                p[op: op, field: .outputLevel] = 85 - op * 4
                p[op: op, field: .freqCoarse] = 1 + op % 3
                p[op: op, field: .freqFine] = op * 7
                p[op: op, field: .detune] = 5 + op
                p[op: op, field: .ampModSens] = op % 4
                p[op: op, field: .keyVelSens] = op % 8
                p[op: op, field: .rate1] = 70 + op * 3
                p[op: op, field: .level2] = 80
            }
            p[op: 1, field: .oscMode] = 1                                  // one fixed-frequency operator

            let core = SynthCore(sampleRate: 48000)
            core.setEngine(engine)
            core.setPatch(p)
            core.controlChange(1, 90)
            var hash: UInt64 = 0xcbf29ce484222325
            for (note, velocity) in [(48, 90), (55, 70), (64, 110), (88, 60)] { core.noteOn(note, velocity: velocity) }
            for block in 0..<40 {
                if block == 20 { core.pitchBend(12000); core.noteOff(48) }
                for sample in core.render(frames: 512) {
                    hash = (hash ^ UInt64(sample.bitPattern)) &* 0x100000001b3
                }
            }
            return hash
        }

        @Test func engineOutputMatchesRecordedFingerprint() {
            let got = EngineType.allCases.map { Self.fingerprint($0) }
            print("FINGERPRINTS", got)
            #expect(got == Self.expected, "fingerprints changed: \(got)")
        }

        static let expected: [UInt64] = [40932685808056956, 3923941283329485767, 6514936974564345330]
    }

    @Suite struct ClipboardAndControlTests {
        @Test func operatorClipboardUsesDexedsHexFormat() throws {
            var p = Patch.initVoice
            p[op: 2, field: .freqCoarse] = 7
            p[op: 2, field: .outputLevel] = 88
            let text = OperatorClipboard.encode(p.operatorBytes(2), description: "from test")
            #expect(text.hasPrefix("63636363"))                    // 21 bytes, lowercase hex, rates 99 99 99 99 first
            #expect(text.contains("\n; from test"))
            let bytes = try #require(OperatorClipboard.decode(text))
            #expect(bytes == p.operatorBytes(2))
            #expect(OperatorClipboard.decode("not hex at all, definitely") == nil)
            #expect(OperatorClipboard.decode("0102") == nil)
        }

        @Test func pastingAnOperatorCopiesEverythingOrJustTheEnvelope() {
            var source = Patch.initVoice
            source[op: 0, field: .rate1] = 12
            source[op: 0, field: .level1] = 34
            source[op: 0, field: .outputLevel] = 56
            source[op: 0, field: .freqCoarse] = 9
            let bytes = source.operatorBytes(0)

            var all = Patch.initVoice
            all.setOperatorBytes(3, bytes)
            #expect(all.operatorBytes(3) == bytes)

            var envelope = Patch.initVoice
            envelope.setOperatorBytes(3, bytes, envelopeOnly: true)
            #expect(envelope[op: 3, field: .rate1] == 12)
            #expect(envelope[op: 3, field: .level1] == 34)
            #expect(envelope[op: 3, field: .outputLevel] == Patch.initVoice[op: 3, field: .outputLevel])   // untouched
            #expect(envelope[op: 3, field: .freqCoarse] == Patch.initVoice[op: 3, field: .freqCoarse])

            var clamped = Patch.initVoice
            clamped.setOperatorBytes(1, [UInt8](repeating: 255, count: 21))      // junk must be clamped to valid ranges
            #expect(clamped[op: 1, field: .rate1] == 99)
            #expect(clamped[op: 1, field: .leftCurve] == 3)
            #expect(clamped[op: 1, field: .oscMode] == 1)
        }

        @Test @MainActor func engineCopyPasteBetweenOperators() {
            let engine = SynthEngine(hosted: HostedSession())
            engine.setParameter(Patch.offset(op: 0, .outputLevel), 71)
            engine.setParameter(Patch.offset(op: 0, .freqCoarse), 5)
            let text = engine.operatorClipboardText(0)
            #expect(engine.pasteOperator(4, from: text))
            #expect(engine.patch[op: 4, field: .outputLevel] == 71)
            #expect(engine.patch[op: 4, field: .freqCoarse] == 5)
            #expect(!engine.pasteOperator(4, from: "hello"))
        }

        @Test func normalizeVelocityMakesFullVelocityQuieter() {
            func peak(normalize: Bool) -> Float {
                var voice = Patch.initVoice
                voice[op: 0, field: .keyVelSens] = 7          // the init voice ignores velocity; make it respond
                let core = SynthCore(sampleRate: 48000)
                core.setPatch(voice)
                core.setNormalizeVelocity(normalize)
                core.noteOn(69, velocity: 127)
                _ = core.render(frames: 2400)
                return core.render(frames: 4800).map(abs).max() ?? 0
            }
            let loud = peak(normalize: false), normalized = peak(normalize: true)
            #expect(normalized < loud, "loud=\(loud) normalized=\(normalized)")
        }

        @Test func portamentoGlidesFromThePreviousNote() {
            func earlyCrossings(portamento: Bool) -> Int {
                let core = SynthCore(sampleRate: 48000)
                core.setPortamento(time: portamento ? 100 : 0, glissando: false)
                core.noteOn(69, velocity: 100)
                _ = core.render(frames: 4800)
                core.noteOff(69)
                _ = core.render(frames: 2400)
                core.noteOn(81, velocity: 100)                  // an octave up: 880 Hz when it arrives
                let out = core.render(frames: 1920)             // first 40 ms
                var c = 0
                for i in 1..<out.count where (out[i - 1] < 0) != (out[i] < 0) { c += 1 }
                return c
            }
            let direct = earlyCrossings(portamento: false), glide = earlyCrossings(portamento: true)
            #expect(glide < direct - 8, "direct=\(direct) glide=\(glide)")
        }
    }

    /// Reproduces "scrolling through the instruments" in a host: voices change rapidly (from the host's thread, the editor and
    /// the MIDI program-change path) while the audio thread renders and notes are playing.
    @Suite struct PresetScrollingStressTests {
        static func factoryBanks() -> [Cartridge] {
            let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Shared/Resources/FactoryBanks")
            let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "syx" }.sorted { $0.path < $1.path }
            return files.compactMap { try? Cartridge(sysex: (try? Data(contentsOf: $0)) ?? Data()) }
        }

        @Test @MainActor func scrollingThroughEveryFactoryVoiceWhileRenderingDoesNotCrash() async throws {
            let banks = Self.factoryBanks()
            try #require(banks.count > 20)

            let unit = try AudioUnitTests().makeUnit()
            try unit.allocateRenderResources()
            let engine = SynthEngine(hosted: unit.session)          // the editor, attached to the same session
            engine.start()

            // The audio thread: render continuously, with notes sounding.
            let running = RunningFlag()
            let renderer = Thread {
                let format = unit.outputBusses[0].format
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
                buffer.frameLength = 512
                var time = 0.0
                var n = 0
                while running.value {
                    var flags = AudioUnitRenderActionFlags()
                    var ts = AudioTimeStamp(); ts.mSampleTime = time; ts.mFlags = .sampleTimeValid
                    _ = unit.renderBlock(&flags, &ts, 512, 0, buffer.mutableAudioBufferList, nil)
                    time += 512; n += 1
                    if n % 6 == 0 {
                        let note = UInt8(40 + (n / 6) % 40)
                        [UInt8]([0x90, note, 100]).withUnsafeBufferPointer { unit.scheduleMIDIEventBlock?(AUEventSampleTimeImmediate, 0, 3, $0.baseAddress!) }
                        [UInt8]([0x80, note &- 3, 0]).withUnsafeBufferPointer { unit.scheduleMIDIEventBlock?(AUEventSampleTimeImmediate, 0, 3, $0.baseAddress!) }
                    }
                    Thread.sleep(forTimeInterval: 0.001)
                }
            }
            renderer.start()

            // The host's thread: sets presets (like clicking through the host's preset list).
            let hostThread = Thread {
                var i = 0
                while running.value {
                    let preset = AUAudioUnitPreset()
                    preset.number = i % 32
                    unit.currentPreset = preset
                    _ = unit.factoryPresets
                    i += 1
                    Thread.sleep(forTimeInterval: 0.0005)
                }
            }
            hostThread.start()

            // The main thread: the editor changing voices and banks, plus MIDI program changes.
            for i in 0..<1500 {
                var settings = unit.session.settings
                let bank = banks[i % banks.count]
                settings.bank = bank
                settings.bankName = "bank \(i)"
                settings.program = i % 32
                settings.patch = bank.patch(at: i % 32)
                unit.session.apply(settings)
                engine.selectProgram((i * 7) % 32)
                if i % 5 == 0 { engine.setParameter(134, i % 32) }
                if i % 11 == 0 { unit.session.selectProgram((i * 3) % 32) }
                if i % 50 == 0 { _ = unit.fullState; unit.fullState = unit.fullState }
                try await Task.sleep(for: .milliseconds(1))
            }
            running.value = false
            try await Task.sleep(for: .milliseconds(100))
            unit.deallocateRenderResources()
        }
    }

    final class RunningFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = true
        var value: Bool { get { lock.lock(); defer { lock.unlock() }; return _value } set { lock.lock(); _value = newValue; lock.unlock() } }
    }

    @Suite struct OutputGainTests {
        @Test func gainScalesTheOutputButNotTheMeter() {
            func measure(_ gain: Float) -> (peak: Float, meter: Float) {
                let core = SynthCore(sampleRate: 48000)
                core.setOutputGain(gain)
                core.noteOn(69, velocity: 100)
                _ = core.render(frames: 2400)
                let peak = core.render(frames: 4800).map(abs).max() ?? 0
                return (peak, core.status().outputLevel)
            }
            let full = measure(1), half = measure(0.5), none = measure(0)
            #expect(abs(half.peak - full.peak * 0.5) < 0.01, "full=\(full.peak) half=\(half.peak)")
            #expect(none.peak == 0)
            #expect(abs(half.meter - full.meter) < 0.01)      // the meter reads before the volume, as the app's does
        }
    }

    /// A virtual MIDI destination that collects the SysEx messages sent to it, standing in for a real DX7.
    final class LoopbackDestination: @unchecked Sendable {
        private let lock = NSLock()
        private var _messages: [Data] = []
        private var assembler = SysExAssembler()
        private var client = MIDIClientRef()
        private var endpoint = MIDIEndpointRef()
        private(set) var uniqueID: Int32 = 0

        var messages: [Data] { lock.lock(); defer { lock.unlock() }; return _messages }

        init(name: String) {
            var uid: Int32 = 0
            MIDIClientCreateWithBlock("loopback" as CFString, &client) { _ in }
            // The handler is set after creation so it can capture `self`.
            var created = MIDIEndpointRef()
            MIDIDestinationCreateWithProtocol(client, name as CFString, ._1_0, &created) { [unowned self] list, _ in
                for packet in list.unsafeSequence() {
                    let count = Int(packet.pointee.wordCount)
                    let w = (UnsafeRawPointer(packet) + MemoryLayout<MIDIEventPacket>.offset(of: \.words)!).assumingMemoryBound(to: UInt32.self)
                    var i = 0
                    while i < count {
                        let type = w[i] >> 28
                        if type == 3, i + 1 < count {
                            lock.lock()
                            if let m = assembler.consume(w[i], w[i + 1]) { _messages.append(m) }
                            lock.unlock()
                        }
                        i += UMPSysEx.wordCount(forType: type)
                    }
                }
            }
            endpoint = created
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uid)
            uniqueID = uid
        }

        deinit { MIDIEndpointDispose(endpoint); MIDIClientDispose(client) }
    }

    @Suite(.serialized) struct DX7SysExEngineTests {
        /// Runs a test with a clean slate of saved settings and restores them afterwards.
        @MainActor static func withEngine(_ body: (SynthEngine) async throws -> Void) async rethrows {
            let d = UserDefaults.standard
            let keys = ["sysexDestination", "sysexChannel", "sendsEditsToDX7"]
            let saved = keys.map { d.object(forKey: $0) }
            keys.forEach(d.removeObject(forKey:))
            defer { for (k, v) in zip(keys, saved) { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } } }
            try await body(SynthEngine())
        }

        @Test @MainActor func incomingDumpsAndEditsChangeTheVoice() async {
            await Self.withEngine { engine in
                // single-voice dump
                var p = Patch.initVoice; p.name = "FROM DX7"; p.algorithm = 9
                engine.handleSysEx(Cartridge.singleVoiceSysex(p))
                #expect(engine.patch.name == "FROM DX7")
                #expect(engine.patch.algorithm == 9)

                // bank dump
                var bank = Cartridge(); var q = Patch.initVoice; q.name = "BANKED"
                bank.setPatch(q, at: 0)
                engine.handleSysEx(bank.sysexData())
                #expect(engine.bankName == "DX7 Dump")
                #expect(engine.patch.name == "BANKED")

                // parameter change, clamped to the parameter's range
                engine.handleSysEx(SysExMessage.parameterChange(channel: 0, offset: 134, value: 21))
                #expect(engine.patch.algorithm == 21)
                let levelOffset = Patch.offset(op: 0, .outputLevel)
                engine.handleSysEx(SysExMessage.parameterChange(channel: 0, offset: levelOffset, value: 127))
                #expect(engine.patch[levelOffset] == 99)

                // operator switches: bit 0 = OP6 … bit 5 = OP1
                engine.handleSysEx(SysExMessage.parameterChange(channel: 0, offset: 155, value: 0b000011))
                #expect(engine.operatorEnabled == [false, false, false, false, true, true])
                engine.handleSysEx(SysExMessage.parameterChange(channel: 0, offset: 155, value: 0b111111))
                #expect(engine.operatorEnabled == [Bool](repeating: true, count: 6))

                // garbage is ignored
                let before = engine.patch
                engine.handleSysEx(Data([0xF0, 0x7E, 0x00, 0xF7]))
                #expect(engine.patch == before)
            }
        }

        @Test @MainActor func outgoingMessagesReachTheChosenDestination() async throws {
            try await Self.withEngine { engine in
                let dx7 = LoopbackDestination(name: "Fake DX7")
                #expect(!engine.hasSysExDestination)
                engine.sendVoiceToDX7()                                    // no destination yet: nothing happens
                engine.sysexDestinationID = dx7.uniqueID
                engine.sysexChannel = 2

                var p = Patch.initVoice; p.name = "TO DX7"; p.algorithm = 3
                engine.load(patch: p)
                engine.sendVoiceToDX7()
                engine.requestVoiceFromDX7()
                engine.sendsEditsToDX7 = true
                engine.setParameter(134, 17)
                engine.operatorEnabled[0] = false                          // OP1 off: bit 5 clear → 0b011111
                try await Task.sleep(for: .seconds(2.5))

                let got = dx7.messages
                #expect(got.count == 4, "got \(got.map(\.count))")
                #expect(got.first == Cartridge.singleVoiceSysex(p, channel: 2))
                #expect(got.dropFirst().first == SysExMessage.request(channel: 2, .voice))
                #expect(got.dropFirst(2).first == SysExMessage.parameterChange(channel: 2, offset: 134, value: 17))
                #expect(got.last == SysExMessage.parameterChange(channel: 2, offset: 155, value: 0b011111))
            }
        }

        @Test @MainActor func aVoiceOrBankFromTheBrowserCanBeSentWithoutLoadingIt() async throws {
            try await Self.withEngine { engine in
                let dx7 = LoopbackDestination(name: "Fake DX7 3")
                engine.sysexDestinationID = dx7.uniqueID
                engine.sysexChannel = 4
                let before = engine.patch

                var other = Patch.initVoice; other.name = "BROWSED"; other.algorithm = 9
                var browsed = Cartridge(); browsed.setPatch(other, at: 0)
                engine.sendVoiceToDX7(other)
                engine.sendBankToDX7(browsed)
                try await Task.sleep(for: .seconds(3.5))

                let got = dx7.messages
                #expect(got.count == 2, "got \(got.map(\.count))")
                #expect(got.first == Cartridge.singleVoiceSysex(other, channel: 4))
                #expect(got.last?.count == 4104)
                #expect(got.last?[2] == 0x04, "channel byte \(String(describing: got.last?[2]))")
                #expect(engine.patch == before, "sending must not change the loaded voice")
            }
        }

        @Test @MainActor func aRequestFromTheDX7IsAnsweredWithTheCurrentVoiceOrBank() async throws {
            try await Self.withEngine { engine in
                let dx7 = LoopbackDestination(name: "Fake DX7 2")
                engine.sysexDestinationID = dx7.uniqueID
                engine.sysexChannel = 0
                var p = Patch.initVoice; p.name = "ASKED"
                engine.load(patch: p)
                engine.handleSysEx(SysExMessage.request(channel: 0, .voice))
                engine.handleSysEx(SysExMessage.request(channel: 0, .bank))
                try await Task.sleep(for: .seconds(3.5))
                let got = dx7.messages
                #expect(got.count == 2)
                #expect(got.first == Cartridge.singleVoiceSysex(p, channel: 0))
                #expect(got.last?.count == 4104)
            }
        }
    }

    @Suite struct ChannelFilterTests {
        func level(_ core: SynthCore) -> Float {
            let out = core.render(frames: 4800)
            return out.map { abs($0) }.max() ?? 0
        }

        @Test func omniAcceptsEveryChannel() {
            let core = SynthCore(sampleRate: 48000)
            core.handleMIDI(status: 0x95, data1: 69, data2: 100)      // note on, channel 6
            #expect(level(core) > 0.01)
        }

        @Test func filterIgnoresOtherChannels() {
            let core = SynthCore(sampleRate: 48000)
            core.setMIDIChannel(3)
            core.handleMIDI(status: 0x95, data1: 69, data2: 100)      // channel 6: ignored
            #expect(level(core) < 0.0001)
            core.handleMIDI(status: 0x92, data1: 69, data2: 100)      // channel 3: plays
            #expect(level(core) > 0.01)
        }

        @Test func mpeStandsAsideFromTheFilter() {
            let core = SynthCore(sampleRate: 48000)
            core.setMIDIChannel(1)
            core.setMPE(enabled: true, range: 24)
            core.handleMIDI(status: 0x95, data1: 69, data2: 100)
            #expect(level(core) > 0.01)
        }
    }

    @Suite struct TransposeAsScaleTests {
        func hz(_ core: SynthCore, note: Int) -> Double {
            core.noteOn(note, velocity: 100)
            _ = core.render(frames: 2400)
            let out = core.render(frames: 48000)
            var c = 0
            for i in 1..<out.count where (out[i - 1] < 0) != (out[i] < 0) { c += 1 }
            return Double(c) / 2
        }

        // A 7-note scale repeating at the octave: one scale period is 7 keys, not 12.
        let scl = "! seven\nseven\n 7\n" + (1...6).map { "\(Double($0) * 1200 / 7)" }.joined(separator: "\n") + "\n 2/1\n"

        func transposedPitch(asScale: Bool) -> Double {
            let core = SynthCore(sampleRate: 48000)
            #expect(core.setTuning(scl: scl) == nil)
            core.setTransposeAsScale(asScale)
            var p = Patch.initVoice
            p[144] = 36                      // +12 semitones
            core.setPatch(p)
            _ = core.render(frames: 64)
            return hz(core, note: 60)
        }

        @Test func optionChangesWhatAnOctaveOfTransposeMeans() {
            let on = transposedPitch(asScale: true)
            let off = transposedPitch(asScale: false)
            #expect(abs(on - off) > 5, "on=\(on) off=\(off)")
        }
    }

    @Suite struct MTSESPTests {
        @Test func clientIsPresentOnMacAndNotConnectedWithoutAMaster() {
            let core = SynthCore(sampleRate: 48000)
            #if os(macOS)
            #expect(core.isMTSSupported)
            #else
            #expect(!core.isMTSSupported)
            #endif
            #expect(!core.isMTSConnected || core.isMTSSupported)
        }

        @Test func withoutAMasterPitchIsUnchangedWhetherOrNotMTSIsOn() {
            func hz(_ on: Bool) -> Double {
                let core = SynthCore(sampleRate: 48000)
                core.setMTS(on)
                core.noteOn(69, velocity: 100)
                _ = core.render(frames: 2400)
                let out = core.render(frames: 48000)
                var c = 0
                for i in 1..<out.count where (out[i - 1] < 0) != (out[i] < 0) { c += 1 }
                return Double(c) / 2
            }
            let on = hz(true), off = hz(false)
            #expect(abs(on - 440) < 6, "on=\(on)")
            #expect(abs(on - off) < 1, "on=\(on) off=\(off)")
        }
    }

    @Suite struct MPETests {
        func hz(_ core: SynthCore) -> Double {
            _ = core.render(frames: 2400)
            let out = core.render(frames: 48000)
            var c = 0
            for i in 1..<out.count where (out[i - 1] < 0) != (out[i] < 0) { c += 1 }
            return Double(c) / 2
        }

        @Test func memberChannelBendsOnlyItsOwnNote() {
            let core = SynthCore(sampleRate: 48000)
            core.setMPE(enabled: true, range: 24)
            core.noteOn(69, velocity: 100, channel: 2)
            core.pitchBend(16383, channel: 2)      // +24 semitones at full deflection
            let f = hz(core)
            #expect(abs(f - 440 * 4) < 40, "f=\(f)")
        }

        @Test func withoutMPEEveryChannelBendsGlobally() {
            let core = SynthCore(sampleRate: 48000)
            core.noteOn(69, velocity: 100, channel: 2)
            core.pitchBend(16383, channel: 2)
            #expect(abs(hz(core) - 440 * pow(2, 3.0 / 12)) < 10)
        }

        @Test func masterChannelBendIsGlobalEvenInMPE() {
            let core = SynthCore(sampleRate: 48000)
            core.setMPE(enabled: true, range: 24)
            core.noteOn(69, velocity: 100, channel: 2)
            core.pitchBend(16383, channel: 1)
            #expect(abs(hz(core) - 440 * pow(2, 3.0 / 12)) < 10)
        }
    }

    @Suite struct WheelTests {
        func crossingsPerSecond(_ core: SynthCore, note: Int, bend: Int? = nil) -> Double {
            if let bend { core.pitchBend(bend) }
            core.noteOn(note, velocity: 100)
            _ = core.render(frames: 2400)
            let out = core.render(frames: 48000)
            var c = 0
            for i in 1..<out.count where (out[i - 1] < 0) != (out[i] < 0) { c += 1 }
            return Double(c) / 2
        }

        @Test func pitchWheelBendsByTheBendRange() {
            let up = crossingsPerSecond(SynthCore(sampleRate: 48000), note: 69, bend: 16383)
            let down = crossingsPerSecond(SynthCore(sampleRate: 48000), note: 69, bend: 0)
            #expect(abs(up - 440 * pow(2, 3.0 / 12)) < 10, "up=\(up)")      // +3 semitones ≈ 523 Hz
            #expect(abs(down - 440 * pow(2, -3.0 / 12)) < 10, "down=\(down)")
        }

        @Test func modWheelDeepensVibratoOnAPatchWithLFO() {
            var p = Patch.initVoice
            p[139] = 0        // no vibrato of its own: only the wheel adds it
            p[137] = 60       // LFO speed
            p[138] = 0        // LFO delay
            p[143] = 7        // pitch mod sensitivity
            func spread(_ mod: Int) -> Double {
                let core = SynthCore(sampleRate: 48000)
                core.setPatch(p)
                core.controlChange(1, mod)
                core.noteOn(69, velocity: 100)
                _ = core.render(frames: 4800)
                // measure how much the instantaneous period wobbles
                let out = core.render(frames: 48000)
                var last = 0, periods: [Double] = []
                for i in 1..<out.count where out[i - 1] < 0 && out[i] >= 0 { if last > 0 { periods.append(Double(i - last)) }; last = i }
                let mean = periods.reduce(0, +) / Double(max(1, periods.count))
                return periods.map { abs($0 - mean) }.reduce(0, +) / Double(max(1, periods.count))
            }
            let none = spread(0), full = spread(127)
            #expect(full > none * 1.3, "none=\(none) full=\(full)")
        }
    }

    @Suite struct ModWheelRoutingTests {
        @Test @MainActor func defaultRoutingMakesTheWheelAudibleOnAVibratoPatch() {
            let engine = SynthEngine(hosted: HostedSession())
            #expect(engine.routing(.wheel) == ControllerRouting(range: 100, pitch: true))
            #expect(engine.routing(.aftertouch).pitch)
            #expect(engine.routing(.foot).amp)
            #expect(engine.routing(.breath).amp)
        }
    }
}

extension AllEngineTests {
    @Suite struct MIDIMappingTests {
        @Test func scalingMatchesEachControlsRange() {
            #expect(MappableControl.voice(Patch.offset(op: 0, .outputLevel)).scaled(127) == 99)
            #expect(MappableControl.voice(Patch.offset(op: 0, .outputLevel)).scaled(0) == 0)
            #expect(MappableControl.voice(134).scaled(127) == 31)          // algorithm
            #expect(MappableControl.voice(135).scaled(127) == 7)           // feedback
            #expect(MappableControl.voice(Patch.offset(op: 2, .leftCurve)).scaled(127) == 3)
            #expect(MappableControl.cutoff.scaled(127) == 1)
            #expect(abs(MappableControl.cutoff.scaled(64) - 64.0 / 127) < 1e-9)
            #expect(MappableControl.voice(134).scaled(500) == 31)          // out-of-range input is clamped
        }

        @Test func everyNumericParameterHasARangeAndAName() {
            for offset in 0...144 {
                #expect(Parameters.maxValue(offset: offset) != nil, "offset \\(offset)")
                #expect(!Parameters.name(offset: offset).contains("?"), "offset \\(offset)")
            }
            #expect(Parameters.maxValue(offset: 145) == nil)               // the voice name isn't mappable
            #expect(Parameters.name(offset: Patch.offset(op: 2, .outputLevel)) == "OP3 Level")
        }

        @Test func aControllerAndAControlEachHaveOneAssignment() {
            var m = MIDIMapping()
            m.assign(.cutoff, to: .init(channel: 1, cc: 74))
            m.assign(.resonance, to: .init(channel: 1, cc: 71))
            m.assign(.volume, to: .init(channel: 1, cc: 74))               // takes CC 74 away from cutoff
            #expect(m.control(for: .init(channel: 1, cc: 74)) == .volume)
            #expect(m.key(for: .cutoff) == nil)
            m.assign(.resonance, to: .init(channel: 2, cc: 9))             // moves resonance to another controller
            #expect(m.key(for: .resonance) == .init(channel: 2, cc: 9))
            #expect(m.control(for: .init(channel: 1, cc: 71)) == nil)
            #expect(m.count == 2)
        }

        @Test func mappingSurvivesSavingAndLoading() throws {
            var m = MIDIMapping()
            m.assign(.voice(Patch.offset(op: 5, .outputLevel)), to: .init(channel: 3, cc: 20))
            m.assign(.masterTune, to: .init(channel: 1, cc: 21))
            let back = try JSONDecoder().decode(MIDIMapping.self, from: JSONEncoder().encode(m))
            #expect(back == m)
        }

        @Test func reservedControllersCannotBeMapped() {
            for cc in [1, 2, 4, 5, 64, 65, 120, 123, 127] { #expect(ReservedCC.isReserved(cc), "cc \\(cc)") }
            for cc in [3, 7, 10, 21, 74, 119] { #expect(!ReservedCC.isReserved(cc), "cc \\(cc)") }
        }

        @Test @MainActor func learnThenControl() {
            let defaults = UserDefaults.standard
            let saved = defaults.data(forKey: "midiMapping")
            defer { if let saved { defaults.set(saved, forKey: "midiMapping") } else { defaults.removeObject(forKey: "midiMapping") } }
            defaults.removeObject(forKey: "midiMapping")

            let engine = SynthEngine(hosted: HostedSession())
            let level = MappableControl.voice(Patch.offset(op: 0, .outputLevel))

            // Not learning and nothing mapped: ignored.
            #expect(!engine.handleController(channel: 1, cc: 21, value: 100))

            // A reserved controller is ignored even while learning.
            engine.beginLearning(level)
            #expect(!engine.handleController(channel: 1, cc: 64, value: 127))
            #expect(engine.learningControl == level)

            // The next real controller is learned and applied immediately.
            #expect(engine.handleController(channel: 1, cc: 21, value: 127))
            #expect(engine.learningControl == nil)
            #expect(engine.mappedController(for: level) == .init(channel: 1, cc: 21))
            #expect(engine.patch[op: 0, field: .outputLevel] == 99)

            // From now on that controller drives the parameter.
            #expect(engine.handleController(channel: 1, cc: 21, value: 0))
            #expect(engine.patch[op: 0, field: .outputLevel] == 0)
            #expect(!engine.handleController(channel: 2, cc: 21, value: 50))      // other channel: not mapped

            // Global controls work too, and mappings can be removed.
            engine.beginLearning(.cutoff)
            engine.handleController(channel: 1, cc: 74, value: 127)
            engine.handleController(channel: 1, cc: 74, value: 64)
            #expect(abs(engine.filterCutoff - 64.0 / 127) < 1e-9)
            engine.removeMapping(for: .cutoff)
            #expect(!engine.handleController(channel: 1, cc: 74, value: 10))
            engine.removeAllMappings()
            #expect(engine.mappedController(for: level) == nil)
        }
    }
}

extension AllEngineTests {
    @Suite struct SysExFormatTests {
        @Test func ump_roundTripsMessagesOfEveryLength() {
            for length in [0, 1, 5, 6, 7, 11, 12, 13, 18, 100, 4102] {
                let payload = (0..<length).map { UInt8($0 % 128) }
                let message = Data([0xF0] + payload + [0xF7])
                let words = UMPSysEx.words(for: message)
                #expect(words.count % 2 == 0)
                var assembler = SysExAssembler()
                var out: [Data] = []
                for i in stride(from: 0, to: words.count, by: 2) { if let m = assembler.consume(words[i], words[i + 1]) { out.append(m) } }
                #expect(out == [message], "length \(length)")
            }
        }

        @Test func ump_acceptsMessagesWithoutFramingBytes() {
            let words = UMPSysEx.words(for: Data([0x43, 0x10, 0x00]))
            var assembler = SysExAssembler()
            #expect(assembler.consume(words[0], words[1]) == Data([0xF0, 0x43, 0x10, 0x00, 0xF7]))
        }

        @Test func assembler_ignoresStrayContinuations() {
            var assembler = SysExAssembler()
            #expect(assembler.consume(0x3 << 28 | 2 << 20 | 2 << 16 | 0x0102, 0) == nil)      // "continue" with no start
            #expect(assembler.consume(0x3 << 28 | 3 << 20 | 1 << 16 | 0x0100, 0) == nil)      // "end" with no start
        }

        @Test func voiceDumpRoundTrips() throws {
            var p = Patch.initVoice
            p.name = "DX DUMP"; p.algorithm = 17; p[op: 1, field: .outputLevel] = 77
            let message = try #require(SysExMessage.parse(Cartridge.singleVoiceSysex(p)))
            guard case .voice(let parsed, let ok) = message else { Issue.record("not a voice"); return }
            #expect(parsed.bytes.prefix(155) == p.bytes.prefix(155))
            #expect(ok)
        }

        @Test func bankDumpRoundTrips() throws {
            var bank = Cartridge()
            var p = Patch.initVoice; p.name = "SLOT 9"
            bank.setPatch(p, at: 8)
            let message = try #require(SysExMessage.parse(bank.sysexData()))
            guard case .bank(let parsed) = message else { Issue.record("not a bank"); return }
            #expect(parsed.names[8] == "SLOT 9")
        }

        @Test func parameterChangesAndRequests() {
            let change = SysExMessage.parameterChange(channel: 2, offset: 134, value: 21)
            #expect([UInt8](change) == [0xF0, 0x43, 0x12, 1, 6, 21, 0xF7])        // offset 134 = 1<<7 + 6
            #expect(SysExMessage.parse(change) == .parameterChange(offset: 134, value: 21))
            #expect(SysExMessage.parse(SysExMessage.parameterChange(channel: 0, offset: 155, value: 0x3F)) == .parameterChange(offset: 155, value: 63))
            #expect(SysExMessage.parse(Data([0xF0, 0x43, 0x10, 2, 0, 5, 0xF7])) == nil)       // offset 256: out of range
            #expect(SysExMessage.parse(SysExMessage.request(channel: 0, .voice)) == .request(.voice))
            #expect(SysExMessage.parse(SysExMessage.request(channel: 3, .bank)) == .request(.bank))
        }

        @Test func foreignAndTruncatedMessagesAreIgnored() {
            #expect(SysExMessage.parse(Data([0xF0, 0x41, 0x10, 0, 0xF7])) == nil)             // not Yamaha
            #expect(SysExMessage.parse(Data([0xF0, 0x43])) == nil)
            #expect(SysExMessage.parse(Data([0xF0, 0x43, 0x00, 0x09, 0x20, 0x00, 0xF7])) == nil)   // bank header, no body
        }
    }
}

extension AllEngineTests {
    @Suite(.serialized) struct SysExTransportTests {
        final class Inbox: @unchecked Sendable {
            private let lock = NSLock()
            private var _messages: [Data] = []
            var messages: [Data] { lock.lock(); defer { lock.unlock() }; return _messages }
            func add(_ m: Data) { lock.lock(); _messages.append(m); lock.unlock() }
        }

        @Test func aBankSentToADestinationArrivesIntact() async throws {
            var client = MIDIClientRef()
            MIDIClientCreateWithBlock("test" as CFString, &client) { _ in }
            let inbox = Inbox()
            var assembler = SysExAssembler()
            var destination = MIDIEndpointRef()
            MIDIDestinationCreateWithProtocol(client, "iDexed Test Destination" as CFString, ._1_0, &destination) { list, _ in
                for packet in list.unsafeSequence() {
                    let count = Int(packet.pointee.wordCount)
                    let w = (UnsafeRawPointer(packet) + MemoryLayout<MIDIEventPacket>.offset(of: \.words)!).assumingMemoryBound(to: UInt32.self)
                    var i = 0
                    while i < count {
                        let type = w[i] >> 28
                        if type == 3, i + 1 < count, let m = assembler.consume(w[i], w[i + 1]) { inbox.add(m) }
                        i += UMPSysEx.wordCount(forType: type)
                    }
                }
            }
            defer { MIDIEndpointDispose(destination); MIDIClientDispose(client) }

            var uid: Int32 = 0
            MIDIObjectGetIntegerProperty(destination, kMIDIPropertyUniqueID, &uid)
            #expect(MIDISysExSender.destinations().contains { $0.id == uid && $0.name.contains("iDexed Test Destination") })

            var bank = Cartridge()
            var p = Patch.initVoice; p.name = "OVER WIRE"
            bank.setPatch(p, at: 11)
            let sender = MIDISysExSender()
            #expect(sender.send(bank.sysexData(), to: uid))
            #expect(sender.send(Cartridge.singleVoiceSysex(p), to: uid))
            #expect(!sender.send(Data([0xF0, 0x43, 0xF7]), to: 123_456_789))       // unknown destination
            // CoreMIDI paces SysEx at real MIDI speed (31,250 baud): a bank alone takes about 1.3 s.
            try await Task.sleep(for: .seconds(4))

            let got = inbox.messages
            #expect(got.count == 2)
            #expect(got.first == bank.sysexData())
            #expect(got.last == Cartridge.singleVoiceSysex(p))
        }

        @Test func sysexSentOnTheVirtualSourceIsReceivedByTheInput() async throws {
            let out = MIDIOutput()
            out.start()
            let inbox = Inbox()
            let input = MIDIInput()
            input.ignoredSources = []
            input.onSysEx = { inbox.add($0) }
            input.start()
            try await Task.sleep(for: .milliseconds(300))
            let message = SysExMessage.parameterChange(channel: 0, offset: 134, value: 12)
            out.sendSysEx(message)
            out.sendSysEx(Cartridge().sysexData())
            try await Task.sleep(for: .milliseconds(800))
            #expect(inbox.messages.first == message)
            #expect(inbox.messages.count == 2)
            #expect(inbox.messages.last?.count == 4104)
            out.stop()
        }
    }
}

extension AllEngineTests {
    @Suite struct BankBrowserTests {
        @Test func scanFindsSyxFilesRecursivelyAndSortsThem() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("iDexedBanks-\(UUID().uuidString)")
            let sub = root.appendingPathComponent("Yamaha/DX7II")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            try Cartridge().sysexData().write(to: root.appendingPathComponent("Bank_10.syx"))
            try Cartridge().sysexData().write(to: root.appendingPathComponent("Bank_2.SYX"))        // extension is case-insensitive
            try Cartridge().sysexData().write(to: sub.appendingPathComponent("Rom1a.syx"))
            try Data("not a bank".utf8).write(to: root.appendingPathComponent("notes.txt"))
            try Data([1, 2, 3]).write(to: root.appendingPathComponent(".hidden.syx"))               // hidden files are skipped

            let found = BankFolder.scan(root)
            #expect(found.map(\.name) == ["Bank 2", "Bank 10", "Rom1a"])         // natural sort, top level before sub-folders
            #expect(found.map(\.folder) == ["", "", "Yamaha/DX7II"])
            #expect(BankFolder.scan(root, limit: 1).count == 1)
            #expect(BankFolder.scan(root.appendingPathComponent("missing")).isEmpty)
        }

        @Test func loadReadsBanksAndSingleVoicesAndRejectsJunk() throws {
            let dir = FileManager.default.temporaryDirectory
            var bank = Cartridge(); var p = Patch.initVoice; p.name = "IN FILE"
            bank.setPatch(p, at: 4)
            let bankURL = dir.appendingPathComponent("test-bank-\(UUID().uuidString).syx")
            let voiceURL = dir.appendingPathComponent("test-voice-\(UUID().uuidString).syx")
            let junkURL = dir.appendingPathComponent("test-junk-\(UUID().uuidString).syx")
            defer { [bankURL, voiceURL, junkURL].forEach { try? FileManager.default.removeItem(at: $0) } }
            try bank.sysexData().write(to: bankURL)
            try Cartridge.singleVoiceSysex(p).write(to: voiceURL)
            try Data("junk".utf8).write(to: junkURL)

            #expect(try BankFolder.load(bankURL).names[4] == "IN FILE")
            #expect(try BankFolder.load(voiceURL).names[0] == "IN FILE")        // a single voice lands in slot 1
            #expect(throws: (any Error).self) { try BankFolder.load(junkURL) }
        }

        @Test @MainActor func replacingASlotUpdatesTheBankAndTheLoadedVoice() {
            let engine = SynthEngine(hosted: HostedSession())
            var voice = Patch.initVoice; voice.name = "DROPPED"; voice.algorithm = 5
            engine.selectProgram(3)
            engine.replaceVoice(at: 7, with: voice)                              // another slot: the played voice is unchanged
            #expect(engine.bank.names[7] == "DROPPED")
            #expect(engine.programIndex == 3)
            #expect(engine.patch.name != "DROPPED")
            engine.replaceVoice(at: 3, with: voice)                              // the played slot: reload it
            #expect(engine.patch.name == "DROPPED")
            #expect(engine.patch.algorithm == 5)
            engine.replaceVoice(at: 99, with: voice)                             // out of range: ignored
            #expect(engine.bank.names.filter { $0 == "DROPPED" }.count == 2)
        }
    }
}
