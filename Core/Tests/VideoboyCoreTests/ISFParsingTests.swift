//
//  ISFParsingTests.swift — the ISF header, the GLSL tokenizer, pass-size arithmetic.
//
//  Pure text in, data out: no Metal, no files. These are the parts of the ISF host
//  that fail silently if they are wrong (a misread DEFAULT, a line count off by one),
//  so each promise is pinned here.
//

import XCTest
@testable import VideoboyCore

final class ISFDocumentTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    private let effect = """
    /*{
        "DESCRIPTION": "test",
        "CREDIT": "me",
        "CATEGORIES": ["Stylize"],
        "INPUTS": [
            { "NAME": "inputImage", "TYPE": "image" },
            { "NAME": "amount", "TYPE": "float", "MIN": 0.0, "MAX": 2.0, "DEFAULT": 0.5, "VIDEOBOY_CODE": "02A" },
            { "NAME": "on", "TYPE": "bool", "DEFAULT": true },
            { "NAME": "mode", "TYPE": "long", "VALUES": [3, 4, 5], "LABELS": ["a", "b", "c"] },
            { "NAME": "tint", "TYPE": "color", "DEFAULT": [1.0, 0.5, 0.25, 1.0] },
            { "NAME": "centre", "TYPE": "point2D", "DEFAULT": [0.5, 0.5] }
        ]
    }*/
    void main() {
        gl_FragColor = IMG_THIS_PIXEL(inputImage);
    }
    """

    func testAnEffectHeaderIsReadInFull() throws {
        let document = try ISFDocument(source: effect, name: "Test")
        XCTAssertEqual(document.kind, .effect)
        XCTAssertEqual(document.summary, "test")
        XCTAssertEqual(document.categories, ["Stylize"])
        XCTAssertEqual(document.inputs.count, 6)
        XCTAssertEqual(document.valueInputs.map(\.name), ["amount", "on", "mode", "tint", "centre"])

        let amount = document.inputs[1]
        XCTAssertEqual(amount.defaultValue, [0.5])
        XCTAssertEqual(amount.minimum, [0.0])
        XCTAssertEqual(amount.maximum, [2.0])
        XCTAssertEqual(amount.videoboyCode, "02A")

        XCTAssertEqual(document.inputs[2].defaultValue, [1], "a JSON true DEFAULT is 1")
        XCTAssertEqual(document.inputs[3].defaultValue, [3], "a popup with no DEFAULT opens on its first VALUE")
        XCTAssertEqual(document.inputs[3].labels, ["a", "b", "c"])
        XCTAssertEqual(document.inputs[4].defaultValue, [1.0, 0.5, 0.25, 1.0])
        XCTAssertEqual(document.inputs[5].componentCount, 2)
        XCTAssertEqual(document.passes.count, 1, "no PASSES means one pass to output")
        XCTAssertNil(document.passes[0].target)
    }

    func testTheBodyStartsOnTheLineAfterTheHeader() throws {
        let document = try ISFDocument(source: effect, name: "Test")
        // The header is 13 lines; the body text begins on the header's last line
        // (right after `*/`), which is line 13.
        XCTAssertEqual(document.fragmentStartLine, 13)
        XCTAssertTrue(document.fragmentSource.contains("void main()"))
    }

    func testKindsFollowTheISFRules() throws {
        let generator = try ISFDocument(source: #"/*{ "INPUTS": [] }*/ void main() {}"#, name: "g")
        XCTAssertEqual(generator.kind, .generator)
        let transition = try ISFDocument(source: #"""
        /*{ "INPUTS": [
            { "NAME": "startImage", "TYPE": "image" },
            { "NAME": "endImage", "TYPE": "image" },
            { "NAME": "progress", "TYPE": "float" }
        ] }*/ void main() {}
        """#, name: "t")
        XCTAssertEqual(transition.kind, .transition)
    }

    func testPassesAndVersionOnePersistentBuffers() throws {
        let document = try ISFDocument(source: #"""
        /*{
            "PERSISTENT_BUFFERS": ["trail"],
            "PASSES": [
                { "TARGET": "half", "WIDTH": "$WIDTH/2", "HEIGHT": 240, "FLOAT": true },
                { "TARGET": "trail" },
                { }
            ]
        }*/ void main() {}
        """#, name: "p")
        XCTAssertEqual(document.passes.count, 3)
        XCTAssertEqual(document.passes[0].widthExpression, "$WIDTH/2")
        XCTAssertEqual(document.passes[0].heightExpression, "240")
        XCTAssertTrue(document.passes[0].float)
        XCTAssertFalse(document.passes[0].persistent)
        XCTAssertTrue(document.passes[1].persistent, "v1 PERSISTENT_BUFFERS still marks the pass")
        XCTAssertNil(document.passes[2].target)
    }

    func testVideoboyExtensionsAreRead() throws {
        let document = try ISFDocument(
            source: #"/*{ "VIDEOBOY": { "IDENTITY_AT_DEFAULTS": true } }*/ void main() {}"#, name: "v")
        XCTAssertTrue(document.identityAtDefaults)
    }

    func testCubeInputTypeIsSupported() throws {
        let document = try ISFDocument(
            source: #"/*{ "INPUTS": [ { "NAME": "env", "TYPE": "cube" } ] }*/ void main() {}"#, name: "c")
        XCTAssertEqual(document.inputs.count, 1)
        XCTAssertEqual(document.inputs[0].type, .cube)
        XCTAssertTrue(document.inputs[0].isImage)
        XCTAssertEqual(document.inputs[0].componentCount, 0)
    }

    func testLineCommentsBeforeTheHeaderAreAllowed() throws {
        let withComments = """
        //#SaturdayShader
        //2015-01 Example
        //Based on something

        /*{ "INPUTS": [] }*/ void main() {}
        """
        let document = try ISFDocument(source: withComments, name: "c")
        XCTAssertEqual(document.kind, .generator)
    }

    func testBrokenFilesSayWhatIsWrong() {
        XCTAssertThrowsError(try ISFDocument(source: "void main() {}", name: "x")) {
            XCTAssertEqual($0 as? ISFParseError, .missingHeader)
        }
        XCTAssertThrowsError(try ISFDocument(source: "/*{ \"INPUTS\": [] ", name: "x")) {
            XCTAssertEqual($0 as? ISFParseError, .unterminatedHeader)
        }
        XCTAssertThrowsError(try ISFDocument(source: "/*{ INPUTS: }*/", name: "x")) {
            guard case .invalidJSON = $0 as? ISFParseError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try ISFDocument(
            source: #"/*{ "INPUTS": [ { "NAME": "a", "TYPE": "wobble" } ] }*/"#, name: "x")) {
            XCTAssertEqual($0 as? ISFParseError, .invalidInput(name: "a", reason: "unknown TYPE 'wobble'"))
        }
        XCTAssertThrowsError(try ISFDocument(
            source: #"/*{ "INPUTS": [ { "NAME": "2bad", "TYPE": "float" } ] }*/"#, name: "x")) {
            guard case .invalidInput(name: "2bad", _) = $0 as? ISFParseError else { return XCTFail("\($0)") }
        }
    }
}

final class GLSLTokenizerTests: XCTestCase {

    /// The property everything else relies on: tokens join back to the exact input.
    func testTokensJoinBackToTheExactSource() {
        let sources = [
            "void main() { gl_FragColor = vec4(1.0, .5, 2e-3, 0x1F); }\n",
            "// comment with vec2 and inout\n/* block\n comment */ float a = 1.0f;",
            "#define X(a) \\\n  (a * 2.0)\nfloat b = X(3.);\n",
            "a <<= 2; b >>= 1; c += d++; e = f != g && h || !i;\r\n",
            "  \t#version 120\n  #ifdef GL_ES\nprecision mediump float;\n#endif\n",
            "ünicode = \"not glsl\"; @ $"
        ]
        for source in sources {
            XCTAssertEqual(GLSLTokenizer.join(GLSLTokenizer.tokenize(source)), source)
        }
    }

    func testTokenKinds() {
        let tokens = GLSLTokenizer.tokenize("inout vec2 p; // hi\n#define A 1\nx += 1.5e2;")
            .filter { $0.kind != .whitespace }
        XCTAssertEqual(tokens.map(\.kind), [
            .identifier, .identifier, .identifier, .symbol, .comment, .preprocessor,
            .identifier, .symbol, .number, .symbol
        ])
        XCTAssertEqual(tokens[7].text, "+=")
        XCTAssertEqual(tokens[8].text, "1.5e2")
    }

    func testAHashMidLineIsNotADirective() {
        let tokens = GLSLTokenizer.tokenize("a # b")
        XCTAssertFalse(tokens.contains { $0.kind == .preprocessor })
    }
}

final class ISFSizeExpressionTests: XCTestCase {

    private func evaluate(_ text: String, _ variables: [String: Double] = ["WIDTH": 720, "HEIGHT": 480]) -> Double? {
        ISFSizeExpression.parse(text)?.evaluate { variables[$0] }
    }

    func testArithmeticAndPrecedence() {
        XCTAssertEqual(evaluate("$WIDTH/2"), 360)
        XCTAssertEqual(evaluate("$WIDTH - $HEIGHT * 0.5"), 480)
        XCTAssertEqual(evaluate("($WIDTH - $HEIGHT) * 0.5"), 120)
        XCTAssertEqual(evaluate("-2 + 10"), 8)
        XCTAssertEqual(evaluate("240"), 240)
    }

    func testFunctionsAndInputVariables() {
        XCTAssertEqual(evaluate("max($HEIGHT * $blur, 1.0)", ["HEIGHT": 480, "blur": 0.0]), 1)
        XCTAssertEqual(evaluate("floor($WIDTH / 7)"), 102)
        XCTAssertEqual(evaluate("min(ceil(2.2), 10)"), 3)
    }

    func testRejectsWhatItCannotRead() {
        XCTAssertNil(ISFSizeExpression.parse("$WIDTH /"))
        XCTAssertNil(ISFSizeExpression.parse("floor($WIDTH"))
        XCTAssertNil(ISFSizeExpression.parse("$WIDTH ? 1 : 2"))
    }

    func testDivisionByZeroIsZeroNotInfinity() {
        XCTAssertEqual(evaluate("$WIDTH / 0"), 0)
    }
}
