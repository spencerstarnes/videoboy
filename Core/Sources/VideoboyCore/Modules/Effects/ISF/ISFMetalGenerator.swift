//
//  ISFMetalGenerator.swift — ISF (GLSL) → Metal source, without a translator.
//
//  Purpose : Turns a parsed ISF file into Metal Shading Language that
//            `MTLDevice.makeLibrary(source:)` compiles. It does NOT parse GLSL.
//            It relies on one observation: Metal is C++, and a GLSL shader pasted
//            inside a C++ `struct` compiles almost unchanged, because the struct's
//            members play the part of GLSL's globals (uniforms, images, the pixel
//            coordinate) and its member functions can call each other in any order.
//            Metal's own compiler then does all the real parsing and type checking.
//  Inputs  : an `ISFDocument`.
//  Outputs : `ISFGeneratedShader`: the Metal source, the uniform layout the host must
//            pack, the texture binding order, and a line table that maps Metal's
//            error lines back to lines in the author's `.fs` file.
//  Connects: GLSLTokenizer (tokens), ISFMetalPrelude (the GLSL vocabulary),
//            ISFProgram (compiles the output), ISFNode (packs uniforms by the layout).
//  Extend  : a new GLSL incompatibility is either a prelude function (preferred) or a
//            small token rule in `rewriteBody`. Every rule gets a fixture test that
//            asserts the output COMPILES, not just that the text looks right.
//
//  THE SHAPE OF THE OUTPUT
//
//      <prelude: typedefs, #defines>
//      struct ISFUniforms { TIME, …, one field per input };     // what the host packs
//      struct ISFShader {
//          <uniforms as plain members>   <images as texture members>
//          <sampler, gl_FragCoord, isf_FragNormCoord, gl_FragColor>
//          <prelude helper functions>
//          <THE AUTHOR'S GLSL, lightly rewritten, line count preserved>
//      };
//      vertex   isf_vertex   — full-screen triangle
//      fragment isf_fragment — builds an ISFShader, calls main(), returns gl_FragColor
//
//  The token rules, all local, all line-count preserving:
//    - drop `#version`, `#extension`, `precision …;`, top-level `uniform …;`
//    - drop forward declarations (a member function is visible before its definition)
//    - `in T x` → `T x`,  `out T x` / `inout T x` → `thread T& x`  (parameter lists)
//    - top-level `out vec4 name;` (GLSL 3 output) → dropped, `name` aliased to gl_FragColor
//    - `float[3](a, b, c)` → `{a, b, c}`
//    - identifiers that are Metal/C++ keywords (`texture`, `sampler`, `constant`, …)
//      get a trailing underscore
//    - `.st` / `.stp` swizzles → `.xy` / `.xyz` (Metal has no s/t/p/q swizzles)
//    - `varying` / `attribute` → an explicit "needs a vertex shader" error
//

import Foundation

/// Why a document could not be converted. Shown on the card as-is.
public enum ISFGenerateError: Error, Equatable, CustomStringConvertible {
    case unsupported(String)

    public var description: String {
        switch self {
        case .unsupported(let what): "not supported yet: \(what)"
        }
    }
}

/// The scalar/vector types that appear in the uniform block.
public enum ISFUniformType: String, Sendable {
    case float, int, float2, float4

    /// Metal's size and alignment for the type (natural alignment; no float3 is used,
    /// which is what keeps this table this simple).
    var size: Int {
        switch self {
        case .float, .int: 4
        case .float2: 8
        case .float4: 16
        }
    }

    var alignment: Int { size }
}

/// Where each value lives in the uniform buffer the host sends to the shader.
public struct ISFUniformLayout: Equatable, Sendable {

    public struct Field: Equatable, Sendable {
        public let name: String
        public let type: ISFUniformType
        public let offset: Int
    }

    public let fields: [Field]
    /// Total size in bytes, rounded to the largest alignment, matching Metal.
    public let size: Int

    /// The built-in ISF uniforms, always present, always first, always this order.
    static let builtIns: [(String, ISFUniformType)] = [
        ("TIME", .float), ("TIMEDELTA", .float), ("FRAMEINDEX", .int), ("PASSINDEX", .int),
        ("RENDERSIZE", .float2), ("DATE", .float4),
        // Videoboy extensions: the musical clock (SPEC 4b), for shaders that want to
        // lock to the beat rather than to wall time.
        ("VB_BEAT", .float), ("VB_PHASE", .float)
    ]

    /// Lays out the built-ins then every value input, with Metal's alignment rules.
    init(document: ISFDocument) {
        var entries = ISFUniformLayout.builtIns
        for input in document.valueInputs {
            switch input.type {
            case .float: entries.append((input.name, .float))
            case .bool, .long, .event: entries.append((input.name, .int))
            case .point2D: entries.append((input.name, .float2))
            case .color: entries.append((input.name, .float4))
            case .image, .audio, .audioFFT, .cube: break
            }
        }
        var offset = 0
        var largest = 4
        var fields: [Field] = []
        for (name, type) in entries {
            offset = (offset + type.alignment - 1) / type.alignment * type.alignment
            fields.append(Field(name: name, type: type, offset: offset))
            offset += type.size
            largest = max(largest, type.alignment)
        }
        self.fields = fields
        self.size = (offset + largest - 1) / largest * largest
    }

    /// The field for a name, if it is in the block.
    public func field(named name: String) -> Field? {
        fields.first { $0.name == name }
    }
}

/// Everything the host needs to compile and drive one converted shader.
public struct ISFGeneratedShader: Sendable {
    /// Complete Metal source.
    public let source: String
    public let vertexFunctionName = "isf_vertex"
    public let fragmentFunctionName = "isf_fragment"
    public let uniformLayout: ISFUniformLayout
    /// Texture names by binding index: `[[texture(i)]]` is `textureNames[i]`. Image
    /// inputs first, in file order, then pass targets, in pass order.
    public let textureNames: [String]
    /// 1-based line in `source` where line 1 of the author's GLSL body sits.
    let bodyFirstGeneratedLine: Int
    /// Number of lines the body occupies.
    let bodyLineCount: Int
    /// 1-based line in the `.fs` file where the body starts.
    let bodyFirstFileLine: Int

    /// The `.fs` line for a line of the generated source, or nil when the line is
    /// in the generated wrapper rather than the author's code.
    public func fileLine(forGeneratedLine line: Int) -> Int? {
        let offset = line - bodyFirstGeneratedLine
        guard offset >= 0, offset < bodyLineCount else { return nil }
        return bodyFirstFileLine + offset
    }

    /// Rewrites Metal compiler output so every `program_source:L:C:` in the author's
    /// code reads `line N:C:` against their own file. The first error line is what
    /// the FX card shows.
    public func translateCompilerMessage(_ message: String) -> String {
        let pattern = #/program_source:(\d+):(\d+):/#
        return message.replacing(pattern) { match in
            let generated = Int(match.output.1) ?? 0
            if let fileLine = fileLine(forGeneratedLine: generated) {
                return "line \(fileLine):\(match.output.2):"
            }
            return "generated line \(generated):\(match.output.2):"
        }
    }

    /// The first `error:` line of a compiler message, translated, trimmed for a card.
    public func firstError(in message: String) -> String {
        let translated = translateCompilerMessage(message)
        let line = translated
            .split(separator: "\n")
            .first { $0.contains("error:") }
            .map(String.init) ?? translated.split(separator: "\n").first.map(String.init) ?? ""
        return line.replacingOccurrences(of: "error: ", with: "").trimmingCharacters(in: .whitespaces)
    }
}

/// Converts ISF documents to Metal.
public enum ISFMetalGenerator {

    /// Bumped whenever the output changes, so anything cached against it is rebuilt.
    public static let version = 1

    /// Identifiers GLSL allows as names that Metal or C++ reserve.
    static let reservedRenames: Set<String> = [
        // Metal
        "constant", "device", "thread", "threadgroup", "kernel", "vertex", "fragment",
        "sampler", "texture", "half", "ray_data", "object_data", "metal",
        // C++
        "auto", "catch", "char", "class", "const_cast", "delete", "dynamic_cast",
        "explicit", "export", "friend", "goto", "mutable", "namespace", "new",
        "operator", "private", "protected", "public", "reinterpret_cast", "register",
        "static_assert", "static_cast", "template", "this", "throw", "try", "typeid",
        "typename", "using", "virtual", "and", "or", "not", "xor", "bitand", "bitor",
        "compl", "and_eq", "or_eq", "not_eq", "xor_eq", "alignas", "alignof",
        "decltype", "noexcept", "nullptr", "constexpr", "thread_local", "size_t"
    ]

    /// GLSL type names that can open an array constructor, `float[3](…)`.
    static let typeNames: Set<String> = [
        "float", "int", "uint", "bool",
        "vec2", "vec3", "vec4", "ivec2", "ivec3", "ivec4", "uvec2", "uvec3", "uvec4",
        "bvec2", "bvec3", "bvec4", "mat2", "mat3", "mat4"
    ]

    /// Generates Metal for a document.
    ///
    /// - Throws: `ISFGenerateError.unsupported` for features that are recognised but
    ///   not built yet, so the card can say so instead of failing mysteriously.
    public static func generate(_ document: ISFDocument) throws -> ISFGeneratedShader {
        if !document.importedImages.isEmpty {
            throw ISFGenerateError.unsupported(
                "IMPORTED images (\(document.importedImages.joined(separator: ", ")))")
        }
        if let audio = document.inputs.first(where: { $0.type == .audio || $0.type == .audioFFT }) {
            throw ISFGenerateError.unsupported("audio input '\(audio.name)'")
        }

        let rewrite = try rewriteBody(GLSLTokenizer.tokenize(document.fragmentSource))
        let layout = ISFUniformLayout(document: document)

        var textureNames = document.imageInputs.map(\.name)
        for pass in document.passes {
            if let target = pass.target, !textureNames.contains(target) {
                textureNames.append(target)
            }
        }

        // ---- everything before the body ----
        var head = ISFMetalPrelude.fileScope + "\n\n"
        if let alias = rewrite.outputAlias {
            head += "#define \(alias) gl_FragColor\n"
        }
        head += "// Generated from ISF '\(document.name)' by ISFMetalGenerator v\(version).\n"
        head += "struct ISFUniforms {\n"
        for field in layout.fields {
            head += "    \(field.type.rawValue) \(field.name);\n"
        }
        head += "};\n"
        head += "static_assert(sizeof(ISFUniforms) == \(layout.size), "
            + "\"uniform layout out of step with ISFUniformLayout\");\n\n"

        head += "struct ISFShader {\n"
        head += "    // Uniforms, as plain members so the GLSL body sees them as globals.\n"
        for field in ISFUniformLayout.builtIns {
            head += "    \(memberType(field.1)) \(field.0);\n"
        }
        for input in document.valueInputs {
            head += "    \(memberType(for: input)) \(input.name);\n"
        }
        head += "    // Images: inputs, then pass buffers.\n"
        for name in textureNames {
            head += "    texture2d<float> \(name);\n"
        }
        head += """
            sampler isf_sampler;
            float4 gl_FragCoord;
            float2 isf_FragNormCoord;
            float2 vv_FragNormCoord;
            float4 gl_FragColor = float4(0.0);

        """
        head += ISFMetalPrelude.members + "\n"
        head += "    // ---- author's GLSL body ----\n"

        // ---- the body, then everything after it ----
        let body = rewrite.text
        var tail = "\n    // ---- end of body ----\n};\n\n"
        tail += """
        struct ISFVertexOut {
            float4 position [[position]];
            float2 uv;
        };

        // Full-screen triangle, identical to MetalContext's: uv row 0 is the top row.
        vertex ISFVertexOut isf_vertex(uint vertexID [[vertex_id]]) {
            float2 corners[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
            float2 position = corners[vertexID];
            ISFVertexOut out;
            out.position = float4(position, 0.0, 1.0);
            out.uv = float2((position.x + 1.0) * 0.5, 1.0 - (position.y + 1.0) * 0.5);
            return out;
        }

        fragment float4 isf_fragment(ISFVertexOut in [[stage_in]],
                                     constant ISFUniforms& u [[buffer(0)]]
        """
        for (index, name) in textureNames.enumerated() {
            tail += ",\n                             texture2d<float> tex_\(name) [[texture(\(index))]]"
        }
        tail += ") {\n"
        tail += """
            constexpr sampler isfSampler(filter::linear, address::clamp_to_edge);
            // ISF coordinates are OpenGL's: y runs up from the bottom.
            float2 normalised = float2(in.uv.x, 1.0 - in.uv.y);
            float4 fragCoord = float4(in.position.x, u.RENDERSIZE.y - in.position.y,
                                      in.position.z, in.position.w);

        """
        // Aggregate initialisation, in member declaration order.
        var initialisers: [String] = []
        for field in ISFUniformLayout.builtIns { initialisers.append("u.\(field.0)") }
        for input in document.valueInputs {
            switch input.type {
            case .bool, .event: initialisers.append("(u.\(input.name) != 0)")
            default: initialisers.append("u.\(input.name)")
            }
        }
        for name in textureNames { initialisers.append("tex_\(name)") }
        initialisers += ["isfSampler", "fragCoord", "normalised", "normalised"]
        tail += "    ISFShader shader {\n        "
        tail += initialisers.joined(separator: ",\n        ")
        tail += "\n    };\n"
        tail += "    shader.main();\n"
        tail += "    return shader.gl_FragColor;\n"
        tail += "}\n"

        let headLines = GLSLTokenizer.lineBreakCount(head)
        let bodyLines = GLSLTokenizer.lineBreakCount(body) + 1
        return ISFGeneratedShader(
            source: head + body + tail,
            uniformLayout: layout,
            textureNames: textureNames,
            bodyFirstGeneratedLine: headLines + 1,
            bodyLineCount: bodyLines,
            bodyFirstFileLine: document.fragmentStartLine
        )
    }

    // MARK: - Types

    private static func memberType(_ type: ISFUniformType) -> String {
        switch type {
        case .float: "float"
        case .int: "int"
        case .float2: "float2"
        case .float4: "float4"
        }
    }

    private static func memberType(for input: ISFInput) -> String {
        switch input.type {
        case .float: "float"
        case .bool, .event: "bool"
        case .long: "int"
        case .point2D: "float2"
        case .color: "float4"
        case .image, .audio, .audioFFT: "texture2d<float>"
        case .cube: "texturecube<float>"
        }
    }

    // MARK: - Body rewriting

    struct RewriteResult {
        let text: String
        /// A GLSL 3 `out vec4 name;` declaration, aliased to gl_FragColor.
        let outputAlias: String?
    }

    /// Applies the token rules listed in the file header. Line count is preserved:
    /// anything dropped leaves its newlines behind.
    static func rewriteBody(_ input: [GLSLToken]) throws -> RewriteResult {
        var tokens = input
        var outputAlias: String?

        // Pass 1: local rules anywhere in the body. These run FIRST, so the keywords the
        // top-level pass writes (`thread`) are never mistaken for names to rename.
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            switch token.kind {
            case .preprocessor:
                let directive = token.text.drop { $0 == "#" || $0 == " " || $0 == "\t" }
                if directive.hasPrefix("version") || directive.hasPrefix("extension") {
                    tokens[index].text = ""
                }
            case .identifier:
                if reservedRenames.contains(token.text) {
                    tokens[index].text += "_"
                } else if typeNames.contains(token.text) {
                    rewriteArrayConstructor(at: index, tokens: &tokens)
                }
            case .symbol where token.text == ".":
                if let next = nextSignificant(after: index, in: tokens),
                   tokens[next].kind == .identifier {
                    tokens[next].text = mappedSwizzle(tokens[next].text)
                }
            default:
                break
            }
            index += 1
        }

        // Pass 2: top-level items (declarations and function definitions).
        for item in topLevelItems(tokens) {
            let significant = item.filter { !tokens[$0].isTrivia && tokens[$0].kind != .preprocessor }
            guard let first = significant.first else { continue }
            let head = tokens[first].text

            switch head {
            case "precision", "uniform":
                blank(item, in: &tokens)
                continue
            case "varying", "attribute", "in":
                throw ISFGenerateError.unsupported(
                    "'\(head)' declarations need a custom vertex shader (.vs)")
            case "out":
                // `out vec4 fragColor;` — the GLSL 3 way to name the output.
                if let name = significant.last(where: { tokens[$0].kind == .identifier }) {
                    outputAlias = tokens[name].text
                }
                blank(item, in: &tokens)
                continue
            default:
                break
            }

            let texts = significant.map { tokens[$0].text }
            let isDefinition = texts.contains("{")
            let hasParen = texts.contains("(")
            let equalsBeforeParen: Bool = {
                guard let paren = texts.firstIndex(of: "(") else { return false }
                return texts[..<paren].contains("=")
            }()

            if !isDefinition, hasParen, !equalsBeforeParen, texts.last == ";" {
                // A forward declaration. Redeclaring a member function is an error in
                // C++, and inside a struct it is not needed.
                blank(item, in: &tokens)
                continue
            }
            if isDefinition, hasParen, !equalsBeforeParen {
                rewriteParameterQualifiers(item: significant, tokens: &tokens)
            }
        }

        return RewriteResult(text: GLSLTokenizer.join(tokens), outputAlias: outputAlias)
    }

    /// Splits the token stream into top-level items: each ends at a `;` at depth 0,
    /// or at the `}` closing a function body. Returns token indices per item.
    static func topLevelItems(_ tokens: [GLSLToken]) -> [[Int]] {
        var items: [[Int]] = []
        var current: [Int] = []
        var braceDepth = 0
        var parenDepth = 0
        // Whether the current item reached `{` right after a `)` — a function body —
        // so its closing `}` ends it. A struct body does not; its `;` does.
        var isFunctionBody = false
        var lastSignificant = ""

        for index in tokens.indices {
            let token = tokens[index]
            current.append(index)
            if token.kind == .preprocessor, braceDepth == 0 {
                items.append(current)
                current = []
                continue
            }
            guard !token.isTrivia, token.kind != .preprocessor else { continue }

            switch token.text {
            case "(": parenDepth += 1
            case ")": parenDepth -= 1
            case "{":
                if braceDepth == 0 { isFunctionBody = lastSignificant == ")" }
                braceDepth += 1
            case "}":
                braceDepth -= 1
                if braceDepth == 0, isFunctionBody {
                    items.append(current)
                    current = []
                    isFunctionBody = false
                }
            case ";":
                if braceDepth == 0, parenDepth == 0 {
                    items.append(current)
                    current = []
                }
            default:
                break
            }
            lastSignificant = token.text
        }
        if !current.isEmpty { items.append(current) }
        return items
    }

    /// Replaces a run of tokens with nothing but their newlines.
    private static func blank(_ item: [Int], in tokens: inout [GLSLToken]) {
        for index in item {
            let newlines = String(repeating: "\n", count: tokens[index].newlineCount)
            tokens[index] = GLSLToken(.whitespace, newlines)
        }
    }

    /// In a function header's parameter list: `in T x` → `T x`,
    /// `out T x` / `inout T x` → `thread T& x`.
    private static func rewriteParameterQualifiers(item significant: [Int], tokens: inout [GLSLToken]) {
        // The parameter list is between the first `(` and its matching `)`.
        guard let openPosition = significant.firstIndex(where: { tokens[$0].text == "(" }) else { return }
        var depth = 0
        var position = openPosition
        while position < significant.count {
            let index = significant[position]
            let text = tokens[index].text
            if text == "(" { depth += 1 }
            if text == ")" {
                depth -= 1
                if depth == 0 { break }
            }
            if depth == 1, tokens[index].kind == .identifier {
                if text == "in" {
                    tokens[index].text = ""
                } else if text == "out" || text == "inout" {
                    tokens[index].text = "thread"
                    // The type is the next identifier that is itself followed by an
                    // identifier (the parameter name). Mark it as a reference.
                    var look = position + 1
                    while look + 1 < significant.count {
                        let typeIndex = significant[look]
                        let nameIndex = significant[look + 1]
                        if tokens[typeIndex].kind == .identifier, tokens[nameIndex].kind == .identifier {
                            tokens[typeIndex].text += "&"
                            break
                        }
                        look += 1
                    }
                }
            }
            position += 1
        }
    }

    /// `float[3](a, b, c)` or `float[](a, b, c)` → `{a, b, c}`.
    private static func rewriteArrayConstructor(at typeIndex: Int, tokens: inout [GLSLToken]) {
        guard let open = nextSignificant(after: typeIndex, in: tokens), tokens[open].text == "[" else { return }
        var cursor = open
        guard var next = nextSignificant(after: cursor, in: tokens) else { return }
        if tokens[next].kind == .number {
            cursor = next
            guard let after = nextSignificant(after: cursor, in: tokens) else { return }
            next = after
        }
        guard tokens[next].text == "]",
              let paren = nextSignificant(after: next, in: tokens), tokens[paren].text == "(" else { return }

        // Find the matching `)`.
        var depth = 0
        var close: Int?
        for index in paren..<tokens.count where !tokens[index].isTrivia {
            if tokens[index].text == "(" { depth += 1 }
            if tokens[index].text == ")" {
                depth -= 1
                if depth == 0 { close = index; break }
            }
        }
        guard let close else { return }

        // Blank the type and brackets, turn the parens into braces.
        for index in typeIndex..<paren where tokens[index].kind != .whitespace {
            tokens[index].text = ""
        }
        tokens[paren].text = "{"
        tokens[close].text = "}"
    }

    /// Metal only accepts xyzw/rgba swizzles; GLSL also has stpq.
    private static func mappedSwizzle(_ name: String) -> String {
        guard !name.isEmpty, name.count <= 4, name.allSatisfy({ "stpq".contains($0) }) else { return name }
        return String(name.map { character -> Character in
            switch character {
            case "s": "x"
            case "t": "y"
            case "p": "z"
            default: "w"
            }
        })
    }

    private static func nextSignificant(after index: Int, in tokens: [GLSLToken]) -> Int? {
        var look = index + 1
        while look < tokens.count {
            if !tokens[look].isTrivia { return look }
            look += 1
        }
        return nil
    }
}
