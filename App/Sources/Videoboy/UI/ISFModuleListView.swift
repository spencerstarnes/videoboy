//
//  ISFModuleListView.swift — the + / − list of ISF shader modules.
//
//  Purpose : The Shaders pane's editor: every ISF module Videoboy can see, on the
//            left; what the selected one is and whether it compiles, on the right;
//            + / − beneath. The same list-and-detail shape as the Outputs and Sources
//            panes (DestinationListView, SourceListView).
//  Inputs  : the three ISF folders (ISFLibrary.standardFolders), and files the
//            operator picks with + or drops on the list.
//  Outputs : + COPIES into Videoboy's own ISF folder (ISFImporter) — so a module is
//            never lost when its original moves. − moves an imported module to the
//            Trash. Built-in and shared modules cannot be removed from here.
//  Connects: PreferencePanes (the Shaders pane), ISFLibrary, ISFImporter, ISFCompiler.
//  Extend  : a new fact about a module is one more line in `updateDetail`.
//
//  Threading: the render tick runs on the main thread, so scanning, importing and
//  compiling never do. Each runs on `work` (or ISFCompiler's queue) and hands its
//  result back to main.
//

import AppKit
import UniformTypeIdentifiers
import VideoboyCore

/// Lists ISF modules and imports them into Videoboy's library.
final class ISFModuleListView: NSView {

    let tableView = NSTableView()
    private let scrollView = NSScrollView()
    let addButton = Controls.button("+")
    let removeButton = Controls.button("−")
    private let statusLine = Controls.label("", font: Theme.Font.tinyLabel, color: Theme.Color.textTertiary)

    private let detail = FlippedView()
    private let emptyState = Controls.label("Scanning…", color: Theme.Color.textTertiary)
    private let nameLabel = Controls.label("", font: Theme.Font.panelTitle, color: Theme.Color.textPrimary)
    private let originLabel = Controls.label("")
    private let kindLabel = Controls.label("")
    private let inputsLabel = Controls.label("")
    private let creditLabel = Controls.label("")
    private let summaryNote = Controls.note("", width: 330)
    private let stateNote = Controls.note("", width: 330)
    private let pathLabel = Controls.label("", font: Theme.Font.tinyLabel, color: Theme.Color.textTertiary)
    private let copyButton = Controls.button("Copy into Videoboy")

    /// File I/O for the list — scanning and importing — off the main thread.
    private let work = DispatchQueue(label: "videoboy.isf.library", qos: .userInitiated)
    private(set) var entries: [ISFLibraryEntry] = []
    /// Compile results by file path, for this window's lifetime. `nil` = checking.
    private var compileState: [String: Result<Void, ISFCompileError>?] = [:]

    /// Folders to scan and import into. Overridable so self-QA never touches ~/Library.
    private let folders: [(URL, ISFLibraryEntry.Folder)]
    private let importFolder: URL
    /// How − disposes of a module: the Trash, except under the self-QA.
    private let trash: (URL) throws -> Void

    init(
        folders: [(URL, ISFLibraryEntry.Folder)] = ISFLibrary.standardFolders,
        importFolder: URL = ISFLibrary.userFolder,
        trash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) {
        self.folders = folders
        self.importFolder = importFolder
        self.trash = trash
        super.init(frame: .zero)
        build()
        rescan()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    // MARK: - Layout

    private func build() {
        tableView.headerView = nil
        tableView.rowHeight = 22
        tableView.backgroundColor = Theme.Color.panelFillNested
        tableView.style = .plain
        tableView.allowsMultipleSelection = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.width = 220
        tableView.addTableColumn(column)
        tableView.dataSource = self
        tableView.delegate = self
        // Dropping files or folders on the list imports them, same as +.
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.setAccessibilityIdentifier("isf-module-list")

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .lineBorder

        let add = addButton
        add.target = self
        add.action = #selector(addModules)
        add.toolTip = "Import ISF files or folders. They are copied into Videoboy."
        add.setAccessibilityIdentifier("isf-add")
        removeButton.target = self
        removeButton.action = #selector(removeModule)
        removeButton.setAccessibilityIdentifier("isf-remove")
        let reveal = Controls.button("Show Folder", target: self, action: #selector(revealFolder))
        reveal.toolTip = "Open Videoboy's ISF folder in the Finder."
        let buttons = Controls.row([add, removeButton, Controls.spacer(), reveal], spacing: 4)
        buttons.translatesAutoresizingMaskIntoConstraints = false

        statusLine.translatesAutoresizingMaskIntoConstraints = false
        statusLine.lineBreakMode = .byTruncatingTail

        copyButton.target = self
        copyButton.action = #selector(copySharedModule)
        copyButton.toolTip = "Keep a copy in Videoboy, so it stays even if the other app removes it."
        pathLabel.lineBreakMode = .byTruncatingHead

        let form = Controls.column([
            nameLabel,
            summaryNote,
            labelled("From", originLabel),
            labelled("Kind", kindLabel),
            labelled("Controls", inputsLabel),
            labelled("Credit", creditLabel),
            labelled("Status", stateNote),
            Controls.row([copyButton, Controls.spacer()], spacing: 0),
            pathLabel
        ], spacing: 7)
        form.translatesAutoresizingMaskIntoConstraints = false
        // Text in the detail TRUNCATES rather than widening the window. A long path
        // or a long list of controls pushed Preferences out to 1202 pt, and the window
        // then changed size as you changed tabs (see DestinationListView).
        //
        // 490 sits between the two things it has to beat and lose to: above a stack
        // view's hugging (250), so the text shows in full when there is room, and below
        // the window holding its size (500), so a long line truncates instead.
        for label in [nameLabel, originLabel, kindLabel, inputsLabel, creditLabel, pathLabel] {
            label.setContentCompressionResistancePriority(.init(490), for: .horizontal)
        }
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.addSubview(form)
        for row in form.arrangedSubviews {
            row.widthAnchor.constraint(lessThanOrEqualTo: form.widthAnchor).isActive = true
        }
        emptyState.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        addSubview(buttons)
        addSubview(statusLine)
        addSubview(detail)
        addSubview(emptyState)

        let listWidth: CGFloat = 230
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.widthAnchor.constraint(equalToConstant: listWidth),
            scrollView.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -6),

            buttons.leadingAnchor.constraint(equalTo: leadingAnchor),
            buttons.widthAnchor.constraint(equalToConstant: listWidth),
            buttons.bottomAnchor.constraint(equalTo: statusLine.topAnchor, constant: -4),

            statusLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusLine.bottomAnchor.constraint(equalTo: bottomAnchor),

            detail.topAnchor.constraint(equalTo: topAnchor),
            detail.leadingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: 16),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor),
            detail.bottomAnchor.constraint(equalTo: buttons.topAnchor),

            form.topAnchor.constraint(equalTo: detail.topAnchor),
            form.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: detail.trailingAnchor),

            emptyState.topAnchor.constraint(equalTo: detail.topAnchor, constant: 4),
            emptyState.leadingAnchor.constraint(equalTo: detail.leadingAnchor)
        ])
    }

    private func labelled(_ caption: String, _ control: NSView) -> NSView {
        let label = Controls.label(caption, color: Theme.Color.textTertiary)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 58).isActive = true
        return Controls.row([label, control, Controls.spacer()], spacing: 8)
    }

    // MARK: - Scanning

    /// Re-reads every ISF folder in the background, then keeps the selection on
    /// `select` (a module name) if given, or on whatever was selected before.
    func rescan(select name: String? = nil, then: (() -> Void)? = nil) {
        let keep = name ?? selectedEntry?.name
        let folders = folders
        work.async { [weak self] in
            let scanned = ISFLibrary.scan(folders)
            DispatchQueue.main.async {
                guard let self else { return }
                self.entries = scanned
                self.tableView.reloadData()
                let row = keep.flatMap { wanted in scanned.firstIndex { $0.name == wanted } }
                    ?? (scanned.isEmpty ? nil : 0)
                if let row {
                    self.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    self.tableView.scrollRowToVisible(row)
                }
                if self.statusLine.stringValue.isEmpty { self.statusLine.stringValue = self.countSummary() }
                self.updateDetail()
                then?()
            }
        }
    }

    private func countSummary() -> String {
        let imported = entries.filter { $0.folder == .user }.count
        let problems = entries.filter { $0.document == nil }.count
        var text = "\(entries.count) modules · \(imported) imported"
        if problems > 0 { text += " · \(problems) with problems" }
        return text
    }

    /// What the detail's status line says, for the self-QA.
    var statusTextForChecks: String { stateNote.stringValue }
    /// The line under the buttons (import results), for the self-QA.
    var statusLineForChecks: String { statusLine.stringValue }

    /// Selects a module by name, as a click on its row would.
    func select(name: String) {
        guard let row = entries.firstIndex(where: { $0.name == name }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    var selectedEntry: ISFLibraryEntry? {
        let row = tableView.selectedRow
        return entries.indices.contains(row) ? entries[row] : nil
    }

    // MARK: - Importing and removing

    @objc private func addModules() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        // `.fs` has no system type; a dynamic one for the extension, plus folders.
        panel.allowedContentTypes = [UTType(filenameExtension: "fs") ?? .data, .folder]
        panel.prompt = "Import"
        panel.message = "Choose ISF files (.fs) or folders of them. Videoboy keeps its own copy."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        importModules(panel.urls)
    }

    /// Copies `urls` into Videoboy's ISF folder, off the main thread.
    func importModules(_ urls: [URL], then: ((ISFImportReport) -> Void)? = nil) {
        statusLine.stringValue = "Importing…"
        let destination = importFolder
        work.async { [weak self] in
            let report = ISFImporter.importFiles(urls, into: destination)
            DispatchQueue.main.async {
                guard let self else { return }
                self.statusLine.stringValue = report.summary
                self.rescan(select: report.importedNames.first) {
                    self.explainProblems(in: report)
                    then?(report)
                }
            }
        }
    }

    /// Anything skipped or imported with missing pieces gets said out loud, once.
    private func explainProblems(in report: ISFImportReport) {
        var lines: [String] = []
        for item in report.items {
            switch item.outcome {
            case .skipped(let reason): lines.append("• \(reason)")
            case .imported(let name, let notes): lines += notes.map { "• \(name): \($0)" }
            case .alreadyImported: break
            }
        }
        guard !lines.isEmpty, let window else { return }
        let alert = NSAlert()
        alert.messageText = report.summary
        let shown = lines.prefix(12)
        alert.informativeText = shown.joined(separator: "\n")
            + (lines.count > shown.count ? "\n…and \(lines.count - shown.count) more (see the log)." : "")
        alert.beginSheetModal(for: window)
    }

    @objc private func removeModule() {
        guard let entry = selectedEntry, entry.folder == .user else { return }
        let url = entry.url
        let libraryFolder = importFolder
        let trash = trash
        work.async { [weak self] in
            let outcome = Result { try ISFImporter.remove(url, libraryFolder: libraryFolder, trash: trash) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch outcome {
                case .success:
                    self.statusLine.stringValue = "Moved \(entry.name) to the Trash."
                case .failure(let error):
                    Log.error(.isf, "could not remove '\(url.path)': \(error)")
                    self.statusLine.stringValue = "Could not remove \(entry.name): \(error)"
                }
                self.compileState[url.path] = nil
                self.rescan()
            }
        }
    }

    @objc private func copySharedModule() {
        guard let entry = selectedEntry, entry.folder == .shared else { return }
        importModules([entry.url])
    }

    @objc private func revealFolder() {
        do {
            try FileManager.default.createDirectory(at: importFolder, withIntermediateDirectories: true)
        } catch {
            Log.error(.isf, "could not create '\(importFolder.path)': \(error.localizedDescription)")
        }
        NSWorkspace.shared.activateFileViewerSelecting([importFolder])
    }

    // MARK: - Detail

    private func updateDetail() {
        guard let entry = selectedEntry else {
            detail.isHidden = true
            emptyState.isHidden = false
            emptyState.stringValue = entries.isEmpty
                ? "No ISF modules yet. Press + or drop .fs files here."
                : "Select a module."
            removeButton.isEnabled = false
            return
        }
        detail.isHidden = false
        emptyState.isHidden = true

        nameLabel.stringValue = entry.name
        originLabel.stringValue = Self.originText(entry.folder)
        pathLabel.stringValue = entry.url.path
        copyButton.isHidden = entry.folder != .shared
        removeButton.isEnabled = entry.folder == .user
        removeButton.toolTip = entry.folder == .user
            ? "Move this module to the Trash."
            : (entry.folder == .builtin
                ? "Built-in modules ship with Videoboy and cannot be removed."
                : "This module belongs to another app's folder. Remove it there.")

        guard let document = entry.document else {
            summaryNote.stringValue = ""
            kindLabel.stringValue = "—"
            inputsLabel.stringValue = "—"
            creditLabel.stringValue = "—"
            if case .failure(let error) = entry.result { showProblem(error.description) }
            return
        }
        summaryNote.stringValue = document.summary
        let categories = document.categories.isEmpty ? "" : " · " + document.categories.joined(separator: ", ")
        kindLabel.stringValue = document.kind.rawValue.capitalized + categories
        let names = document.valueInputs.map { $0.label.isEmpty ? $0.name : $0.label }
        inputsLabel.stringValue = names.isEmpty ? "none" : names.joined(separator: ", ")
        inputsLabel.toolTip = inputsLabel.stringValue
        creditLabel.stringValue = document.credit.isEmpty ? "—" : document.credit

        if let known = compileState[entry.url.path] {
            showCompileState(known)
        } else {
            checkCompiles(entry)
        }
    }

    /// Compiles the module in the background to prove it will run — the question the
    /// operator is really asking after an import.
    private func checkCompiles(_ entry: ISFLibraryEntry) {
        guard let source = entry.source, let device = MetalContext.shared?.device else {
            showProblem("cannot check: no Metal device")
            return
        }
        let path = entry.url.path
        compileState[path] = .some(nil)
        showCompileState(nil)
        ISFCompiler.shared.compile(
            source: source, vertexSource: entry.vertexSource, name: entry.name, device: device
        ) { [weak self] result in
            guard let self else { return }
            let state: Result<Void, ISFCompileError> = result.map { _ in () }
            self.compileState[path] = .some(state)
            if self.selectedEntry?.url.path == path { self.showCompileState(state) }
        }
    }

    private func showCompileState(_ state: Result<Void, ISFCompileError>??) {
        switch state {
        case .some(.some(.success)):
            stateNote.stringValue = "Ready — converts and compiles for Metal."
            stateNote.textColor = Theme.Color.moduleReady
        case .some(.some(.failure(let error))):
            showProblem(error.description)
        default:
            stateNote.stringValue = "Checking…"
            stateNote.textColor = Theme.Color.textTertiary
        }
    }

    private func showProblem(_ text: String) {
        stateNote.stringValue = "⚠ " + text
        stateNote.textColor = Theme.Color.moduleProblem
    }

    static func originText(_ folder: ISFLibraryEntry.Folder) -> String {
        switch folder {
        case .builtin: "Built-in"
        case .user: "Imported — kept in Videoboy"
        case .shared: "Shared ISF folder (another app's)"
        }
    }

    static func badge(_ folder: ISFLibraryEntry.Folder) -> String {
        switch folder {
        case .builtin: "built-in"
        case .user: "imported"
        case .shared: "shared"
        }
    }
}

extension ISFModuleListView: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let entry = entries[row]
        let broken = entry.document == nil
        let name = Controls.label(
            (broken ? "⚠ " : "") + entry.name,
            color: broken ? Theme.Color.moduleProblem : Theme.Color.textSecondary)
        let badge = Controls.label(
            Self.badge(entry.folder), font: Theme.Font.tinyLabel,
            color: Theme.Color.textTertiary, holdsWidth: true)
        return Controls.row([name, Controls.spacer(), badge], spacing: 6)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateDetail()
    }

    func tableView(
        _ tableView: NSTableView, validateDrop info: NSDraggingInfo,
        proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        tableView.setDropRow(-1, dropOperation: .on)   // the whole list, not a row
        return droppedURLs(info).isEmpty ? [] : .copy
    }

    func tableView(
        _ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
        row: Int, dropOperation: NSTableView.DropOperation
    ) -> Bool {
        let urls = droppedURLs(info)
        guard !urls.isEmpty else { return false }
        importModules(urls)
        return true
    }

    /// Dropped `.fs` files and folders; anything else is not offered as a drop.
    private func droppedURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { $0.hasDirectoryPath || $0.pathExtension.lowercased() == "fs" }
    }
}
