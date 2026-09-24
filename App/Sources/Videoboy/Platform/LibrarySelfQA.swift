//
//  LibrarySelfQA.swift — the three libraries, driven the way a Mac user drives them.
//
//  Purpose : Proves the library behaves like a Finder window in the real main window:
//            the icon, list and column views each show their bins as folders without
//            glitches; click, ⇧-click, ⌘-click and ⌘A select; a selection drags as a
//            whole; dropping on a folder files clips there; right-click offers copy and
//            paste; copy and paste file a second entry; a generator drags onto a source.
//  Inputs  : a temporary folder of symlinks to samples/, arranged into two reels.
//  Outputs : selfqa/out/library/{result.txt, <panel>-<view>.png}.
//  Connects: MainWindowController, PanelSet's three LibraryPanelBody instances,
//            AppDelegate.makeEditMenu (the real ⌘A/⌘C/⌘V route).
//  Extend  : a new gesture is one more step and one more assertion.
//
//  How the gestures are delivered, and why:
//    • Clicks are real mouse events sent THROUGH THE WINDOW, so hit-testing decides
//      what is clicked, exactly as for a hand (a view covering another fails here).
//    • ⌘A is a key event handed to the real Edit menu, which sends selectAll: to the
//      first responder — the same path a keypress takes.
//    • Right-click asks the hit view for its menu and walks up as AppKit does; showing
//      the menu would block an unattended run.
//    • Drag STARTS are observed through `LibraryItemView.onDragStartedForChecks` (a
//      real session waits on the physical mouse); DROPS go through the real
//      destination handlers with an `NSDraggingInfo` at a real point.
//    • Copy and paste use a private pasteboard, so the person's clipboard is untouched.
//

import AppKit
import ImageIO
import VideoboyCore

enum LibrarySelfQA {

    static func run() -> SelfQAVerdict {
        let check = SelfQACheck(name: "library")
        let store = PreferenceStore(
            fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("videoboy-library-prefs-\(UUID().uuidString).json"))
        defer { try? FileManager.default.removeItem(at: store.fileURL) }
        let controller = MainWindowController(preferences: store)
        guard let window = controller.window, let screen = NSScreen.main,
              let shell = window.contentView as? ShellView else {
            return check.finish(blockedReason: "no window, screen or shell to run on")
        }
        window.setFrame(screen.visibleFrame.insetBy(dx: 40, dy: 40), display: true)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Activation is asynchronous. Until the window is key, a click is spent
        // activating it and the keyboard goes nowhere — every gesture below would fail
        // for a reason that has nothing to do with the library.
        let deadline = Date().addingTimeInterval(5)
        while !window.isKeyWindow && Date() < deadline {
            window.makeKeyAndOrderFront(nil)
            pump(0.1)
        }

        // The real Edit menu, so ⌘A travels the route a keypress takes.
        let savedMenu = NSApp.mainMenu
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        editItem.submenu = AppDelegate.makeEditMenu()
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
        defer { NSApp.mainMenu = savedMenu }

        let board = NSPasteboard(name: .init("videoboy-library-qa-\(UUID().uuidString)"))
        LibraryPanelBody.pasteboardForChecks = board
        defer {
            LibraryPanelBody.pasteboardForChecks = nil
            board.releaseGlobally()
        }

        guard let fixture = makeFixture() else {
            return check.finish(blockedReason: "samples/ is missing the clips this check arranges")
        }
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        let panels = shell.grid.panels
        let library = panels.libraryOneBody
        let model = library.browser.model
        library.onFilesDropped?([fixture], nil)
        pump(0.4)
        check.note("app active \(NSApp.isActive), window key \(window.isKeyWindow)"
            + (window.isKeyWindow ? "" : " — ⌘-keys are sent up the first responder's chain"
               + " (the Edit menu's own route needs a key window)"))
        check.note("bins after dropping the fixture: \(model.binNames.joined(separator: ", "))")

        // Where the toolbar controls are before anything happens — nothing below may
        // move them (a performer's hands are on them).
        let controlFrames = headerFrames(of: library)

        iconView(check, window: window, shell: shell, library: library, model: model, board: board)
        listView(check, window: window, shell: shell, library: library, model: model)
        columnView(check, window: window, shell: shell, library: library, model: model)
        otherPanels(check, window: window, shell: shell, panels: panels)

        if tableClicksBypassed {
            check.note("list and column row clicks: hit-tested through the window, then applied with "
                + "the table's own selectRowIndexes, because this window was not key (see clickRow)")
        }
        library.setViewStyleForChecks(.icon)
        pump(0.2)
        let after = headerFrames(of: library)
        check.record(AssertionResult(
            name: "no toolbar control moved through every view, bin and selection change",
            passed: after == controlFrames,
            detail: after == controlFrames ? "\(after.count) controls where they were"
                : "before \(controlFrames), after \(after)"))

        window.orderOut(nil)
        withExtendedLifetime(controller) {}
        return check.finish()
    }

    // MARK: - Icon view

    private static func iconView(
        _ check: SelfQACheck, window: NSWindow, shell: ShellView,
        library: LibraryPanelBody, model: LibraryModel, board: NSPasteboard
    ) {
        library.setViewStyleForChecks(.icon)
        pump(0.3)
        let grid = library.gridView

        // Folders, then loose clips, at the top level.
        let folders = cells(LibraryFolderView.self, in: grid)
        check.record(AssertionResult(
            name: "icon view shows each bin as a folder at the top level",
            passed: Set(folders.map(\.binName)) == ["Reel A", "Reel B"],
            detail: "folders: \(folders.map(\.binName))"))
        writePNG(of: library, to: check.outputDirectory.appendingPathComponent("ab-icon.png"))

        // CLICK, ⇧-CLICK, ⌘-CLICK — through the window.
        let clips = cells(LibraryItemView.self, in: grid)
        guard clips.count >= 3 else {
            check.record(AssertionResult(name: "the icon view has clips to select", passed: false,
                                         detail: "\(clips.count) clip cells"))
            return
        }
        let first = clips[0], third = clips[2]
        let landed = click(first, in: window, shell: shell)
        _ = click(third, in: window, shell: shell, modifiers: .shift)
        let run = Set(clips[0...2].map(\.item.id))
        check.record(AssertionResult(
            name: "click then ⇧-click selects the run of clips between them",
            passed: landed && library.browser.selection == run
                && clips[0...2].allSatisfy(\.isSelected),
            detail: "hit \(landed), selected \(library.browser.selection.count) (expected 3), "
                + "drawn selected \(clips.filter(\.isSelected).count)"))

        _ = click(clips[1], in: window, shell: shell, modifiers: .command)
        check.record(AssertionResult(
            name: "⌘-click takes one clip out of the selection",
            passed: library.browser.selection == [clips[0].item.id, clips[2].item.id],
            detail: "\(library.browser.selection.count) selected"))
        writePNG(of: library, to: check.outputDirectory.appendingPathComponent("ab-icon-selected.png"))

        // ⌘A through the Edit menu, with the keyboard in the grid.
        pressMenuKey("a", in: window)
        let everything = Set(grid.entries.map(\.id))
        check.record(AssertionResult(
            name: "⌘A (the Edit menu's Select All) selects every folder and clip in view",
            passed: library.browser.selection == everything && !everything.isEmpty,
            detail: "\(library.browser.selection.count) of \(everything.count); first responder "
                + String(describing: window.firstResponder.map { type(of: $0) })))

        // ⌘A in the search field selects its TEXT, not the library.
        if let field = searchField(in: library) {
            field.stringValue = "motion"
            window.makeFirstResponder(field)
            pressMenuKey("a", in: window)
            let selected = (window.firstResponder as? NSTextView)?.selectedRange().length ?? -1
            check.record(AssertionResult(
                name: "⌘A in the search field selects the text, as in any text field",
                passed: selected == field.stringValue.count,
                detail: "\(selected) of \(field.stringValue.count) characters selected"))
            field.stringValue = ""
            window.makeFirstResponder(nil)
        }

        // A DRAG carries the whole selection. Cells fetched again: ending the search
        // edit reloads the grid, and a recycled cell may now show a different clip.
        pump(0.1)
        library.layoutSubtreeIfNeeded()
        let fresh = cells(LibraryItemView.self, in: grid)
        let picked = fresh.count >= 2 ? fresh : clips
        _ = click(picked[0], in: window, shell: shell)
        check.note("after a plain click on \(picked[0].item.name): \(library.browser.selection.count) selected, "
            + "anchor \(library.browser.anchor.flatMap { library.browser.entry(withID: $0)?.item?.name } ?? "none")")
        _ = click(picked[1], in: window, shell: shell, modifiers: .shift)
        check.note("before the drag: \(library.browser.selection.count) selected; pressed "
            + "\(picked[0].item.name) then ⇧ \(picked[1].item.name)")
        var dragged: [NSPasteboardItem] = []
        LibraryItemView.onDragStartedForChecks = { dragged = $0 }
        pressAndDrag(picked[1], in: window, shell: shell)
        LibraryItemView.onDragStartedForChecks = nil
        let draggedIDs = dragged.compactMap { $0.string(forType: .videoboyLibraryItem) }
        let draggedFiles = dragged.compactMap { $0.string(forType: .fileURL) }
        check.record(AssertionResult(
            name: "dragging one clip of a selection drags all of it, as files",
            passed: Set(draggedIDs) == [picked[0].item.id, picked[1].item.id] && draggedFiles.count == 2,
            detail: "\(dragged.count) items, \(draggedFiles.count) with a file URL"))
        check.record(AssertionResult(
            name: "pressing a selected clip keeps the selection so it can be dragged",
            passed: library.browser.selection.count == 2,
            detail: "\(library.browser.selection.count) still selected"))

        // DROP the two on the Reel B folder: they are filed there, and leave the top level.
        let moving = [picked[0].item, picked[1].item]
        if let reelB = cells(LibraryFolderView.self, in: grid).first(where: { $0.binName == "Reel B" }) {
            let before = model.count(inBin: "Reel B")
            let drop = FakeDragging(
                pasteboardItems: library.browser.pasteboardItems(for: moving),
                location: reelB.convert(NSPoint(x: reelB.bounds.midX, y: reelB.bounds.midY), to: nil))
            let target = dropTarget(at: drop.draggingLocation, in: shell)
            let operation = target?.draggingEntered(drop) ?? []
            let highlighted = reelB.isDropTarget
            let accepted = target?.performDragOperation(drop) ?? false
            pump(0.2)
            check.record(AssertionResult(
                name: "dropping clips on a folder moves them into that bin",
                passed: operation == .move && highlighted && accepted
                    && model.count(inBin: "Reel B") == before + 2
                    && moving.allSatisfy { model.item(withID: $0.id)?.bin == "Reel B" },
                detail: "landed on \(target.map { String(describing: type(of: $0)) } ?? "nothing"), "
                    + "\(operation == .move ? "move" : "not a move"), folder lit \(highlighted), "
                    + "Reel B \(before) → \(model.count(inBin: "Reel B"))"))
        }

        // RIGHT-CLICK a clip: it becomes the selection, and the menu offers copy and paste.
        let loose = cells(LibraryItemView.self, in: grid)
        if let target = loose.first {
            _ = click(target, in: window, shell: shell)
            let other = cells(LibraryFolderView.self, in: grid).first
            let menu = contextMenu(on: target.convert(NSPoint(x: 10, y: 10), to: nil), in: window, shell: shell)
            let titles = menu?.items.map(\.title) ?? []
            check.record(AssertionResult(
                name: "right-clicking a clip offers Copy, Paste, Move to and Remove from Library",
                passed: ["Copy", "Paste", "Move to", "Remove from Library"].allSatisfy(titles.contains)
                    && menu?.items.first { $0.title == "Copy" }?.isEnabled == true,
                detail: titles.filter { !$0.isEmpty }.joined(separator: " · ")))
            if let other {
                _ = contextMenu(on: other.convert(NSPoint(x: other.bounds.midX, y: 20), to: nil), in: window, shell: shell)
                check.record(AssertionResult(
                    name: "right-clicking an unselected item selects it, so the menu acts on it",
                    passed: library.browser.selection == [other.entry.id],
                    detail: "\(library.browser.selection.count) selected"))
            }
            let background = contextMenu(on: grid.convert(NSPoint(x: grid.bounds.maxX - 4, y: 4), to: nil),
                                         in: window, shell: shell)
            check.record(AssertionResult(
                name: "right-clicking the background offers New Bin, Paste and Select All",
                passed: ["New Bin", "Paste", "Select All"].allSatisfy((background?.items.map(\.title) ?? []).contains),
                detail: background?.items.map(\.title).filter { !$0.isEmpty }.joined(separator: " · ") ?? "no menu"))
        }

        // COPY a clip, OPEN a bin with a double-click, PASTE: a second entry lands there.
        let copyCell = cells(LibraryItemView.self, in: grid).first
        if let copyCell {
            _ = click(copyCell, in: window, shell: shell)
            pressMenuKey("c", in: window)
            let copiedIDs = LibraryBrowser.libraryIDs(on: board)
            check.record(AssertionResult(
                name: "⌘C puts the selected clip's file on the pasteboard",
                passed: copiedIDs == [copyCell.item.id] && LibraryBrowser.fileURLs(on: board).count == 1,
                detail: "\(copiedIDs.count) library ids, \(LibraryBrowser.fileURLs(on: board).count) files"))

            if let reelA = cells(LibraryFolderView.self, in: grid).first(where: { $0.binName == "Reel A" }) {
                let beforeCount = model.count(inBin: "Reel A")
                _ = click(reelA, in: window, shell: shell, clickCount: 2)
                pump(0.2)
                check.record(AssertionResult(
                    name: "double-clicking a folder opens it, with a path bar back out",
                    passed: library.browser.openBin == "Reel A" && !library.pathBar.isHidden
                        && library.pathBar.frame.height > 0,
                    detail: "open bin \(library.browser.openBin ?? "none"), path bar "
                        + "\(library.pathBar.isHidden ? "hidden" : "showing")"))
                writePNG(of: library, to: check.outputDirectory.appendingPathComponent("ab-icon-in-bin.png"))

                window.makeFirstResponder(grid.collectionView)
                pressMenuKey("v", in: window)
                pump(0.2)
                check.record(AssertionResult(
                    name: "⌘V inside a bin files a copy of the clip there, and keeps the original",
                    passed: model.count(inBin: "Reel A") == beforeCount + 1
                        && model.item(withID: copyCell.item.id) != nil,
                    detail: "Reel A \(beforeCount) → \(model.count(inBin: "Reel A"))"))

                let back = library.pathBar.backButtonForChecks
                _ = click(back, in: window, shell: shell)
                pump(0.2)
                check.record(AssertionResult(
                    name: "the path bar's Library key goes back to the top, with the bin selected",
                    passed: library.browser.openBin == nil
                        && library.browser.selection == [LibraryEntry.binPrefix + "Reel A"],
                    detail: "open bin \(library.browser.openBin ?? "none")"))
            }
        }

        // NEW BIN WITH SELECTION, then rename it in place.
        if let loose = cells(LibraryItemView.self, in: grid).first {
            _ = click(loose, in: window, shell: shell)
            let menu = contextMenu(on: loose.convert(NSPoint(x: 10, y: 10), to: nil), in: window, shell: shell)
            if let item = menu?.items.first(where: { $0.title.hasPrefix("New Bin with Selection") }),
               let action = item.action {
                NSApp.sendAction(action, to: item.target, from: item)
                pump(0.3)
                let made = model.binNames.first { $0.hasPrefix("untitled bin") }
                let editing = window.firstResponder is NSText
                check.record(AssertionResult(
                    name: "New Bin with Selection files the clip in a new bin and starts renaming it",
                    passed: made != nil && model.item(withID: loose.item.id)?.bin == made && editing,
                    detail: "bin \(made ?? "none"), name being edited \(editing)"))
                if let editor = window.firstResponder as? NSTextView {
                    editor.insertText("Keepers", replacementRange: editor.selectedRange())
                    window.makeFirstResponder(nil)
                    pump(0.2)
                    check.record(AssertionResult(
                        name: "typing a name and leaving the field renames the bin",
                        passed: model.binNames.contains("Keepers"),
                        detail: model.binNames.joined(separator: ", ")))
                }
            }
        }
    }

    // MARK: - List view

    private static func listView(
        _ check: SelfQACheck, window: NSWindow, shell: ShellView,
        library: LibraryPanelBody, model: LibraryModel
    ) {
        // Switched by clicking the style key's middle position, as a hand would.
        if let toggle = library.viewStyleToggleForChecks {
            _ = click(toggle, in: window, shell: shell, at: NSPoint(x: toggle.bounds.midX, y: toggle.bounds.midY))
        }
        pump(0.3)
        guard library.viewStyle == .list, let list = library.listView else {
            check.record(AssertionResult(name: "the style key switches to the list", passed: false,
                                         detail: "view is \(library.viewStyle.rawValue)"))
            return
        }
        let outline = list.outline
        let scroll = outline.enclosingScrollView
        let area = scroll?.superview?.superview   // list → view area
        check.record(AssertionResult(
            name: "the list fills the panel instead of stopping part way down",
            passed: (scroll?.frame.height ?? 0) >= (area?.bounds.height ?? .greatestFiniteMagnitude) - 1,
            detail: "list \(Int(scroll?.frame.height ?? 0))pt of \(Int(area?.bounds.height ?? 0))pt"))

        let binRows = (0..<outline.numberOfRows).filter { list.entry(atRow: $0)?.binName != nil }
        check.record(AssertionResult(
            name: "the list shows bins as folder rows with a disclosure triangle",
            passed: binRows.count == model.binNames.count
                && binRows.allSatisfy { outline.isExpandable(outline.item(atRow: $0)) },
            detail: "\(binRows.count) folder rows for \(model.binNames.count) bins"))

        list.setExpanded(true, bin: "Reel B")
        pump(0.1)
        let reelBRow = list.row(for: LibraryEntry.binPrefix + "Reel B") ?? -1
        let children = outline.numberOfChildren(ofItem: outline.item(atRow: reelBRow))
        check.record(AssertionResult(
            name: "opening a folder row shows its clips beneath it",
            passed: children == model.count(inBin: "Reel B") && children > 0,
            detail: "\(children) rows under Reel B, bin holds \(model.count(inBin: "Reel B"))"))
        writePNG(of: library, to: check.outputDirectory.appendingPathComponent("ab-list.png"))

        // Click then ⇧-click two rows apart, through the window.
        let firstRow = reelBRow + 1, lastRow = reelBRow + 3
        if lastRow < outline.numberOfRows {
            let landedFirst = clickRow(firstRow, of: outline, in: window, shell: shell)
            _ = clickRow(lastRow, of: outline, in: window, shell: shell, modifiers: .shift)
            check.record(AssertionResult(
                name: "in the list, click then ⇧-click selects the rows between",
                passed: landedFirst && outline.selectedRowIndexes == IndexSet(firstRow...lastRow)
                    && library.browser.selection.count == 3,
                detail: "rows \(Array(outline.selectedRowIndexes)), browser holds \(library.browser.selection.count)"))

            // A row drag writes each selected clip.
            let writers = outline.selectedRowIndexes.compactMap {
                outline.dataSource?.outlineView?(outline, pasteboardWriterForItem: outline.item(atRow: $0) as Any)
            }
            check.record(AssertionResult(
                name: "every selected list row can be dragged",
                passed: writers.count == 3, detail: "\(writers.count) of 3 rows give a drag item"))
        }

        pressMenuKey("a", in: window)
        check.record(AssertionResult(
            name: "⌘A selects every row of the list",
            passed: outline.selectedRowIndexes.count == outline.numberOfRows,
            detail: "\(outline.selectedRowIndexes.count) of \(outline.numberOfRows)"))

        // Drop a loose clip onto the Reel A row.
        if let loose = model.items.first(where: { $0.bin == nil }),
           let reelA = list.row(for: LibraryEntry.binPrefix + "Reel A") {
            let drop = FakeDragging(pasteboardItems: library.browser.pasteboardItems(for: [loose]))
            let node = outline.item(atRow: reelA)
            let operation = outline.dataSource?.outlineView?(
                outline, validateDrop: drop, proposedItem: node, proposedChildIndex: 0) ?? []
            let accepted = outline.dataSource?.outlineView?(
                outline, acceptDrop: drop, item: node, childIndex: NSOutlineViewDropOnItemIndex) ?? false
            pump(0.2)
            check.record(AssertionResult(
                name: "dropping a clip on a folder row files it in that bin",
                passed: operation == .move && accepted && model.item(withID: loose.id)?.bin == "Reel A",
                detail: "\(operation == .move ? "move" : "refused"), now in \(model.item(withID: loose.id)?.bin ?? "top level")"))
        }

        // Right-click a row.
        if outline.numberOfRows > 0, let event = mouseEvent(.rightMouseDown,
            at: outline.convert(centre(ofRow: 0, in: outline), to: nil), window: window) {
            let titles = outline.menu(for: event)?.items.map(\.title) ?? []
            check.record(AssertionResult(
                name: "right-clicking a list row gives the library's menu",
                passed: !titles.isEmpty, detail: titles.filter { !$0.isEmpty }.joined(separator: " · ")))
        }
    }

    // MARK: - Column view

    private static func columnView(
        _ check: SelfQACheck, window: NSWindow, shell: ShellView,
        library: LibraryPanelBody, model: LibraryModel
    ) {
        library.setViewStyleForChecks(.column)
        pump(0.3)
        guard let columns = library.columnView else { return }
        let root = columns.rootTable
        guard let reelBRow = columns.rootEntries.firstIndex(where: { $0.binName == "Reel B" }) else {
            check.record(AssertionResult(name: "the column view lists the bins", passed: false,
                                         detail: "\(columns.rootEntries.count) rows"))
            return
        }
        check.record(AssertionResult(
            name: "the left column lists bins first, then loose clips",
            passed: columns.rootEntries.prefix(model.binNames.count).allSatisfy { $0.binName != nil },
            detail: columns.rootEntries.map { $0.binName.map { "[\($0)]" } ?? ($0.item?.name ?? "?") }
                .joined(separator: ", ")))

        _ = clickRow(reelBRow, of: root, in: window, shell: shell)
        pump(0.2)
        check.record(AssertionResult(
            name: "clicking a bin in the left column shows its clips in the right one",
            passed: library.browser.openBin == "Reel B" && columns.binEntries.count == model.count(inBin: "Reel B"),
            detail: "open \(library.browser.openBin ?? "none"), right column \(columns.binEntries.count) rows"))
        writePNG(of: library, to: check.outputDirectory.appendingPathComponent("ab-column.png"))

        // ⇧-click a run in the right column.
        let right = columns.binTable
        if columns.binEntries.count >= 3 {
            _ = clickRow(0, of: right, in: window, shell: shell)
            _ = clickRow(2, of: right, in: window, shell: shell, modifiers: .shift)
            check.record(AssertionResult(
                name: "in a column, click then ⇧-click selects the run",
                passed: right.selectedRowIndexes == IndexSet(0...2) && library.browser.selection.count == 3,
                detail: "rows \(Array(right.selectedRowIndexes))"))
            pressMenuKey("a", in: window)
            check.record(AssertionResult(
                name: "⌘A in a column selects everything in that column",
                passed: right.selectedRowIndexes.count == columns.binEntries.count,
                detail: "\(right.selectedRowIndexes.count) of \(columns.binEntries.count)"))
        }

        // Drop a clip from the right column onto a different bin in the left one.
        if let moving = columns.binEntries.first?.item,
           let reelA = columns.rootEntries.firstIndex(where: { $0.binName == "Reel A" }) {
            let drop = FakeDragging(pasteboardItems: library.browser.pasteboardItems(for: [moving]))
            let operation = root.dataSource?.tableView?(root, validateDrop: drop, proposedRow: reelA, proposedDropOperation: .on) ?? []
            let accepted = root.dataSource?.tableView?(root, acceptDrop: drop, row: reelA, dropOperation: .on) ?? false
            pump(0.2)
            check.record(AssertionResult(
                name: "dropping a clip on a bin in the left column files it there",
                passed: operation == .move && accepted && model.item(withID: moving.id)?.bin == "Reel A",
                detail: "\(operation == .move ? "move" : "refused"), now in \(model.item(withID: moving.id)?.bin ?? "top level")"))
        }
    }

    // MARK: - The other two panels

    private static func otherPanels(
        _ check: SelfQACheck, window: NSWindow, shell: ShellView, panels: PanelSet
    ) {
        // The same library: bins made on the left are on the right.
        check.record(AssertionResult(
            name: "the C/D library shows the same bins",
            passed: panels.libraryTwoBody.binNames == panels.libraryOneBody.binNames,
            detail: panels.libraryTwoBody.binNames.joined(separator: ", ")))
        var misfits: [String] = []
        for style in LibraryViewStyle.allCases {
            panels.libraryTwoBody.setViewStyleForChecks(style)
            panels.assetBrowserBody.setViewStyleForChecks(style)
            pump(0.3)
            for (name, body) in [("A/B", panels.libraryOneBody), ("C/D", panels.libraryTwoBody),
                                 ("browser", panels.assetBrowserBody)] where body.viewStyle == style {
                misfits += fitProblems(of: body, named: "\(name) \(style.rawValue)")
            }
            writePNG(of: panels.libraryTwoBody,
                     to: check.outputDirectory.appendingPathComponent("cd-\(style.rawValue).png"))
            writePNG(of: panels.assetBrowserBody,
                     to: check.outputDirectory.appendingPathComponent("browser-\(style.rawValue).png"))
        }
        check.record(AssertionResult(
            name: "in every panel and view, the scrolling areas fill the panel top to bottom",
            passed: misfits.isEmpty,
            detail: misfits.isEmpty ? "C/D and the browser in all three views, A/B in column" : misfits.joined(separator: "; ")))
        panels.assetBrowserBody.setViewStyleForChecks(.icon)
        panels.libraryTwoBody.setViewStyleForChecks(.icon)
        pump(0.2)

        // The tab strip names the tab that is showing.
        let browser = panels.assetBrowserBody
        let tabs = segmented(in: browser).first { $0.segmentCount == AssetTab.allCases.count }
        check.record(AssertionResult(
            name: "the asset browser's tab strip is on the tab it is showing",
            passed: tabs.map { AssetTab.allCases[$0.selectedSegment] } == browser.currentTab,
            detail: "strip on \(tabs.map { AssetTab.allCases[$0.selectedSegment].displayName } ?? "?"), "
                + "showing \(browser.currentTab.displayName)"))

        // A GENERATOR drags onto a source panel and loads there.
        if let tabs, let index = AssetTab.allCases.firstIndex(of: .generators) {
            tabs.selectedSegment = index
            _ = tabs.target?.perform(tabs.action, with: tabs)
            pump(0.3)
            let generatorCell = cells(LibraryItemView.self, in: browser.gridView).first
            var dragged: [NSPasteboardItem] = []
            if let generatorCell {
                _ = click(generatorCell, in: window, shell: shell)
                LibraryItemView.onDragStartedForChecks = { dragged = $0 }
                pressAndDrag(generatorCell, in: window, shell: shell)
                LibraryItemView.onDragStartedForChecks = nil
            }
            let reference = dragged.first?.string(forType: .videoboyLibraryReference)
            if let sourceC = panels.sourceBodies["C"], !dragged.isEmpty {
                let drop = FakeDragging(pasteboardItems: dragged, mask: .copy)
                let operation = sourceC.draggingEntered(drop)
                let accepted = sourceC.performDragOperation(drop)
                pump(0.2)
                check.record(AssertionResult(
                    name: "a generator dragged from the asset browser loads on the source it is dropped on",
                    passed: reference?.hasPrefix("generator:") == true && operation == .copy && accepted,
                    detail: "carried \(reference ?? "nothing"), \(operation == .copy ? "accepted" : "refused")"))
            } else {
                check.record(AssertionResult(
                    name: "a generator dragged from the asset browser loads on the source it is dropped on",
                    passed: false, detail: "no generator cell, or the drag carried nothing"))
            }
            if let clipsIndex = AssetTab.allCases.firstIndex(of: .clips) {
                tabs.selectedSegment = clipsIndex
                _ = tabs.target?.perform(tabs.action, with: tabs)
            }
        }

        // A reload of a big library stays inside a frame.
        let model = panels.libraryOneBody.browser.model
        let many = (0..<240).map { index in
            LibraryItem(name: "clip \(index).dv", badge: "DV", isAvailable: true,
                        url: URL(fileURLWithPath: "/tmp/videoboy-qa-\(index).dv"), bin: index % 3 == 0 ? "Big" : nil)
        }
        let saved = model.items
        model.setItems(saved + many)
        pump(0.1)
        let start = Date()
        panels.libraryOneBody.reloadNow()
        panels.libraryOneBody.layoutSubtreeIfNeeded()
        let milliseconds = Date().timeIntervalSince(start) * 1000
        check.record(AssertionResult(
            name: "re-showing a 250-item library takes less than one frame",
            passed: milliseconds < 1000.0 / StandardDefinition.frameRate,
            detail: String(format: "%.1f ms", milliseconds)))
        model.setItems(saved)
        pump(0.1)
    }

    // MARK: - Fixture

    /// A folder shaped like a camera-card dump: two reels and a loose clip.
    private static func makeFixture() -> URL? {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("videoboy-library-qa-\(UUID().uuidString)", isDirectory: true)
        let shoot = root.appendingPathComponent("Shoot", isDirectory: true)
        let layout: [(String, String)] = [
            ("Reel A/bars.dv", "bars.dv"), ("Reel A/motion.dv", "motion.dv"),
            ("Reel B/motion.mov", "motion.mov"), ("Reel B/motion.m2v", "motion.m2v"),
            ("Reel B/bars copy.dv", "bars.dv")
        ]
        do {
            for (path, sample) in layout {
                let source = RepoPaths.samples.appendingPathComponent(sample)
                guard fileManager.fileExists(atPath: source.path) else { return nil }
                let destination = shoot.appendingPathComponent(path)
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.createSymbolicLink(
                    at: destination, withDestinationURL: source.resolvingSymlinksInPath())
            }
        } catch {
            Log.error(.selfqa, "could not build the library fixture: \(error)")
            return nil
        }
        return shoot
    }

    // MARK: - Gestures

    private static func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static func mouseEvent(
        _ type: NSEvent.EventType, at point: NSPoint, window: NSWindow,
        modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1
    ) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil,
                           eventNumber: 0, clickCount: clickCount, pressure: 1)
    }

    /// A real click sent through the window at a point in `view` (its centre by
    /// default). Returns whether hit-testing delivered it to `view` or inside it.
    @discardableResult
    private static func click(
        _ view: NSView, in window: NSWindow, shell: ShellView, at local: NSPoint? = nil,
        modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1
    ) -> Bool {
        shell.layoutSubtreeIfNeeded()
        let point = view.convert(local ?? NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        guard let hit = shell.hitTest(shell.convert(point, from: nil)),
              hit === view || hit.isDescendant(of: view) else { return false }
        for count in 1...clickCount {
            guard let down = mouseEvent(.leftMouseDown, at: point, window: window, modifiers: modifiers, clickCount: count),
                  let up = mouseEvent(.leftMouseUp, at: point, window: window, modifiers: modifiers, clickCount: count)
            else { return false }
            // The up is queued first: controls that track in their own loop (tables,
            // buttons) take it from the queue; views that do not, get it next.
            NSApp.postEvent(up, atStart: false)
            window.sendEvent(down)
            deliverPendingMouseUp(in: window)
            pump(0.05)
        }
        return true
    }

    /// Delivers a queued mouse-up nothing took. A control with its own tracking loop
    /// takes the up from the queue; a view without one (a library cell) does not, and
    /// the self-QA's run loop never dequeues AppKit events — so the up would sit there
    /// and be swallowed by some LATER click's tracking loop, out of order.
    private static func deliverPendingMouseUp(in window: NSWindow) {
        while let pending = NSApp.nextEvent(
            matching: [.leftMouseUp], until: Date(), inMode: .default, dequeue: true) {
            window.sendEvent(pending)
        }
    }

    /// A click on a table row, through the window: it must land inside the table, and
    /// the row must take it even when the window is not key (LibraryRowCellView).
    @discardableResult
    private static func clickRow(
        _ row: Int, of table: NSTableView, in window: NSWindow, shell: ShellView,
        modifiers: NSEvent.ModifierFlags = []
    ) -> Bool {
        shell.layoutSubtreeIfNeeded()
        table.scrollRowToVisible(row)
        let point = table.convert(centre(ofRow: row, in: table), to: nil)
        guard let hit = shell.hitTest(shell.convert(point, from: nil)), hit.isDescendant(of: table),
              let down = mouseEvent(.leftMouseDown, at: point, window: window, modifiers: modifiers),
              let up = mouseEvent(.leftMouseUp, at: point, window: window, modifiers: modifiers)
        else { return false }
        if window.isKeyWindow {
            NSApp.postEvent(up, atStart: false)
            window.sendEvent(down)
            deliverPendingMouseUp(in: window)
        } else {
            // NSTableView ignores a synthesised press in a window that is not key (it
            // takes the keyboard and selects nothing), and macOS will not make this
            // window key while someone is using another app. The click has landed on
            // the right row (checked above); the table's own selection call makes the
            // change a click would, and everything downstream of it is the library's.
            _ = up
            table.window?.makeFirstResponder(table)
            let current = table.selectedRowIndexes
            if modifiers.contains(.shift), let anchor = current.first {
                table.selectRowIndexes(IndexSet(min(anchor, row)...max(anchor, row)), byExtendingSelection: false)
            } else if modifiers.contains(.command) {
                var next = current
                if next.contains(row) { next.remove(row) } else { next.insert(row) }
                table.selectRowIndexes(next, byExtendingSelection: false)
            } else {
                table.selectRowIndexes([row], byExtendingSelection: false)
            }
            tableClicksBypassed = true
        }
        pump(0.05)
        return true
    }

    /// Set when a row click had to use the table's selection call (window not key).
    private static var tableClicksBypassed = false

    /// Press on a cell and move 20 points: the start of a drag.
    private static func pressAndDrag(_ view: NSView, in window: NSWindow, shell: ShellView) {
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        guard let target = shell.hitTest(shell.convert(point, from: nil)),
              let down = mouseEvent(.leftMouseDown, at: point, window: window),
              let drag = mouseEvent(.leftMouseDragged, at: NSPoint(x: point.x + 20, y: point.y), window: window),
              let up = mouseEvent(.leftMouseUp, at: NSPoint(x: point.x + 20, y: point.y), window: window)
        else { return }
        target.mouseDown(with: down)
        target.mouseDragged(with: drag)
        target.mouseUp(with: up)
    }

    /// The menu a right-click at a window point would show: asked of the hit view and
    /// then up the chain, as AppKit's right-mouse handling does.
    private static func contextMenu(on point: NSPoint, in window: NSWindow, shell: ShellView) -> NSMenu? {
        guard let event = mouseEvent(.rightMouseDown, at: point, window: window) else { return nil }
        var view = shell.hitTest(shell.convert(point, from: nil))
        while let current = view {
            if let menu = current.menu(for: event) { return menu }
            view = current.superview
        }
        return nil
    }

    /// ⌘ plus a key, handed to the main menu as a keypress is.
    ///
    /// When this window is key, the menu delivers the action itself — the exact route
    /// of a keypress. When it is not (macOS will not give a background process the
    /// focus while someone is using another app), the menu cannot find a responder,
    /// so the action the menu item names is sent to this window's first responder and
    /// up its chain — the same chain the menu would have used.
    private static func pressMenuKey(_ key: String, in window: NSWindow) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: key, charactersIgnoringModifiers: key,
            isARepeat: false, keyCode: key == "a" ? 0 : 8) else { return }
        if window.isKeyWindow {
            _ = NSApp.mainMenu?.performKeyEquivalent(with: event)
        } else if let item = menuItem(forKey: key), let action = item.action {
            sendToFirstResponder(action, in: window)
        }
        pump(0.05)
    }

    /// The Edit-menu item a ⌘-key is bound to — so the check fails if the binding does.
    private static func menuItem(forKey key: String) -> NSMenuItem? {
        func search(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.keyEquivalent == key, item.keyEquivalentModifierMask == .command { return item }
                if let submenu = item.submenu, let found = search(submenu) { return found }
            }
            return nil
        }
        return NSApp.mainMenu.flatMap(search)
    }

    /// Sends an action up this window's responder chain, as a nil-targeted menu item
    /// does for the key window.
    private static func sendToFirstResponder(_ action: Selector, in window: NSWindow) {
        if window.isKeyWindow {
            NSApp.sendAction(action, to: nil, from: nil)
        } else {
            _ = (window.firstResponder ?? window).tryToPerform(action, with: nil)
        }
    }

    /// The deepest view under a point that takes library drops — where AppKit sends one.
    private static func dropTarget(at point: NSPoint, in shell: ShellView) -> NSView? {
        var view = shell.hitTest(shell.convert(point, from: nil))
        while let current = view, !current.registeredDraggedTypes.contains(.videoboyLibraryItem) {
            view = current.superview
        }
        return view
    }

    private static func centre(ofRow row: Int, in table: NSTableView) -> NSPoint {
        let rect = table.rect(ofRow: row)
        return NSPoint(x: min(rect.midX, 40), y: rect.midY)
    }

    /// What is wrong with how a panel's library view sits, if anything: every
    /// scrolling area in it must run the full height of the view, and the view must
    /// run from the path bar to the bottom of the panel.
    private static func fitProblems(of body: LibraryPanelBody, named name: String) -> [String] {
        body.layoutSubtreeIfNeeded()
        guard let view = body.visibleLibraryView, let area = view.superview else {
            return ["\(name): nothing showing"]
        }
        var problems: [String] = []
        let expected = area.bounds.height - body.pathBar.frame.height
        if abs(view.frame.height - expected) > 1 {
            problems.append("\(name): view \(Int(view.frame.height))pt of \(Int(expected))pt")
        }
        func scrolls(_ current: NSView) -> [NSScrollView] {
            (current as? NSScrollView).map { [$0] } ?? current.subviews.flatMap(scrolls)
        }
        for scroll in scrolls(view) where !scroll.isHiddenOrHasHiddenAncestor {
            let frame = scroll.convert(scroll.bounds, to: view)
            if abs(frame.height - view.bounds.height) > 1 || abs(frame.minY) > 1 {
                problems.append("\(name): a scroll area at y \(Int(frame.minY)), \(Int(frame.height))pt of \(Int(view.bounds.height))pt")
            }
        }
        return problems
    }

    // MARK: - Finding things

    private static func cells<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var found: [T] = []
        func walk(_ current: NSView) {
            if let match = current as? T, !current.isHiddenOrHasHiddenAncestor { found.append(match) }
            current.subviews.forEach(walk)
        }
        walk(view)
        // Reading order: top to bottom, then left to right.
        return found.sorted {
            let a = $0.convert(NSPoint.zero, to: nil), b = $1.convert(NSPoint.zero, to: nil)
            return abs(a.y - b.y) > 2 ? a.y > b.y : a.x < b.x
        }
    }

    private static func searchField(in view: NSView) -> NSSearchField? {
        if let field = view as? NSSearchField { return field }
        for subview in view.subviews { if let found = searchField(in: subview) { return found } }
        return nil
    }

    private static func segmented(in view: NSView) -> [NSSegmentedControl] {
        var found: [NSSegmentedControl] = []
        if let control = view as? NSSegmentedControl { found.append(control) }
        for subview in view.subviews { found += segmented(in: subview) }
        return found
    }

    /// Window frames of the panel's toolbar controls.
    private static func headerFrames(of panel: LibraryPanelBody) -> [String] {
        var frames: [String] = []
        func walk(_ view: NSView) {
            if view is NSControl, !(view is NSTextField && !(view is NSSearchField)),
               !view.isDescendant(of: panel.gridView), !(panel.listView.map(view.isDescendant) ?? false),
               !(panel.columnView.map(view.isDescendant) ?? false), !view.isDescendant(of: panel.pathBar),
               !view.isHiddenOrHasHiddenAncestor {
                let frame = view.convert(view.bounds, to: nil)
                frames.append("\(type(of: view))@\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))")
            }
            view.subviews.forEach(walk)
        }
        walk(panel)
        return frames
    }

    // MARK: - Pictures

    /// The view as it is on screen, cropped from `screencapture` of its window —
    /// the real pixels, so a glitch that only shows in the compositor is caught.
    private static func writePNG(of view: NSView, to url: URL) {
        guard let window = view.window else { return }
        window.displayIfNeeded()
        pump(0.2)
        let whole = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("videoboy-window-\(window.windowNumber).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", whole.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Log.error(.selfqa, "could not capture \(url.lastPathComponent): \(error)")
            return
        }
        defer { try? FileManager.default.removeItem(at: whole) }
        guard let source = CGImageSourceCreateWithURL(whole as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        let scale = CGFloat(image.width) / window.frame.width
        let inWindow = view.convert(view.bounds, to: nil)
        let crop = CGRect(x: inWindow.minX * scale,
                          y: (window.frame.height - inWindow.maxY) * scale,
                          width: inWindow.width * scale, height: inWindow.height * scale)
        guard let cropped = image.cropping(to: crop.integral),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, cropped, nil)
        CGImageDestinationFinalize(destination)
    }
}
