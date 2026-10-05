import SwiftUI
import UniformTypeIdentifiers
import DexedKit

/// Browse banks (the bundled factory banks and a folder of your own), audition voices, and copy them into the current bank.
struct LibraryPanel: View {
    @Environment(SynthEngine.self) private var engine
    var library: BankLibrary
    @State private var choosingFolder = false

    var body: some View {
        Panel(title: "Library") {
            bankPicker
            if let error = library.previewError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if let preview = library.preview, let selected = library.selected {
                HStack {
                    Button("Use This Bank", systemImage: "tray.and.arrow.down") {
                        engine.load(bank: preview, name: selected.name)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .foregroundStyle(.black)
                    Spacer()
                    Text("Tap a voice to audition it. Drag it onto a slot of the current bank, or use ⋯ to copy it.")
                        .font(.caption2).foregroundStyle(Theme.dim)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                voiceList(preview)
            } else if library.previewError == nil {
                Text("Choose a bank to see its voices.").font(.callout).foregroundStyle(Theme.dim)
            }
            if !engine.isHostedPlugin { folderControls }
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { library.chooseFolder(url) }
        }
    }

    private var bankPicker: some View {
        Picker("Bank", selection: Binding(get: { library.selected }, set: { library.select($0) })) {
            Text("Choose a bank…").tag(BankLibrary.Entry?.none)
            Section("Factory Banks") {
                ForEach(library.factory) { Text($0.name).tag(BankLibrary.Entry?.some($0)) }
            }
            if !library.user.isEmpty {
                Section(library.folderName ?? "My Banks") {
                    ForEach(library.user) { entry in
                        Text(entry.folder.isEmpty ? entry.name : "\(entry.folder) / \(entry.name)").tag(BankLibrary.Entry?.some(entry))
                    }
                }
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Bank to browse")
    }

    private func voiceList(_ bank: Cartridge) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<Cartridge.voiceCount, id: \.self) { i in
                let voice = bank.patch(at: i)
                HStack(spacing: 8) {
                    Text(String(format: "%02d", i + 1)).font(.callout.monospacedDigit()).foregroundStyle(Theme.dim)
                        .frame(width: 28, alignment: .leading)
                    Text(voice.name.isEmpty ? "—" : voice.name).lineLimit(1)
                    Spacer(minLength: 4)
                    Menu {
                        Button("Copy to Current Slot (\(engine.programIndex + 1))") { engine.replaceVoice(at: engine.programIndex, with: voice) }
                        Menu("Copy to Slot") {
                            ForEach(0..<Cartridge.voiceCount, id: \.self) { slot in
                                Button("\(slot + 1)  \(engine.bank.names[slot])") { engine.replaceVoice(at: slot, with: voice) }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").foregroundStyle(Theme.dim)
                    }
                    .menuStyle(.button).buttonStyle(.plain)
                    .accessibilityLabel("Copy \(voice.name) into the current bank")
                }
                .padding(.vertical, 7).padding(.horizontal, 4)
                .contentShape(Rectangle())
                .onTapGesture { engine.load(patch: voice) }
                .draggable(VoicePayload(voice))
                Divider().opacity(0.25)
            }
        }
    }

    private var folderControls: some View {
        HStack {
            Button(library.folderName == nil ? "Choose Folder of Banks…" : "Change Folder…", systemImage: "folder") { choosingFolder = true }
            if library.folderName != nil {
                Button("Rescan", systemImage: "arrow.clockwise") { library.rescan() }
                Button("Forget", systemImage: "xmark.circle", role: .destructive) { library.forgetFolder() }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
