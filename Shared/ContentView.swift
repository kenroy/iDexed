import SwiftUI
import UniformTypeIdentifiers
import DexedKit

enum ImportKind { case sysex, scale, mapping }

enum Tab: String, CaseIterable, Identifiable {
    case voice = "Voice", operators = "Operators", bank = "Bank"
    var id: String { rawValue }
    /// Shorter labels for tight layouts (phone landscape) so segments never truncate.
    var shortTitle: String { self == .operators ? "OPs" : rawValue }
}

struct ContentView: View {
    @Environment(SynthEngine.self) private var engine
    @State private var tab: Tab = .voice
    @State private var selectedOperator = 1
    @State private var octave = 4
    @State private var maxOctave = 8      // how far the on-screen keyboard can scroll; set by the keyboard bar
    @State private var importing = false
    @State private var importKind: ImportKind = .sysex
    @State private var exportingBank: SysExDocument?
    @State private var exportingVoice: SysExDocument?
    @State private var errorMessage: String?
    @State private var typist = ComputerKeyboard()
    @State private var library = BankLibrary()
    @State private var editingName = false
    @Environment(\.scenePhase) private var scenePhase
    /// The keyboard can collapse to a movable corner button so the editor gets the height.
    @AppStorage("keyboardCollapsed") private var keyboardCollapsed = false
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var landscapePhone: Bool { verticalSizeClass == .compact }
    #else
    private var landscapePhone: Bool { false }
    #endif

    private var shortcutActions: ShortcutActions {
        ShortcutActions(
            toggleOperator: { engine.operatorEnabled[$0 - 1].toggle() },
            focusOperator: { selectedOperator = $0; tab = .operators },
            show: { tab = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(importing: $importing, importKind: $importKind, editingName: $editingName, tab: $tab, landscapePhone: landscapePhone, exportBank: { exportingBank = SysExDocument(data: engine.exportBank()) },
                       exportVoice: { exportingVoice = SysExDocument(data: engine.exportVoice()) })
            if !landscapePhone {
                Picker("Section", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16).padding(.bottom, 8)
            }

            ScrollView {
                Group {
                    switch tab {
                    case .voice: VoiceView(selectedOperator: $selectedOperator)
                    case .operators: OperatorsView(selectedOperator: $selectedOperator)
                    case .bank: BankView(showTab: $tab, library: library)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.interactively)

            if !keyboardCollapsed {
                KeyboardBar(octave: $octave, maxOctave: $maxOctave, landscapePhone: landscapePhone, collapse: { withAnimation { keyboardCollapsed = true } })
            }
        }
        .overlay {
            if keyboardCollapsed {
                FloatingKeyboardButton { withAnimation { keyboardCollapsed = false } }
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            engine.start()
            let engine = engine, octave = $octave
            typist.noteOn = { engine.noteOn($0) }
            typist.noteOff = { engine.noteOff($0) }
            let maxOctave = $maxOctave
            // One position drives everything: the on-screen arrows, the ← → keys, Z / X, and the base of the A–L piano.
            let visibleOctave = { max(0, min(octave.wrappedValue, maxOctave.wrappedValue)) }
            let scroll: (Int) -> Void = { step in
                octave.wrappedValue = max(0, min(maxOctave.wrappedValue, visibleOctave() + step))
            }
            typist.octave = visibleOctave        // the A key plays the first key you can see
            typist.shiftOctave = scroll
            typist.scrollKeyboard = scroll
            if !engine.isHostedPlugin { typist.start() }   // the host owns the keyboard inside a plug-in
        }
        .onChange(of: editingName) { typist.isTypingText = editingName }
        .onChange(of: scenePhase) { if scenePhase != .active { typist.releaseAll() } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.sysex, .data, .plainText]) { result in
            switch result {
            case .success(let url):
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    let name = url.deletingPathExtension().lastPathComponent
                    switch importKind {
                    case .sysex:
                        try engine.importSysEx(data, name: name)
                        tab = .bank
                    case .scale, .mapping:
                        let text = String(decoding: data, as: UTF8.self)
                        if let message = importKind == .scale ? engine.loadTuning(scl: text, kbm: nil, name: name)
                                                               : engine.loadMapping(text, name: name) {
                            errorMessage = message
                        }
                    }
                } catch { errorMessage = error.localizedDescription }
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .fileExporter(isPresented: Binding(get: { exportingBank != nil }, set: { if !$0 { exportingBank = nil } }),
                      document: exportingBank, contentType: .sysex, defaultFilename: "\(engine.bankName).syx") { _ in }
        .fileExporter(isPresented: Binding(get: { exportingVoice != nil }, set: { if !$0 { exportingVoice = nil } }),
                      document: exportingVoice, contentType: .sysex, defaultFilename: "\(engine.patch.name).syx") { _ in }
        .focusedSceneValue(\.shortcutActions, shortcutActions)
        .alert("Couldn't open file", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }
}

// MARK: - Header

private struct HeaderView: View {
    @Environment(SynthEngine.self) private var engine
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Binding var importing: Bool
    @Binding var importKind: ImportKind
    @Binding var editingName: Bool
    @Binding var tab: Tab
    var landscapePhone: Bool
    var exportBank: () -> Void
    var exportVoice: () -> Void
    @State private var nameDraft = ""

    private var compact: Bool { sizeClass == .compact }

    var body: some View {
        @Bindable var engine = engine
        Group {
            if landscapePhone {
                // Short and wide: one slim row, with the section picker folded in.
                HStack(spacing: 10) {
                    display.frame(maxWidth: 200).layoutPriority(1)
                    navButtons
                    Picker("Section", selection: $tab) {
                        ForEach(Tab.allCases) { Text($0.shortTitle).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()                       // never squeeze or truncate the segment titles
                    .layoutPriority(2)
                    level(volume: $engine.masterVolume, tight: true)
                    menu
                }
            } else if compact {
                VStack(spacing: 10) {
                    HStack(spacing: 10) { display; navButtons; menu }
                    HStack(spacing: 10) { level(volume: $engine.masterVolume) }
                }
            } else {
                HStack(spacing: 12) {
                    display.frame(maxWidth: 320)
                    navButtons
                    Spacer(minLength: 0)
                    menu
                    level(volume: $engine.masterVolume).frame(maxWidth: 260)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, landscapePhone ? 4 : 10)
        .alert("Rename Voice", isPresented: $editingName) {
            TextField("Voice name", text: $nameDraft)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.characters)
                #endif
            Button("Rename") { engine.setPatchName(String(nameDraft.prefix(10))) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Up to 10 characters.")
        }
    }

    /// LCD-style display; tap to rename.
    private var display: some View {
        Button {
            nameDraft = engine.patch.name
            editingName = true
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(engine.bankName.uppercased())  \(String(format: "%02d", engine.programIndex + 1))/32")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.lcd.opacity(0.65))
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(engine.patch.name.isEmpty ? "—" : engine.patch.name)
                    .font(.system(landscapePhone ? .headline : .title2, design: .monospaced).weight(.bold))
                    .foregroundStyle(Theme.lcd)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, landscapePhone ? 4 : 8)
            .background(Theme.lcdBackground, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.black.opacity(0.6), lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Voice name \(engine.patch.name)")
        .accessibilityHint("Double tap to rename")
    }

    private var navButtons: some View {
        HStack(spacing: 4) {
            Button { engine.selectProgram(engine.programIndex - 1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("Previous voice")
            Button { engine.selectProgram(engine.programIndex + 1) } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel("Next voice")
        }
        .buttonStyle(.bordered)
    }

    private var menu: some View {
        Menu {
            Button("Import SysEx…", systemImage: "square.and.arrow.down") { importKind = .sysex; importing = true }
            Button("Export Bank…", systemImage: "square.and.arrow.up", action: exportBank)
            Button("Export Voice…", systemImage: "square.and.arrow.up", action: exportVoice)
            Divider()
            Button("Rename Voice…", systemImage: "pencil") {
                nameDraft = engine.patch.name
                editingName = true
            }
            Button("Store Voice in Bank", systemImage: "tray.and.arrow.down") { engine.storeCurrentPatch() }
            Button("Initialize Voice", systemImage: "arrow.counterclockwise") { engine.load(patch: .initVoice) }
            Divider()
            Menu("Factory Banks", systemImage: "music.note.list") {
                ForEach(FactoryBanks.all) { bank in
                    Button(bank.name) {
                        if let d = try? Data(contentsOf: bank.url) { try? engine.importSysEx(d, name: bank.name) }
                    }
                }
            }
            Menu("Tuning", systemImage: "tuningfork") {
                if let name = engine.tuningName { Text("Active: \(name)") }
                Button("Standard Tuning (12-TET)") { engine.resetTuning() }
                Button("Load Scala Scale (.scl)…") { importKind = .scale; importing = true }
                Button("Add Keyboard Mapping (.kbm)…") { importKind = .mapping; importing = true }
                Toggle("Transpose 12 as Scale", isOn: Binding(get: { engine.transposeAsScale }, set: { engine.transposeAsScale = $0 }))
                Text("On a custom tuning, an octave of transpose moves by one whole scale period.")
                #if os(macOS)
                if engine.mtsSupported && !engine.isHostedPlugin {      // the sandboxed plug-in can't reach a master
                    Divider()
                    Toggle("Follow MTS-ESP Master", isOn: Binding(get: { engine.mtsEnabled }, set: { engine.mtsEnabled = $0 }))
                    Text(engine.mtsEnabled ? (engine.mtsConnected ? "Connected: \(engine.mtsScaleName.isEmpty ? "MTS-ESP master" : engine.mtsScaleName)"
                                                                   : "No MTS-ESP master running")
                                           : "Off")
                }
                #endif
            }
            Picker("MIDI Channel", systemImage: "pianokeys", selection: Binding(get: { engine.midiChannel }, set: { engine.midiChannel = $0 })) {
                Text("Omni (all channels)").tag(0)
                ForEach(1...16, id: \.self) { Text("Channel \($0)").tag($0) }
            }
            Divider()
            if !engine.isHostedPlugin {
                Toggle("Send MIDI Out (“iDexed”)", systemImage: "cable.connector",
                       isOn: Binding(get: { engine.sendsMIDI }, set: { engine.sendsMIDI = $0 }))
                Toggle("Play Sound on This Device", systemImage: "speaker.wave.2",
                       isOn: Binding(get: { engine.playsLocalSound }, set: { engine.playsLocalSound = $0 }))
                Menu("MIDI Mapping", systemImage: "slider.horizontal.3") {
                    Toggle("MIDI Learn Mode", systemImage: "hand.tap",
                           isOn: Binding(get: { engine.midiLearnMode }, set: { engine.midiLearnMode = $0 }))
                    Text("Tap a knob, then move a knob on your controller.")
                    Button("Remove All Mappings (\(engine.midiMapping.count))", systemImage: "trash", role: .destructive) {
                        engine.removeAllMappings()
                    }
                    .disabled(engine.midiMapping.isEmpty)
                }
                dx7Menu
                Divider()
            }
            Button("Panic (all notes off)", systemImage: "speaker.slash") { engine.panic() }
        } label: {
            Image(systemName: "ellipsis.circle").font(.title2)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Menu")
    }

    /// Talk to a real DX7 (or any device that speaks Yamaha SysEx) through a MIDI output port.
    private var dx7Menu: some View {
        Menu("DX7 SysEx", systemImage: "arrow.left.arrow.right") {
            let ports = engine.sysexDestinations()
            Picker("Send To", selection: Binding(get: { engine.sysexDestinationID }, set: { engine.sysexDestinationID = $0 })) {
                Text("No Port").tag(Int32?.none)
                ForEach(ports) { Text($0.name).tag(Int32?.some($0.id)) }
                if let saved = engine.sysexDestinationID, !ports.contains(where: { $0.id == saved }) {
                    Text("Saved port (not connected)").tag(Int32?.some(saved))
                }
            }
            Picker("DX7 Channel", selection: Binding(get: { engine.sysexChannel }, set: { engine.sysexChannel = $0 })) {
                ForEach(0..<16, id: \.self) { Text("Channel \($0 + 1)").tag($0) }
            }
            Divider()
            Button("Send Voice to DX7", systemImage: "square.and.arrow.up") { engine.sendVoiceToDX7() }
                .disabled(!engine.hasSysExDestination)
            Button("Send Bank to DX7", systemImage: "square.and.arrow.up.on.square") { engine.sendBankToDX7() }
                .disabled(!engine.hasSysExDestination)
            Button("Request Voice from DX7", systemImage: "square.and.arrow.down") { engine.requestVoiceFromDX7() }
                .disabled(!engine.hasSysExDestination)
            Button("Request Bank from DX7", systemImage: "square.and.arrow.down.on.square") { engine.requestBankFromDX7() }
                .disabled(!engine.hasSysExDestination)
            Toggle("Send Edits to DX7", systemImage: "waveform.path",
                   isOn: Binding(get: { engine.sendsEditsToDX7 }, set: { engine.sendsEditsToDX7 = $0 }))
                .disabled(!engine.hasSysExDestination)
            Text("Dumps and edits arriving on any MIDI input are received automatically.")
        }
    }

    @ViewBuilder
    private func level(volume: Binding<Float>, tight: Bool = false) -> some View {
        captioned("LEVEL") {
            OutputMeter(level: engine.status.outputLevel)
                .frame(minWidth: tight ? 30 : 80, maxWidth: tight ? 110 : nil)
        }
        if !tight {
            #if os(iOS)
            if !engine.isHostedPlugin {
                RoutePickerButton().frame(width: 30, height: 30).accessibilityLabel("Audio output")
            }
            #endif
        }
        captioned("VOLUME") {
            HStack(spacing: 6) {
                #if os(macOS)
                Image(systemName: "speaker.fill").foregroundStyle(Theme.dim)      // sits right beside the slider it labels
                #endif
                Slider(value: volume, in: 0...1)
                    .frame(minWidth: tight ? 60 : 90, maxWidth: tight ? 120 : compact ? .infinity : 110)
                    .accessibilityLabel("Volume")
                    .midiMappable(.volume)
            }
        }
    }

    /// A control with a small caption underneath, so it is clear what it is.
    private func captioned<C: View>(_ text: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 2) {
            content()
            Text(text)
                .font(.system(size: 8, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.dim)
        }
    }
}

// MARK: - Keyboard

private struct KeyboardBar: View {
    @Environment(SynthEngine.self) private var engine
    @Binding var octave: Int
    @Binding var maxOctave: Int
    var landscapePhone = false
    var collapse: () -> Void = {}
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let compact = sizeClass == .compact
        let arrowWidth: CGFloat = compact ? 30 : 36
        let keyWidth: CGFloat = compact ? 36 : 46
        GeometryReader { geo in
            // Fixed comfortable key width; the window decides how many keys fit.
            let keyboardWidth = geo.size.width - 24 - 16 - 2 * arrowWidth - 2 * 32 - 8
            let whiteKeys = max(8, Int(keyboardWidth / keyWidth))
            let span = (whiteKeys * 12 + 6) / 7 + 1                // semitones covered
            let limit = max(0, (127 - span) / 12)
            let current = max(0, min(octave, limit))
            HStack(spacing: 8) {
                VStack(spacing: 6) {
                    do {
                        Button(action: collapse) {
                            Image(systemName: "chevron.down").font(.footnote.weight(.semibold))
                                .frame(width: arrowWidth - 12, height: 26)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Hide keyboard")
                    }
                    scrollButton("chevron.left", width: arrowWidth, label: "Lower octave", disabled: current <= 0) { octave = current - 1 }
                }
                HStack(spacing: 4) {
                    Wheel(title: "Pitch bend", caption: "PITCH", value: Double(engine.pitchBendValue) / 16383, springsToCenter: true) {
                        engine.setPitchBend(Int(($0 * 16383).rounded()))
                    }
                    Wheel(title: "Mod wheel", caption: "MOD", value: Double(engine.modWheelValue) / 127, springsToCenter: false) {
                        engine.setModWheel(Int(($0 * 127).rounded()))
                    }
                }
                .frame(width: 64)
                KeyboardView(firstNote: current * 12, whiteKeyCount: whiteKeys, activeNotes: engine.status.heldNotes.union(engine.activeNotes),
                             onNoteOn: { engine.noteOn($0, velocity: $1) }, onNoteOff: { engine.noteOff($0) })
                scrollButton("chevron.right", width: arrowWidth, label: "Higher octave", disabled: current >= limit) { octave = current + 1 }
            }
            .padding(.horizontal, 12).padding(.vertical, landscapePhone ? 4 : 8)
            .onChange(of: limit, initial: true) { maxOctave = limit; octave = max(0, min(octave, limit)) }
        }
        .frame(height: landscapePhone ? 112 : compact ? 150 : 210)
        .background(Color.black.opacity(0.35))
    }

    private func scrollButton(_ symbol: String, width: CGFloat, label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .frame(width: width - 12)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .disabled(disabled)
        .accessibilityLabel(label)
    }
}

/// The collapsed-keyboard button. Tap to bring the keyboard back; drag to put it anywhere on screen.
/// The position is remembered as a fraction of the screen so it survives rotation and relaunch.
private struct FloatingKeyboardButton: View {
    var action: () -> Void
    @AppStorage("keyboardButtonX") private var fractionX = 0.96
    @AppStorage("keyboardButtonY") private var fractionY = 0.90

    private let radius: CGFloat = 26
    private let inset: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let margin = radius + inset
            let usableW = max(1, geo.size.width - 2 * margin)
            let usableH = max(1, geo.size.height - 2 * margin)
            Image(systemName: "pianokeys")
                .font(.title2)
                .frame(width: radius * 2, height: radius * 2)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Theme.panelStroke))
                .shadow(radius: 4, y: 2)
                .contentShape(Circle())
                .position(x: margin + fractionX * usableW, y: margin + fractionY * usableH)
                .gesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .named("floatingArea"))
                        .onChanged { g in
                            fractionX = min(1, max(0, (g.location.x - margin) / usableW))
                            fractionY = min(1, max(0, (g.location.y - margin) / usableH))
                        }
                )
                .onTapGesture(perform: action)
                .accessibilityLabel("Show keyboard")
                .accessibilityHint("Drag to move this button")
                .accessibilityAddTraits(.isButton)
        }
        .coordinateSpace(name: "floatingArea")
    }
}
