import SwiftUI
import UniformTypeIdentifiers
import DexedKit

/// Browse banks (the bundled factory banks, the app's Cartridges folder and a folder of your own), audition voices, and
/// copy them into the current bank. A searchable list of banks sits beside the voices of the selected one.
struct LibraryPanel: View {
    /// `.combined` is the whole library in one panel; `.banks` and `.voices` are its two halves, for a three-column layout.
    enum Mode { case combined, banks, voices }

    @Environment(SynthEngine.self) private var engine
    var library: BankLibrary
    var mode: Mode = .combined
    enum PickingKind { case folder, banks }
    @State private var picking: PickingKind?
    @State private var importSummary: String?
    @State private var query = ""
    /// When there's only room for one pane: true shows the bank list, false shows the voices.
    @State private var showingList = true
    @State private var expanded: Set<String> = ["Factory Banks", "Cartridges"]
    @Environment(\.openURL) private var openURL

    private let browserHeight: CGFloat = 600

    var body: some View {
        switch mode {
        case .combined:
            Panel(title: "Library") {
                searchAndFolders
                ViewThatFits(in: .horizontal) {
                    sideBySide
                    onePane
                }
                emptyFolderHint
            }
            .modifier(filePicking)
        case .banks:
            Panel(title: "Banks") {
                searchAndFolders
                ScrollView { bankList }
                    .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                emptyFolderHint
            }
            .modifier(filePicking)
        case .voices:
            Panel(title: "Voices") {
                voicePane(scrolls: true, fillsHeight: true)
            }
        }
    }

    private var searchAndFolders: some View {
        HStack(spacing: 8) {
            searchField
            if !engine.isHostedPlugin { foldersMenu }
        }
    }

    /// One file picker for both jobs: choosing a folder of banks to browse, and importing banks into Cartridges.
    private var filePicking: FilePicking { FilePicking(picking: $picking, summary: $importSummary, library: library) }

    // MARK: Layouts

    /// Wide: the bank list and the voices of the selected bank, side by side.
    private var sideBySide: some View {
        HStack(alignment: .top, spacing: 12) {
            ScrollView { bankList }
                .frame(width: 200, height: browserHeight)
                .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 8) {
                voicePane(scrolls: true)
            }
            // An explicit ideal width: otherwise the long hint text makes the pane's ideal width huge and ViewThatFits
            // gives up on this layout even though it fits comfortably.
            .frame(minWidth: 280, idealWidth: 280, maxWidth: .infinity, alignment: .topLeading)
        }
    }

    /// Narrow: one pane at a time, with a back button from the voices to the list.
    private var onePane: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showingList || library.selected == nil {
                ScrollView { bankList }
                    .frame(height: 420)
                    .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Button { showingList = true } label: { Label("Banks", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                voicePane(scrolls: false)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.dim)
            TextField("Search banks", text: $query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.dim) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: Bank list

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private func matches(_ entry: BankLibrary.Entry) -> Bool {
        guard searching else { return true }
        let q = query.trimmingCharacters(in: .whitespaces)
        return entry.name.localizedCaseInsensitiveContains(q) || entry.folder.localizedCaseInsensitiveContains(q)
    }

    private var bankList: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            section("Factory Banks", entries: library.factory)
            section("Cartridges", entries: library.cartridges)
            if let name = library.folderName { section(name, entries: library.user, key: "folder:" + name) }
            if searching && ![library.factory, library.cartridges, library.user].contains(where: { $0.contains(where: matches) }) {
                Text("No banks match “\(query)”.").font(.callout).foregroundStyle(Theme.dim).padding(10)
            }
        }
        .padding(6)
    }

    /// A collapsible section of banks; entries in subfolders are grouped under the folder's path.
    @ViewBuilder
    private func section(_ title: String, entries: [BankLibrary.Entry], key: String? = nil) -> some View {
        let shown = entries.filter(matches)
        if !shown.isEmpty || (!searching && !entries.isEmpty) {
            let key = key ?? title
            let open = searching || expanded.contains(key)
            header(title, count: shown.count, open: open) { toggle(key) }
            if open {
                let loose = shown.filter { $0.folder.isEmpty }
                ForEach(loose) { bankRow($0) }
                let folders = Dictionary(grouping: shown.filter { !$0.folder.isEmpty }, by: \.folder)
                ForEach(folders.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, id: \.self) { folder in
                    let folderKey = key + "/" + folder
                    let folderOpen = searching || expanded.contains(folderKey)
                    header(folder, count: folders[folder]?.count ?? 0, open: folderOpen, indent: 10, subtle: true) { toggle(folderKey) }
                    if folderOpen {
                        ForEach(folders[folder] ?? []) { bankRow($0, indent: 20) }
                    }
                }
            }
        }
    }

    private func header(_ title: String, count: Int, open: Bool, indent: CGFloat = 0, subtle: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2.weight(.bold)).frame(width: 12)
                Text(title).font(subtle ? .caption.weight(.semibold) : .footnote.weight(.bold)).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)").font(.caption2.monospacedDigit())
            }
            .foregroundStyle(Theme.dim)
            .padding(.leading, 4 + indent).padding(.trailing, 6).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count) banks, \(open ? "expanded" : "collapsed")")
    }

    private func bankRow(_ entry: BankLibrary.Entry, indent: CGFloat = 10) -> some View {
        let selected = library.selected == entry
        return Button {
            library.select(entry)
            showingList = false
        } label: {
            Text(entry.name).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, indent + 8).padding(.trailing, 6).padding(.vertical, 5)
                .background(selected ? Theme.accent.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func toggle(_ key: String) {
        if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
    }

    // MARK: Voices

    @ViewBuilder
    private func voicePane(scrolls: Bool, fillsHeight: Bool = false) -> some View {
        if let error = library.previewError {
            Text(error).font(.caption).foregroundStyle(.orange)
        } else if let preview = library.preview, let selected = library.selected {
            HStack(spacing: 8) {
                Text(selected.name).font(.headline).lineLimit(1)
                Spacer(minLength: 4)
                bankMenu(preview, selected)
            }
            Button("Use This Bank", systemImage: "tray.and.arrow.down") {
                engine.load(bank: preview, name: selected.name)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .foregroundStyle(.black)
            Text("Tap a voice to audition it. Drag it onto a slot of the current bank, or right-click for more.")
                .font(.caption2).foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
            if scrolls {
                ScrollView { voiceList(preview) }
                    .frame(maxHeight: fillsHeight ? .infinity : browserHeight - 110)
            } else {
                voiceList(preview)
            }
        } else {
            Text("Choose a bank from the list to see its voices.").font(.callout).foregroundStyle(Theme.dim)
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            if fillsHeight { Spacer(minLength: 0) }
        }
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
                        voiceActions(voice)
                    } label: {
                        Image(systemName: "ellipsis.circle").foregroundStyle(Theme.dim)
                    }
                    .menuStyle(.button).buttonStyle(.plain)
                    .accessibilityLabel("Actions for \(voice.name)")
                }
                .padding(.vertical, 7).padding(.horizontal, 4)
                .contentShape(Rectangle())
                .onTapGesture { engine.load(patch: voice) }
                .draggable(VoicePayload(voice))
                .contextMenu { voiceActions(voice) }
                Divider().opacity(0.25)
            }
        }
    }

    /// What you can do with a voice from the browser: copy it into the current bank, or send it to a DX7.
    @ViewBuilder
    private func voiceActions(_ voice: Patch) -> some View {
        Button("Copy to Current Slot (\(engine.programIndex + 1))") { engine.replaceVoice(at: engine.programIndex, with: voice) }
        Menu("Copy to Slot") {
            ForEach(0..<Cartridge.voiceCount, id: \.self) { slot in
                Button("\(slot + 1)  \(engine.bank.names[slot])") { engine.replaceVoice(at: slot, with: voice) }
            }
        }
        if !engine.isHostedPlugin {
            Divider()
            Button("Send Voice to DX7", systemImage: "arrow.up.right.square") { engine.sendVoiceToDX7(voice) }
                .disabled(!engine.hasSysExDestination)
        }
    }

    /// Actions for the whole bank being browsed.
    private func bankMenu(_ bank: Cartridge, _ entry: BankLibrary.Entry) -> some View {
        Menu {
            if !engine.isHostedPlugin {
                Button("Send Bank to DX7", systemImage: "arrow.up.right.square") { engine.sendBankToDX7(bank) }
                    .disabled(!engine.hasSysExDestination)
                if !engine.hasSysExDestination { Text("Choose a DX7 under ⋯ ▸ DX7 SysEx first") }
                #if os(macOS)
                if !entry.isFactory {
                    Divider()
                    Button("Show in Finder", systemImage: "folder") { library.reveal(entry) }
                }
                #endif
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.button).buttonStyle(.bordered)
        .controlSize(.regular)
        .accessibilityLabel("Bank actions")
    }

    // MARK: Folder controls

    /// Says why a chosen folder shows no banks, when it holds files that aren't `.syx`.
    @ViewBuilder
    private var emptyFolderHint: some View {
        if let name = library.folderName, library.user.isEmpty {
            let skipped = library.skippedInFolder.sorted { $0.value > $1.value }
            if skipped.isEmpty {
                Text("No .syx banks found in “\(name)”.").font(.caption).foregroundStyle(.orange)
            } else {
                let list = skipped.prefix(4).map { ".\($0.key.isEmpty ? "(none)" : $0.key) × \($0.value)" }.joined(separator: ", ")
                Text("No .syx banks found in “\(name)”. Skipped other files: \(list). iDexed reads DX7 SysEx (.syx) banks only.")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Where banks come from: the Cartridges folder, any other folder, and a rescan. Next to the search box, since it
    /// applies to the whole library and not to a bank in the list.
    private var foldersMenu: some View {
        Menu {
            Button("Import Banks…", systemImage: "square.and.arrow.down.on.square") { picking = .banks }
            Divider()
            Button("Open Cartridges Folder", systemImage: "folder.badge.plus") { if let url = library.cartridgesFolderURL { openURL(url) } }
            Button(library.folderName == nil ? "Choose Folder of Banks…" : "Change Folder…", systemImage: "folder") { picking = .folder }
            Button("Rescan", systemImage: "arrow.clockwise") { library.rescan() }
            if library.folderName != nil {
                Divider()
                Button("Forget “\(library.folderName ?? "")”", systemImage: "xmark.circle", role: .destructive) { library.forgetFolder() }
            }
        } label: {
            Label("Folders", systemImage: "folder")
        }
        .menuStyle(.button).buttonStyle(.bordered)
        .controlSize(.regular)
        .fixedSize()
        .accessibilityLabel("Bank folders")
    }
}

/// The file picker for choosing a browse folder or importing banks, and the summary shown after an import.
private struct FilePicking: ViewModifier {
    @Binding var picking: LibraryPanel.PickingKind?
    @Binding var summary: String?
    var library: BankLibrary
    /// Separate from `picking`, so the kind is still known when the picker's completion runs.
    @State private var presenting = false

    func body(content: Content) -> some View {
        content
            .onChange(of: picking) { _, new in if new != nil { presenting = true } }
            .onChange(of: presenting) { _, now in
                if !now { DispatchQueue.main.async { picking = nil } }
            }
            .fileImporter(isPresented: $presenting,
                          allowedContentTypes: picking == .banks ? [.data, .folder] : [.folder],
                          allowsMultipleSelection: picking == .banks) { result in
                guard case .success(let urls) = result else { return }
                if picking == .banks {
                    Task { summary = await library.importBanks(urls).text }
                } else if let url = urls.first {
                    library.chooseFolder(url)
                }
            }
            .alert("Import Banks", isPresented: Binding(get: { summary != nil }, set: { if !$0 { summary = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(summary ?? "") }
    }
}
