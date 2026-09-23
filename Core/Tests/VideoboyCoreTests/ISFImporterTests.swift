//
//  ISFImporterTests.swift — importing copies, removing trashes, nothing is lost.
//
//  The promise under test is the operator's: a module imported into Videoboy keeps
//  working after the original file is gone. Every test runs in its own temporary
//  folders; none touches the real ~/Library.
//

import XCTest
@testable import VideoboyCore

final class ISFImporterTests: XCTestCase {

    private var root: URL!
    private var outside: URL!
    private var library: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        Log.echoesToStandardError = false
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("isf-import-\(UUID().uuidString)", isDirectory: true)
        outside = root.appendingPathComponent("Downloads", isDirectory: true)
        library = root.appendingPathComponent("Library/ISF", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func shader(_ description: String = "a test", imported: String = "") -> String {
        """
        /*{
            "DESCRIPTION": "\(description)",
            \(imported)
            "INPUTS": [ { "NAME": "inputImage", "TYPE": "image" } ]
        }*/
        void main() { gl_FragColor = IMG_THIS_PIXEL(inputImage); }
        """
    }

    @discardableResult
    private func write(_ text: String, _ name: String, in folder: URL? = nil) throws -> URL {
        let url = (folder ?? outside).appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func run(_ urls: [URL], reserved: Set<String> = []) -> ISFImportReport {
        ISFImporter.importFiles(urls, into: library, reservedNames: reserved)
    }

    func testImportCopiesTheFileSoDeletingTheOriginalLosesNothing() throws {
        let original = try write(shader(), "Glow.fs")
        let report = run([original])
        XCTAssertEqual(report.importedNames, ["Glow"])

        try FileManager.default.removeItem(at: original)
        let copy = library.appendingPathComponent("Glow.fs")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path), "the copy outlives the original")
        let entries = ISFLibrary.scan([(library, .user)])
        XCTAssertEqual(entries.map(\.name), ["Glow"])
        XCTAssertNotNil(entries.first?.document, "the copy parses as ISF")
    }

    func testAFolderIsWalkedForEveryShader() throws {
        try write(shader("one"), "Pack/One.fs")
        try write(shader("two"), "Pack/Deeper/Two.fs")
        try write("not a shader", "Pack/readme.txt")
        let report = run([outside.appendingPathComponent("Pack")])
        XCTAssertEqual(Set(report.importedNames), ["One", "Two"])
        XCTAssertEqual(report.items.count, 2, "only .fs files are considered")
    }

    func testAFileThatIsNotISFIsSkippedWithAReason() throws {
        let bad = try write("void main() {}", "Plain.fs")
        let report = run([bad])
        XCTAssertTrue(report.importedNames.isEmpty)
        guard case .skipped(let reason) = report.items.first?.outcome else {
            return XCTFail("expected a skip, got \(String(describing: report.items.first?.outcome))")
        }
        XCTAssertTrue(reason.contains("not an ISF file"), reason)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent("Plain.fs").path))
    }

    func testImportingTheSameFileTwiceKeepsOneCopy() throws {
        let original = try write(shader(), "Glow.fs")
        run([original])
        let again = run([original])
        XCTAssertEqual(again.items.first?.outcome, .alreadyImported(name: "Glow"))
        XCTAssertEqual(ISFLibrary.fragmentFiles(in: library).count, 1)
    }

    func testADifferentFileWithATakenNameIsRenamedNotOverwritten() throws {
        run([try write(shader("first"), "Glow.fs")])
        let second = try write(shader("second"), "Glow.fs", in: outside.appendingPathComponent("Other"))
        let report = run([second])
        XCTAssertEqual(report.importedNames, ["Glow 2"])
        let first = try String(contentsOf: library.appendingPathComponent("Glow.fs"), encoding: .utf8)
        XCTAssertTrue(first.contains("first"), "the earlier import is untouched")
    }

    func testAnImportNeverTakesABuiltInName() throws {
        let report = run([try write(shader(), "Colour.fs")], reserved: ["colour"])
        XCTAssertEqual(report.importedNames, ["Colour 2"],
                       "a built-in wins on name, so an import called Colour would be hidden")
    }

    func testImportedImagesAndTheVertexShaderComeAlong() throws {
        let original = try write(
            shader(imported: #""IMPORTED": { "noise": { "PATH": "textures/noise.png" } },"#),
            "Grain.fs")
        try write("vertex", "Grain.vs")
        try write("png bytes", "textures/noise.png")

        let report = run([original])
        XCTAssertEqual(report.items.first?.outcome, .imported(name: "Grain", notes: []))
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.appendingPathComponent("Grain.vs").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: library.appendingPathComponent("textures/noise.png").path),
            "the image keeps its relative path so PATH still resolves")
    }

    func testAMissingImageIsNotedButTheModuleStillImports() throws {
        let original = try write(
            shader(imported: #""IMPORTED": [ { "NAME": "lut", "PATH": "lut.png" } ],"#), "Graded.fs")
        let report = run([original])
        guard case .imported(let name, let notes) = report.items.first?.outcome else {
            return XCTFail("expected an import")
        }
        XCTAssertEqual(name, "Graded")
        XCTAssertEqual(notes.count, 1)
        XCTAssertTrue(notes[0].contains("lut.png"), notes[0])
    }

    func testAnImagePathCannotEscapeTheLibrary() throws {
        let original = try write(
            shader(imported: #""IMPORTED": { "x": { "PATH": "../../escape.png" } },"#), "Sneaky.fs")
        try write("png", "../escape.png")
        let report = run([original])
        guard case .imported(_, let notes) = report.items.first?.outcome else {
            return XCTFail("expected an import")
        }
        XCTAssertTrue(notes.first?.contains("outside") ?? false, "\(notes)")
    }

    func testRemoveTrashesOnlyWhatIsInTheLibrary() throws {
        let original = try write(shader(), "Glow.fs")
        run([original])
        let copy = library.appendingPathComponent("Glow.fs")

        let delete: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
        XCTAssertThrowsError(try ISFImporter.remove(original, libraryFolder: library, trash: delete),
                             "a file outside the library is never touched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))

        try ISFImporter.remove(copy, libraryFolder: library, trash: delete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
    }

    func testAvailableNameCountsUpPastEveryTakenName() {
        XCTAssertEqual(ISFImporter.availableName("Glow", taken: []), "Glow")
        XCTAssertEqual(ISFImporter.availableName("Glow", taken: ["glow", "glow 2"]), "Glow 3")
    }
}
