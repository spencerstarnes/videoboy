//
//  FakeDragging.swift — a drag that can be performed without a mouse.
//
//  Purpose : Drag and drop is the one interaction the offscreen harness could not
//            reach, so it was the one place a regression could hide — and it did.
//            `NSDraggingInfo` is a PROTOCOL, not a class, which means the whole
//            destination side can be driven directly: build one of these, hand it to
//            a real view's `draggingEntered` and `performDragOperation`, and find out
//            whether a drop actually lands.
//  Inputs  : the file URLs being dragged.
//  Outputs : something AppKit's drop handlers accept as a real drag.
//  Connects: UISelfQA, and any view that is a drop destination.
//  Extend  : the members here are the ones the app's drop handlers touch. Adding a
//            handler that reads something else means implementing that too — the
//            protocol is large and most of it is irrelevant to a file drop.
//

import AppKit
import VideoboyCore

/// A drag of one or more files, made up for a check.
final class FakeDragging: NSObject, NSDraggingInfo {

    let draggingPasteboard: NSPasteboard
    var draggingLocation: NSPoint = .zero
    var draggingSourceOperationMask: NSDragOperation = .copy

    /// - Parameter urls: written exactly as the library writes them, so this tests
    ///   the real contract rather than a convenient one.
    init(urls: [URL], pasteboardName: String = "videoboy-fake-drag") {
        draggingPasteboard = NSPasteboard(name: .init(pasteboardName))
        draggingPasteboard.clearContents()
        draggingPasteboard.writeObjects(urls.map { LibraryItemView.pasteboardItem(for: $0) })
        super.init()
    }

    /// A drag of whatever the library would write — clips with their library ids, or
    /// a generator's reference — at a point in window coordinates.
    init(
        pasteboardItems: [NSPasteboardItem], pasteboardName: String = "videoboy-fake-drag",
        location: NSPoint = .zero, mask: NSDragOperation = [.move, .copy, .generic]
    ) {
        draggingPasteboard = NSPasteboard(name: .init(pasteboardName))
        draggingPasteboard.clearContents()
        draggingPasteboard.writeObjects(pasteboardItems)
        draggingLocation = location
        draggingSourceOperationMask = mask
        super.init()
    }

    // The rest of the protocol. None of it is consulted by a file drop, and
    // implementing it honestly as "unused" is clearer than inventing values that
    // look meaningful.
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSequenceNumber: Int { 0 }
    var draggingSource: Any? { nil }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var animatesToDestination: Bool {
        get { false }
        set { _ = newValue }
    }
    var numberOfValidItemsForDrop: Int {
        get { 1 }
        set { _ = newValue }
    }
    var draggingFormation: NSDraggingFormation {
        get { .default }
        set { _ = newValue }
    }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? {
        nil
    }
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    func resetSpringLoading() {}
}
