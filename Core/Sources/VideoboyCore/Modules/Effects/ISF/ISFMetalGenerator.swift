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
//    - `varying` / `in` (fragment) and `varying` / `out` (vertex) → collected as
//      varyings: members of both shader structs, carried vertex → fragment through
//      the stage-in struct. Only with a `.vs`; without one they are an error, since
//      nothing would write them. `attribute` is refused: there are no vertex buffers.
//
//    - `.stpq` swizzle mapping skips names declared as struct fields (`hex.q`)
//    - a declaration that reads its own name in its initializer (`vec4 lastRow =
//      IMG_PIXEL(lastRow, …)`, `float distance = distance(a, b)`) renames the new
//      variable from there to the end of its block: in GLSL the initializer still sees
//      the OUTER name, in C++ it would see the variable being declared
//    - a swizzle passed to an `out`/`inout` parameter (`pR(p.xz, a)`) goes through
//      `isf_swizzle<N>(p, 0, 2)`, a temporary that writes back when the call ends —
//      Metal cannot bind a reference to a swizzle, GLSL copies in and out
//
//    - a local declared with no initializer (`vec4 sum;`) gets `{}`: GL drivers
//      hand back zero and files rely on it; Metal hands back garbage
//    - `matN(` → `isf_matN(` (mixed scalar/vector arguments, as GLSL allows)
//    - `a.xz *= m;` → `a.xz = a.xz * (m);` (Metal cannot bind a swizzle to `*=`)
//    - a top-level `uniform T x;` the header does not declare becomes a member that
//      reads zero, rather than vanishing and leaving `x` undeclared
//
//  CUSTOM VERTEX SHADERS (`.vs`). The same trick again: the vertex GLSL goes inside an
//  `ISFVertexShader` struct with the uniforms, images, `gl_Position` and
//  `isf_vertShaderInit()` as members. It is drawn as a four-vertex QUAD, as ISF hosts
//  draw it, not the full-screen triangle — varyings a vertex shader computes are
//  interpolated across the quad's two triangles exactly as they are in VDMX.
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
    /// inputs first, in file order, then audio inputs, then pass targets, in pass order.
    public let textureNames: [String]
    /// 1-based line in `source` where line 1 of the author's GLSL body sits.
    let bodyFirstGeneratedLine: Int
    /// Number of lines the body occupies.
    let bodyLineCount: Int
    /// 1-based line in the `.fs` file where the body starts.
    let bodyFirstFileLine: Int
    /// 1-based line in `source` where line 1 of the `.vs` sits, or nil without one.
    var vertexBodyFirstGeneratedLine: Int? = nil
    var vertexBodyLineCount = 0

    /// Whether a custom vertex shader is compiled in: drawn as a four-vertex strip
    /// with uniforms and images bound to the vertex stage too.
    public var hasVertexShader: Bool { vertexBodyFirstGeneratedLine != nil }

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
            if let first = vertexBodyFirstGeneratedLine,
               generated >= first, generated < first + vertexBodyLineCount {
                return ".vs line \(generated - first + 1):\(match.output.2):"
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
        "decltype", "noexcept", "nullptr", "constexpr", "thread_local", "size_t",
        // C/C++ type words GLSL leaves free: `float signed = sign(x);` is real code.
        "signed", "unsigned", "short", "long", "union", "typedef", "static", "extern",
        "volatile", "inline", "enum"
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
    /// - Parameter promotingIntegerGlobals: names of top-level `ivecN`/`uvecN`
    ///   variables to retype as `vecN`. Apple's GLSL converts them silently where float
    ///   maths meets them (`uv / glyphSize`); Metal will not. Only used as a retry after
    ///   exactly that error, so a shader that compiles as written is never changed.
    public static func generate(
        _ document: ISFDocument, promotingIntegerGlobals: Set<String> = []
    ) throws -> ISFGeneratedShader {
        // IMPORTED cube maps are texture cubes; every other image is 2D.
        let cubes = Set(document.importedCubeMaps)
        func textureType(_ name: String) -> String {
            cubes.contains(name) ? "texturecube<float>" : "texture2d<float>"
        }

        var fragmentTokens = GLSLTokenizer.tokenize(document.fragmentSource)
        if !promotingIntegerGlobals.isEmpty {
            promoteIntegerGlobals(&fragmentTokens, names: promotingIntegerGlobals)
        }
        let rewrite = try rewriteBody(fragmentTokens, stage: .fragment)
        let vertexRewrite = try document.vertexSource.map {
            try rewriteBody(GLSLTokenizer.tokenize($0), stage: .vertex)
        }
        if vertexRewrite == nil, let orphan = rewrite.varyings.first {
            throw ISFGenerateError.unsupported(
                "'varying \(orphan.name)' needs a custom vertex shader (.vs) to write it")
        }
        // Every varying either side declares, the vertex side's first. One declared
        // only in the .fs reads zero, as an unwritten varying does in GL.
        var varyings: [Varying] = vertexRewrite?.varyings ?? []
        for varying in rewrite.varyings where !varyings.contains(where: { $0.name == varying.name }) {
            varyings.append(varying)
        }
        let layout = ISFUniformLayout(document: document)
        // Uniforms the GLSL declares that the header does not: members that read zero.
        let known = Set(ISFUniformLayout.builtIns.map(\.0) + document.inputs.map(\.name)
                        + document.passes.compactMap(\.target) + varyings.map(\.name))
        var extraUniforms: [Varying] = []
        for uniform in rewrite.uniforms + (vertexRewrite?.uniforms ?? [])
        where !known.contains(uniform.name) && !extraUniforms.contains(where: { $0.name == uniform.name }) {
            extraUniforms.append(uniform)
        }
        let extraUniformMembers = extraUniforms.map { "    \($0.member)\n" }.joined()

        // Image inputs, then audio (an image the host fills with sound), then buffers.
        var textureNames = document.imageInputs.map(\.name) + document.audioInputs.map(\.name)
            + document.importedImages
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
            head += "    \(textureType(name)) \(name);\n"
        }
        // ISF v1's per-image uniforms, for the files that still read them. Filled in
        // after construction; declared only when the file mentions them.
        let allSource = document.fragmentSource + (document.vertexSource ?? "")
        let legacyImages = textureNames.filter {
            allSource.contains("_\($0)_img") || allSource.contains("_\($0)_flip")
        }
        head += """
            sampler isf_sampler;
            float4 gl_FragCoord;
            float2 isf_FragNormCoord;
            float2 vv_FragNormCoord;
            float4 gl_FragColor = float4(0.0);

        """
        for varying in varyings {
            head += "    \(varying.member)\n"
        }
        head += legacyImageMembers(legacyImages)
        head += extraUniformMembers
        head += ISFMetalPrelude.members + "\n"
        head += "    // ---- author's GLSL body ----\n"

        // ---- the body, then everything after it ----
        let body = rewrite.text
        var tail = "\n    // ---- end of body ----\n};\n\n"
        var vertexBodyFirstLine: Int?
        var vertexBodyLines = 0
        if let vertexRewrite {
            // The vertex struct, its body, then the stage-in struct and the vertex
            // function that fills it.
            var vertexHead = vertexStructHead(document: document, textureNames: textureNames,
                                              varyings: varyings, legacyImages: legacyImages,
                                              extraUniformMembers: extraUniformMembers)
            vertexHead += "    // ---- author's vertex GLSL ----\n"
            tail += vertexHead
            vertexBodyFirstLine = GLSLTokenizer.lineBreakCount(head) + GLSLTokenizer.lineBreakCount(body)
                + GLSLTokenizer.lineBreakCount(tail) + 1
            vertexBodyLines = GLSLTokenizer.lineBreakCount(vertexRewrite.text) + 1
            tail += vertexRewrite.text
            tail += "\n    // ---- end of vertex GLSL ----\n};\n\n"
            tail += vertexStageFunctions(document: document, textureNames: textureNames,
                                         varyings: varyings, legacyImages: legacyImages)
        } else {
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


            """
        }
        tail += """
        fragment float4 isf_fragment(ISFVertexOut in [[stage_in]],
                                     constant ISFUniforms& u [[buffer(0)]]
        """
        for (index, name) in textureNames.enumerated() {
            tail += ",\n                             \(textureType(name)) tex_\(name) [[texture(\(index))]]"
        }
        tail += ") {\n"
        tail += """
            constexpr sampler isfSampler(filter::linear, address::clamp_to_edge);

        """
        tail += vertexRewrite == nil
            ? """
                // ISF coordinates are OpenGL's: y runs up from the bottom.
                float2 normalised = float2(in.uv.x, 1.0 - in.uv.y);

            """
            : """
                // Written by the vertex shader (isf_vertShaderInit), already y-up.
                float2 normalised = in.isf_norm;

            """
        tail += """
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
        if vertexRewrite != nil {
            for varying in varyings {
                for part in varying.stageFields { tail += "    shader.\(part.access) = in.\(part.field);\n" }
            }
        }
        tail += legacyImageAssignments(legacyImages)
        tail += "    shader.main();\n"
        tail += "    return shader.gl_FragColor;\n"
        tail += "}\n"

        let headLines = GLSLTokenizer.lineBreakCount(head)
        let bodyLines = GLSLTokenizer.lineBreakCount(body) + 1
        var shader = ISFGeneratedShader(
            source: head + body + tail,
            uniformLayout: layout,
            textureNames: textureNames,
            bodyFirstGeneratedLine: headLines + 1,
            bodyLineCount: bodyLines,
            bodyFirstFileLine: document.fragmentStartLine
        )
        shader.vertexBodyFirstGeneratedLine = vertexBodyFirstLine
        shader.vertexBodyLineCount = vertexBodyLines
        return shader
    }

    // MARK: - ISF v1 per-image uniforms

    /// `_name_imgRect` (origin and size), `_name_imgSize`, `_name_flip` per image.
    private static func legacyImageMembers(_ names: [String]) -> String {
        names.map {
            "    float4 _\($0)_imgRect = float4(0.0);\n    float2 _\($0)_imgSize = float2(0.0);\n"
                + "    bool _\($0)_flip = false;\n"
        }.joined()
    }

    /// Fills them from the bound textures. Nothing is flipped: the sampling helpers
    /// already turn Videoboy's top-down rows into ISF's bottom-up coordinates.
    private static func legacyImageAssignments(_ names: [String]) -> String {
        names.map { name in
            "    shader._\(name)_imgSize = float2(float(tex_\(name).get_width()), float(tex_\(name).get_height()));\n"
                + "    shader._\(name)_imgRect = float4(0.0, 0.0, shader._\(name)_imgSize);\n"
        }.joined()
    }

    // MARK: - Custom vertex shaders

    /// `ISFVertexShader`, up to where the author's `.vs` body goes: the same uniforms
    /// and images the fragment side sees, `gl_Position`, the varyings, and the ISF
    /// vertex built-ins.
    private static func vertexStructHead(
        document: ISFDocument, textureNames: [String], varyings: [Varying], legacyImages: [String],
        extraUniformMembers: String
    ) -> String {
        let cubes = Set(document.importedCubeMaps)
        func textureType(_ name: String) -> String {
            cubes.contains(name) ? "texturecube<float>" : "texture2d<float>"
        }
        var text = "struct ISFVertexShader {\n"
        for field in ISFUniformLayout.builtIns {
            text += "    \(memberType(field.1)) \(field.0);\n"
        }
        for input in document.valueInputs {
            text += "    \(memberType(for: input)) \(input.name);\n"
        }
        for name in textureNames {
            text += "    \(textureType(name)) \(name);\n"
        }
        text += """
            sampler isf_sampler;
            // The corner being processed, in clip space: what isf_vertShaderInit puts out.
            float2 isf_quadPosition;
            float4 gl_Position = float4(0.0);
            float4 gl_Vertex = float4(0.0);
            float2 isf_FragNormCoord = float2(0.0);
            float2 vv_FragNormCoord = float2(0.0);

        """
        for varying in varyings {
            text += "    \(varying.member)\n"
        }
        text += legacyImageMembers(legacyImages)
        text += extraUniformMembers
        text += """
            // The ISF default vertex stage: a full-frame quad, normalised coordinates
            // with (0,0) at the bottom left.
            void isf_vertShaderInit() {
                gl_Position = float4(isf_quadPosition, 0.0, 1.0);
                gl_Vertex = gl_Position;
                isf_FragNormCoord = isf_quadPosition * 0.5 + 0.5;
                vv_FragNormCoord = isf_FragNormCoord;
            }
            void vv_vertShaderInit() { isf_vertShaderInit(); }

        """
        text += ISFMetalPrelude.vertexMembers + "\n"
        return text
    }

    /// The stage-in struct and the vertex function for a custom vertex shader.
    private static func vertexStageFunctions(
        document: ISFDocument, textureNames: [String], varyings: [Varying], legacyImages: [String]
    ) -> String {
        let cubes = Set(document.importedCubeMaps)
        func textureType(_ name: String) -> String {
            cubes.contains(name) ? "texturecube<float>" : "texture2d<float>"
        }
        var text = "struct ISFVertexOut {\n    float4 position [[position]];\n    float2 isf_norm;\n"
        for varying in varyings {
            // Integers cannot be interpolated; GLSL requires them `flat` too.
            let flat = varying.type.hasPrefix("int") || varying.type.hasPrefix("ivec")
                || varying.type.hasPrefix("uint") || varying.type.hasPrefix("uvec")
            for part in varying.stageFields {
                text += "    \(part.type) \(part.field)\(flat ? " [[flat]]" : "");\n"
            }
        }
        text += "};\n\n"
        text += """
        // Four corners as a strip — the quad ISF hosts draw.
        vertex ISFVertexOut isf_vertex(uint vertexID [[vertex_id]],
                                       constant ISFUniforms& u [[buffer(0)]]
        """
        for (index, name) in textureNames.enumerated() {
            text += ",\n                               \(textureType(name)) tex_\(name) [[texture(\(index))]]"
        }
        text += ") {\n"
        text += """
            constexpr sampler isfSampler(filter::linear, address::clamp_to_edge);
            float2 corners[4] = { float2(-1.0, -1.0), float2(1.0, -1.0),
                                  float2(-1.0, 1.0), float2(1.0, 1.0) };

        """
        var initialisers: [String] = ISFUniformLayout.builtIns.map { "u.\($0.0)" }
        for input in document.valueInputs {
            switch input.type {
            case .bool, .event: initialisers.append("(u.\(input.name) != 0)")
            default: initialisers.append("u.\(input.name)")
            }
        }
        initialisers += textureNames.map { "tex_\($0)" }
        initialisers += ["isfSampler", "corners[vertexID]"]
        text += "    ISFVertexShader shader {\n        "
        text += initialisers.joined(separator: ",\n        ")
        text += "\n    };\n"
        text += legacyImageAssignments(legacyImages)
        text += "    shader.main();\n"
        text += "    ISFVertexOut out;\n    out.position = shader.gl_Position;\n"
        text += "    out.isf_norm = shader.isf_FragNormCoord;\n"
        for varying in varyings {
            for part in varying.stageFields { text += "    out.\(part.field) = shader.\(part.access);\n" }
        }
        text += "    return out;\n}\n\n"
        return text
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
        /// Top-level varyings, in declaration order.
        var varyings: [Varying] = []
        /// Top-level `uniform` declarations (not samplers), for names the header lacks.
        var uniforms: [Varying] = []
    }

    /// One varying: its GLSL type, name, and array length (nil for a plain value).
    struct Varying {
        let type: String
        let name: String
        let count: Int?

        /// The member declaration inside a shader struct, zero-initialised.
        var member: String {
            if count != nil || type.hasPrefix("mat") || type.hasPrefix("float") && type.contains("x") {
                return "\(type) \(name)\(count.map { "[\($0)]" } ?? "") = {};"
            }
            return "\(type) \(name) = \(type)(0);"
        }

        /// Metal cannot pass arrays or matrices between stages, so each becomes plain
        /// fields in the stage-in struct: `name_0`, `name_1`… for array elements,
        /// `name_c0`… for a matrix's columns. `(field, field type, access)`, where
        /// access is the expression that reads/writes that part in the shader struct.
        var stageFields: [(field: String, type: String, access: String)] {
            let columns: Int? = {
                switch type {
                case "mat2", "float2x2": 2
                case "mat3", "float3x3": 3
                case "mat4", "float4x4": 4
                default: nil
                }
            }()
            let elements: [(suffix: String, access: String)] = count.map { count in
                (0..<count).map { ("_\($0)", "\(name)[\($0)]") }
            } ?? [("", name)]
            var fields: [(String, String, String)] = []
            for element in elements {
                if let columns {
                    for column in 0..<columns {
                        fields.append(("\(name)\(element.suffix)_c\(column)", "float\(columns)",
                                       "\(element.access)[\(column)]"))
                    }
                } else {
                    fields.append(("\(name)\(element.suffix)", type, element.access))
                }
            }
            return fields
        }
    }

    /// Which side of the pipeline a body is: decides what `in` and `out` mean.
    enum Stage { case fragment, vertex }

    /// Qualifiers that can precede a varying's type.
    private static let varyingQualifiers: Set<String> = [
        "varying", "in", "out", "flat", "smooth", "noperspective", "centroid",
        "highp", "mediump", "lowp"
    ]

    /// Applies the token rules listed in the file header. Line count is preserved:
    /// anything dropped leaves its newlines behind.
    static func rewriteBody(_ input: [GLSLToken], stage: Stage = .fragment) throws -> RewriteResult {
        var tokens = input
        var outputAlias: String?
        var varyings: [Varying] = []
        var uniforms: [Varying] = []
        var inoutFunctions: [String: Set<Int>] = [:]
        let structFields = structFieldNames(tokens)

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
                    if ["mat2", "mat3", "mat4"].contains(tokens[index].text),
                       let next = nextSignificant(after: index, in: tokens), tokens[next].text == "(" {
                        tokens[index].text = "isf_" + tokens[index].text
                    }
                }
            case .symbol where token.text == ".":
                if let next = nextSignificant(after: index, in: tokens),
                   tokens[next].kind == .identifier, !structFields.contains(tokens[next].text) {
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
            case "precision":
                blank(item, in: &tokens)
                continue
            case "uniform":
                let texts = significant.map { tokens[$0].text }
                if !texts.contains(where: { $0.hasPrefix("sampler") }) {
                    uniforms += (try? parseVaryings(Array(texts.dropFirst()))) ?? []
                }
                blank(item, in: &tokens)
                continue
            case "attribute":
                throw ISFGenerateError.unsupported("vertex attributes ('attribute' declarations)")
            case "in" where stage == .vertex:
                throw ISFGenerateError.unsupported("vertex inputs ('in' declarations in a .vs)")
            case "varying", "in", "flat", "smooth", "noperspective", "centroid":
                varyings += try parseVaryings(significant.map { tokens[$0].text })
                blank(item, in: &tokens)
                continue
            case "out" where stage == .vertex:
                varyings += try parseVaryings(significant.map { tokens[$0].text })
                blank(item, in: &tokens)
                continue
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
                let referenceParameters = rewriteParameterQualifiers(item: significant, tokens: &tokens)
                if !referenceParameters.isEmpty,
                   let paren = texts.firstIndex(of: "("), paren > 0 {
                    inoutFunctions[texts[paren - 1], default: []].formUnion(referenceParameters)
                }
            }
        }

        // Pass 3: rules that need the whole body.
        let typeWords = typeNames.union(["void"]).union(structNames(tokens))
        renameSelfReferencingDeclarations(&tokens, typeWords: typeWords)
        zeroInitialiseLocals(&tokens, typeWords: typeWords)
        rewriteSwizzleCompoundMultiply(&tokens)
        rewriteSwizzleArguments(&tokens, functions: inoutFunctions, typeWords: typeWords)

        // Files that serve GLSL 1.2 and 3 both (`#if __VERSION__ <= 120` … `varying`,
        // `#else` … `out`) declare every varying twice. Both declarations are blanked;
        // one member each is kept.
        var seen = Set<String>()
        varyings = varyings.filter { seen.insert($0.name).inserted }
        return RewriteResult(text: GLSLTokenizer.join(tokens), outputAlias: outputAlias,
                             varyings: varyings, uniforms: uniforms)
    }

    /// `varying vec2 a, b[5];` → a (vec2), b (vec2 × 5). An array length must be a
    /// number: a named constant cannot be sized before the body is compiled.
    static func parseVaryings(_ texts: [String]) throws -> [Varying] {
        let words = Array(texts.drop { varyingQualifiers.contains($0) })
        guard let type = words.first else { return [] }
        var result: [Varying] = []
        var index = 1
        while index < words.count {
            let word = words[index]
            if word == "," || word == ";" || varyingQualifiers.contains(word) {
                index += 1
                continue
            }
            var count: Int?
            if index + 1 < words.count, words[index + 1] == "[" {
                guard index + 3 < words.count, let length = Int(words[index + 2]), words[index + 3] == "]" else {
                    throw ISFGenerateError.unsupported("a varying array sized by a name ('\(word)')")
                }
                count = length
                result.append(Varying(type: type, name: word, count: count))
                index += 4
                continue
            }
            result.append(Varying(type: type, name: word, count: nil))
            index += 1
        }
        return result
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
    /// Returns the 0-based positions of the parameters that became references.
    @discardableResult
    private static func rewriteParameterQualifiers(item significant: [Int], tokens: inout [GLSLToken]) -> Set<Int> {
        // The parameter list is between the first `(` and its matching `)`.
        guard let openPosition = significant.firstIndex(where: { tokens[$0].text == "(" }) else { return [] }
        var references = Set<Int>()
        var parameter = 0
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
            if depth == 1, text == "," { parameter += 1 }
            if depth == 1, tokens[index].kind == .identifier {
                if text == "in" {
                    tokens[index].text = ""
                } else if text == "out" || text == "inout" {
                    references.insert(parameter)
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
        return references
    }

    // MARK: - Whole-body rules

    /// Every `struct` name the body declares, so its variables are known as types.
    static func structNames(_ tokens: [GLSLToken]) -> Set<String> {
        let significant = tokens.filter { !$0.isTrivia && $0.kind != .preprocessor }.map(\.text)
        var names = Set<String>()
        for (index, text) in significant.enumerated() where text == "struct" && index + 1 < significant.count {
            names.insert(significant[index + 1])
        }
        return names
    }

    /// Every name declared as a field of a `struct` in the body.
    static func structFieldNames(_ tokens: [GLSLToken]) -> Set<String> {
        var fields = Set<String>()
        let significant = tokens.indices.filter { !tokens[$0].isTrivia && tokens[$0].kind != .preprocessor }
        var position = 0
        while position < significant.count {
            guard tokens[significant[position]].text == "struct" else { position += 1; continue }
            // struct Name { type a, b; type c; }
            guard let open = (position..<significant.count).first(where: { tokens[significant[$0]].text == "{" })
            else { break }
            var cursor = open + 1
            var previous: String?
            while cursor < significant.count, tokens[significant[cursor]].text != "}" {
                let text = tokens[significant[cursor]].text
                if (text == ";" || text == "," || text == "["), let name = previous,
                   tokens[significant[cursor - 1]].kind == .identifier {
                    fields.insert(name)
                }
                previous = text
                cursor += 1
            }
            position = cursor + 1
        }
        return fields
    }

    /// `T name = …name…;` → the new variable is `name_isf` from its declarator to the
    /// end of its block, and the initializer keeps meaning the outer `name`.
    static func renameSelfReferencingDeclarations(_ tokens: inout [GLSLToken], typeWords: Set<String>) {
        let significant = tokens.indices.filter { !tokens[$0].isTrivia && tokens[$0].kind != .preprocessor }
        func text(_ position: Int) -> String {
            position >= 0 && position < significant.count ? tokens[significant[position]].text : ""
        }
        var position = 1
        while position + 1 < significant.count {
            defer { position += 1 }
            let nameIndex = significant[position]
            // A declaration: a type word, then the name, then `=` (`return x = …` is not).
            guard tokens[nameIndex].kind == .identifier, text(position + 1) == "=",
                  typeWords.contains(text(position - 1)) else { continue }
            let name = tokens[nameIndex].text
            // The initializer: up to `;` or `,` at depth 0.
            var end = position + 2
            var depth = 0
            var mentions = false
            while end < significant.count {
                let t = text(end)
                if t == "(" || t == "[" || t == "{" { depth += 1 }
                if t == ")" || t == "]" || t == "}" { depth -= 1 }
                if depth < 0 || (depth == 0 && (t == ";" || t == ",")) { break }
                if t == name, text(end - 1) != "." { mentions = true }
                end += 1
            }
            guard mentions else { continue }
            // Rename the declarator, then every later use until the block closes.
            let renamed = name + "_isf"
            tokens[nameIndex].text = renamed
            var blockDepth = 0
            var cursor = end
            while cursor < significant.count {
                let t = text(cursor)
                if t == "{" { blockDepth += 1 }
                if t == "}" {
                    blockDepth -= 1
                    if blockDepth < 0 { break }
                }
                if t == name, text(cursor - 1) != "." {
                    tokens[significant[cursor]].text = renamed
                }
                cursor += 1
            }
        }
    }

    /// `vec4 sum;` inside a function → `vec4 sum{};` — a local with no initializer
    /// starts at zero.
    ///
    /// GLSL leaves such a local undefined, but every GL driver an ISF author tests on
    /// hands back zero, and real files depend on it: Vidvox's Diagonal Blur declares
    /// `vec4 returnMe;` and then accumulates `returnMe = returnMe + …`. Metal really
    /// does leave the register holding whatever was there, so that file rendered as
    /// full-frame coloured noise. `{}` value-initialises every GLSL type — scalar,
    /// vector, matrix, array or struct — to zero. Globals need no rule: they are
    /// members of the shader struct, which is aggregate-initialised, so they are zeroed
    /// already.
    static func zeroInitialiseLocals(_ tokens: inout [GLSLToken], typeWords: Set<String>) {
        let declarable = typeWords.subtracting(["void"])
        for item in topLevelItems(tokens) {
            let significant = item.filter { !tokens[$0].isTrivia && tokens[$0].kind != .preprocessor }
            func text(_ position: Int) -> String {
                position >= 0 && position < significant.count ? tokens[significant[position]].text : ""
            }
            // Function definitions only: the first `{` follows the parameter list's `)`.
            guard let open = significant.indices.first(where: { text($0) == "{" }),
                  text(open - 1) == ")" else { continue }

            // Braces opened by `struct Name {` inside the body: their fields are not locals.
            var structDepths: [Bool] = []
            var parenDepth = 0
            var position = open
            while position < significant.count {
                let current = text(position)
                switch current {
                case "{":
                    structDepths.append(text(position - 2) == "struct" || text(position - 1) == "struct")
                case "}":
                    _ = structDepths.popLast()
                case "(":
                    parenDepth += 1
                case ")":
                    parenDepth -= 1
                default:
                    break
                }
                let previous = text(position - 1)
                let startsStatement = position > open && parenDepth == 0
                    && (previous == ";" || previous == "{" || previous == "}")
                guard startsStatement, structDepths.last == false,
                      declarable.contains(current), position + 1 < significant.count,
                      tokens[significant[position + 1]].kind == .identifier
                else {
                    position += 1
                    continue
                }
                // Walk the declarators to the `;`. Each one without an `=` gets `{}`
                // after its last token — the name, or the `]` of an array length.
                var cursor = position + 1
                var depth = 0
                var hasInitialiser = false
                while cursor < significant.count {
                    let t = text(cursor)
                    if t == "(" || t == "[" || t == "{" { depth += 1 }
                    if t == ")" || t == "]" || t == "}" { depth -= 1 }
                    if depth < 0 { break }
                    if depth == 0, t == "=" { hasInitialiser = true }
                    if depth == 0, t == "," || t == ";" {
                        if !hasInitialiser {
                            tokens[significant[cursor - 1]].text += "{}"
                        }
                        hasInitialiser = false
                        if t == ";" { break }
                    }
                    cursor += 1
                }
                position = cursor + 1
            }
        }
    }

    /// `a.xz *= m;` → `a.xz = a.xz * (m);`. Same meaning in GLSL; the only spelling
    /// Metal takes when `m` is a matrix, since `*=` would need a reference to a swizzle.
    static func rewriteSwizzleCompoundMultiply(_ tokens: inout [GLSLToken]) {
        let significant = tokens.indices.filter { !tokens[$0].isTrivia && tokens[$0].kind != .preprocessor }
        func text(_ position: Int) -> String {
            position >= 0 && position < significant.count ? tokens[significant[position]].text : ""
        }
        for position in significant.indices where text(position) == "*=" {
            guard position >= 3, text(position - 2) == ".", text(position - 4) != ".",
                  tokens[significant[position - 3]].kind == .identifier,
                  let indices = swizzleIndices(text(position - 1)), indices.count >= 2 else { continue }
            // Find the end of the right-hand side.
            var end = position + 1
            var depth = 0
            while end < significant.count {
                let t = text(end)
                if t == "(" || t == "[" { depth += 1 }
                if t == ")" || t == "]" { depth -= 1 }
                if depth < 0 || (depth == 0 && (t == ";" || t == ",")) { break }
                end += 1
            }
            let target = "\(text(position - 3)).\(text(position - 1))"
            tokens[significant[position]].text = "= \(target) * ("
            if end < significant.count {
                tokens[significant[end]].text = ")" + tokens[significant[end]].text
            }
        }
    }

    /// `f(p.xz, …)` where `f`'s first parameter is `inout` → `f(isf_swizzle<2>(p, 0, 2), …)`.
    static func rewriteSwizzleArguments(
        _ tokens: inout [GLSLToken], functions: [String: Set<Int>], typeWords: Set<String>
    ) {
        guard !functions.isEmpty else { return }
        let significant = tokens.indices.filter { !tokens[$0].isTrivia && tokens[$0].kind != .preprocessor }
        func text(_ position: Int) -> String {
            position >= 0 && position < significant.count ? tokens[significant[position]].text : ""
        }
        for position in significant.indices {
            guard let parameters = functions[text(position)], text(position + 1) == "(" else { continue }
            // Skip the definition itself: a type word sits before its name.
            if typeWords.contains(text(position - 1)) { continue }
            var argument = 0
            var depth = 0
            var start = position + 2
            var cursor = position + 2
            while cursor < significant.count {
                let t = text(cursor)
                let closes = (t == ")" && depth == 0)
                if (t == "," && depth == 0) || closes {
                    // Exactly `name . swizzle`.
                    if parameters.contains(argument), cursor - start == 3, text(start + 1) == ".",
                       tokens[significant[start]].kind == .identifier,
                       let indices = swizzleIndices(text(start + 2)) {
                        let base = text(start)
                        tokens[significant[start]].text = indices.count == 1
                            ? "isf_component(\(base), \(indices[0]))"
                            : "isf_swizzle<\(indices.count)>(\(base), \(indices.map(String.init).joined(separator: ", ")))"
                        tokens[significant[start + 1]].text = ""
                        tokens[significant[start + 2]].text = ""
                    }
                    argument += 1
                    start = cursor + 1
                    if closes { break }
                } else if t == "(" || t == "[" {
                    depth += 1
                } else if t == ")" || t == "]" {
                    depth -= 1
                }
                cursor += 1
            }
        }
    }

    /// The top-level `ivecN`/`uvecN` variables a file declares, by name.
    public static func integerGlobalNames(_ document: ISFDocument) -> [String] {
        let tokens = GLSLTokenizer.tokenize(document.fragmentSource)
        var names: [String] = []
        for item in topLevelItems(tokens) {
            let texts = item.filter { !tokens[$0].isTrivia && tokens[$0].kind != .preprocessor }.map { tokens[$0].text }
            guard !texts.contains("{"), let typePosition = texts.firstIndex(where: { $0 != "const" }),
                  texts[typePosition].hasPrefix("ivec") || texts[typePosition].hasPrefix("uvec"),
                  typePosition + 1 < texts.count else { continue }
            names.append(texts[typePosition + 1])
        }
        return names
    }

    /// Top-level `uvec2 name = …;` → `vec2 name = vec2(…);` for the named globals.
    static func promoteIntegerGlobals(_ tokens: inout [GLSLToken], names: Set<String>) {
        for item in topLevelItems(tokens) {
            let significant = item.filter { !tokens[$0].isTrivia && tokens[$0].kind != .preprocessor }
            guard significant.count > 2 else { continue }
            let texts = significant.map { tokens[$0].text }
            // A variable, not a function: no `{`, and the type is first (after const).
            guard !texts.contains("{"), let typePosition = texts.firstIndex(where: { $0 != "const" }) else { continue }
            let type = texts[typePosition]
            guard let size = ["ivec2": 2, "ivec3": 3, "ivec4": 4, "uvec2": 2, "uvec3": 3, "uvec4": 4][type],
                  typePosition + 1 < texts.count, names.contains(texts[typePosition + 1])
            else { continue }
            for index in significant where ["ivec", "uvec"].contains(where: { tokens[index].text == "\($0)\(size)" }) {
                tokens[index].text = "vec\(size)"
            }
        }
    }

    /// `xz` → [0, 2]; nil for anything that is not a swizzle.
    static func swizzleIndices(_ name: String) -> [Int]? {
        guard (1...4).contains(name.count) else { return nil }
        var indices: [Int] = []
        for character in name {
            switch character {
            case "x", "r", "s": indices.append(0)
            case "y", "g", "t": indices.append(1)
            case "z", "b", "p": indices.append(2)
            case "w", "a", "q": indices.append(3)
            default: return nil
            }
        }
        return indices
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
