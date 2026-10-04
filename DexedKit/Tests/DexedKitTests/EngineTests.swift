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
            #expect(engine.modWheelRange == 100)
            #expect(engine.modWheelPitch)
        }
    }
}
