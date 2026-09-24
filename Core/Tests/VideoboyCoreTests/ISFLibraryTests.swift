//
//  ISFLibraryTests.swift — what the library scan accepts, and a trial for whole packs.
//
//  The vertex-shader rule: a `.vs` that only calls `isf_vertShaderInit()` is the ISF
//  default and must not fail the shader beside it; anything more still does.
//
//  The folder trial is opt-in. `VIDEOBOY_ISF_TRIAL=/path/to/pack scripts/test.sh
//  --filter ISFFolderTrial` scans that folder the way the app does, compiles every
//  file, renders one frame of each, times it, and writes the pictures and a report to
//  selfqa/out/isf/trial/. It is how a downloaded pack is checked before it goes near
//  the operator's library.
//

import Metal
import XCTest
@testable import VideoboyCore

final class ISFLibraryTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    private static let generator = """
        /*{ "CATEGORIES": ["Generator"], "INPUTS": [
          { "NAME": "speed", "TYPE": "float", "DEFAULT": 1.0, "MIN": 0.0, "MAX": 4.0 } ] }*/
        void main() { gl_FragColor = vec4(isf_FragNormCoord, 0.5 + 0.5 * sin(TIME * speed), 1.0); }
        """

    func testTheDefaultVertexShaderIsRecognisedWhateverItsFormatting() {
        XCTAssertTrue(ISFLibrary.isPassThroughVertexShader("void main() {\n\tisf_vertShaderInit();\n}\n"))
        XCTAssertTrue(ISFLibrary.isPassThroughVertexShader(
            "// written by hand\n/* default */\nvoid main(void)\n{\n  isf_vertShaderInit(); // all\n}"))
        XCTAssertFalse(ISFLibrary.isPassThroughVertexShader(
            "varying vec2 uv;\nvoid main() {\n  isf_vertShaderInit();\n  uv = isf_FragNormCoord * 2.0;\n}"))
        XCTAssertFalse(ISFLibrary.isPassThroughVertexShader(""))
    }

    func testAShaderWithTheDefaultVertexShaderLoadsAndOneWithARealOneDoesNot() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("isf-vs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["Plain", "Custom"] {
            try Self.generator.write(
                to: folder.appendingPathComponent("\(name).fs"), atomically: true, encoding: .utf8)
        }
        try "void main(){\nisf_vertShaderInit();\n}".write(
            to: folder.appendingPathComponent("Plain.vs"), atomically: true, encoding: .utf8)
        try "varying vec2 p;\nvoid main(){\nisf_vertShaderInit();\np = vec2(0.0);\n}".write(
            to: folder.appendingPathComponent("Custom.vs"), atomically: true, encoding: .utf8)

        let entries = Dictionary(uniqueKeysWithValues:
            ISFLibrary.scan([(folder, .user)]).map { ($0.name, $0.result) })
        guard case .success(let document) = entries["Plain"] else {
            return XCTFail("the default .vs failed its shader: \(String(describing: entries["Plain"]))")
        }
        XCTAssertEqual(document.kind, .generator)
        guard case .failure(.needsVertexShader) = entries["Custom"] else {
            return XCTFail("a real vertex shader must still be refused: \(String(describing: entries["Custom"]))")
        }
    }
}

/// Compiles and renders a whole folder of ISF files. Skipped unless asked for.
final class ISFFolderTrialTests: XCTestCase {

    func testTheFolderCompilesAndRenders() throws {
        guard let path = ProcessInfo.processInfo.environment["VIDEOBOY_ISF_TRIAL"] else {
            throw XCTSkip("set VIDEOBOY_ISF_TRIAL to a folder of .fs files to run the trial")
        }
        guard let metal = MetalContext.shared, let renderer = OffscreenRenderer(context: metal) else {
            throw XCTSkip("no Metal device")
        }
        Log.echoesToStandardError = false
        let check = SelfQACheck(name: "isf/trial")
        let entries = ISFLibrary.scan([(URL(fileURLWithPath: path, isDirectory: true), .user)])
        check.note("\(entries.count) files in \(path)")

        // SD frame, the size every source renders at.
        let plate = ImageBuffer(width: 720, height: 480, r: 0, g: 0, b: 0)
        guard let input = metal.makeTexture(from: plate, label: "trial.in") else {
            throw XCTSkip("could not upload")
        }

        var kinds: [String: Int] = [:]
        for entry in entries {
            let document: ISFDocument
            switch entry.result {
            case .failure(let error):
                check.record(AssertionResult(name: "\(entry.name) loads", passed: false, detail: error.description))
                continue
            case .success(let parsed):
                document = parsed
            }
            kinds["\(document.kind)", default: 0] += 1
            do {
                let program = try ISFProgram.compile(
                    source: entry.source ?? "", name: entry.name, device: metal.device)
                let node = ISFNode(identifier: "trial.\(entry.name)", context: metal)
                node.install(program)
                let context = RenderContext(frameIndex: 30, presentationTime: 1.0, musicalPosition: nil)
                // One warm-up render, then a timed one: the first pays for pipeline setup.
                _ = node.render(inputs: [input], context: context)
                metal.waitForIdle()
                let start = CFAbsoluteTimeGetCurrent()
                let output = node.render(inputs: [input], context: context)
                metal.waitForIdle()
                let milliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000
                guard let output, let picture = renderer.readback(output) else {
                    check.record(AssertionResult(name: "\(entry.name) renders", passed: false, detail: "no output"))
                    continue
                }
                _ = try? check.writeImage(picture, named: "\(entry.name).png")
                let drawn = FrameAssertions.signalPresent(picture, varianceThreshold: 1.0)
                check.record(AssertionResult(
                    name: "\(entry.name) compiles and draws",
                    passed: drawn,
                    detail: String(format: "%@, %d controls, %.2f ms at 720x480%@",
                                   "\(document.kind)", ISFControl.controls(for: document).count,
                                   milliseconds, drawn ? "" : " — frame is flat")))
            } catch {
                check.record(AssertionResult(
                    name: "\(entry.name) compiles", passed: false, detail: "\(error)"))
            }
        }
        check.note("kinds: " + kinds.map { "\($0.value) \($0.key)" }.sorted().joined(separator: ", "))
        _ = check.finish()
    }
}
