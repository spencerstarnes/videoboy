//
//  ISFProgram.swift — a converted ISF file, compiled and ready to draw.
//
//  Purpose : Holds the Metal pipelines for one ISF file plus everything needed to
//            drive them (uniform layout, texture order). Immutable once built, so one
//            program is shared by every node showing that file: the A, B and bus
//            copies of a card compile once, not three times.
//  Inputs  : an `ISFDocument` and a Metal device.
//  Outputs : an `ISFProgram`, or an `ISFCompileError` whose message points at the
//            author's own line numbers.
//  Connects: ISFMetalGenerator (source), ISFNode (draws with it), ISFCompiler (builds
//            programs off the render path).
//  Extend  : a new render-target pixel format is one more entry in `pixelFormats`.
//
//  COMPILING IS SLOW (milliseconds to tens of milliseconds) AND MUST NEVER RUN ON THE
//  TICK. `ISFProgram.compile` is synchronous on purpose, so it is boring to test; the
//  only production caller is `ISFCompiler`, which runs it on a background queue.
//

import Foundation
import Metal

/// Why a program could not be built. `description` is what the FX card shows.
public enum ISFCompileError: Error, CustomStringConvertible {
    case parse(ISFParseError)
    case generate(ISFGenerateError)
    /// Metal rejected the converted source. `message` is already translated to the
    /// author's line numbers; `firstError` is the one line a card has room for.
    case metal(message: String, firstError: String)
    case pipeline(String)

    public var description: String {
        switch self {
        case .parse(let error): error.description
        case .generate(let error): error.description
        case .metal(_, let firstError): firstError
        case .pipeline(let detail): "pipeline could not be built: \(detail)"
        }
    }
}

/// A compiled ISF file.
public final class ISFProgram {

    public let document: ISFDocument
    public let shader: ISFGeneratedShader

    /// One pipeline per render-target format in use: 8-bit for ordinary passes and the
    /// graph's own format, 16-bit float for `FLOAT` passes.
    let pipelines: [MTLPixelFormat: MTLRenderPipelineState]

    /// Format for passes that ask for `FLOAT`.
    public static let floatPixelFormat: MTLPixelFormat = .rgba16Float

    private init(document: ISFDocument, shader: ISFGeneratedShader,
                 pipelines: [MTLPixelFormat: MTLRenderPipelineState]) {
        self.document = document
        self.shader = shader
        self.pipelines = pipelines
    }

    /// The pipeline for a target format. Always present for formats `compile` built.
    func pipeline(for format: MTLPixelFormat) -> MTLRenderPipelineState? {
        pipelines[format]
    }

    /// Parses, converts and compiles. Synchronous — call from a background queue.
    public static func compile(
        source: String, vertexSource: String? = nil, name: String, device: MTLDevice
    ) throws -> ISFProgram {
        let document: ISFDocument
        do {
            document = try ISFDocument(source: source, name: name, vertexSource: vertexSource)
        } catch let error as ISFParseError {
            throw ISFCompileError.parse(error)
        }
        return try compile(document: document, device: device)
    }

    /// Tries each global integer vector as a float one, alone, then all together; the
    /// first version that compiles wins. One at a time because a file can hold both
    /// a size that float maths divides by and an integer table that must stay integer.
    private static func retryPromotingIntegerGlobals(
        _ document: ISFDocument, device: MTLDevice
    ) -> (ISFGeneratedShader, MTLLibrary)? {
        let names = ISFMetalGenerator.integerGlobalNames(document)
        let attempts = names.map { Set([$0]) } + (names.count > 1 ? [Set(names)] : [])
        for promoted in attempts {
            guard let shader = try? ISFMetalGenerator.generate(document, promotingIntegerGlobals: promoted),
                  let library = try? device.makeLibrary(source: shader.source, options: nil) else { continue }
            Log.info(.isf, "'\(document.name)': compiled with \(promoted.sorted().joined(separator: ", ")) as float")
            return (shader, library)
        }
        return nil
    }

    /// Converts and compiles an already-parsed document. Synchronous.
    public static func compile(document: ISFDocument, device: MTLDevice) throws -> ISFProgram {
        var shader: ISFGeneratedShader
        do {
            shader = try ISFMetalGenerator.generate(document)
        } catch let error as ISFGenerateError {
            throw ISFCompileError.generate(error)
        }

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: shader.source, options: nil)
        } catch {
            // localizedDescription is the compiler's own text; "\(error)" would wrap
            // it in NSError debug formatting that has no place on a card.
            let raw = (error as NSError).localizedDescription
            // Apple's GLSL mixes int and float vectors silently; Metal does not. One
            // retry with global integer vectors as float ones, only for that error.
            if raw.contains("implicit conversions between vector types"),
               let (retried, retriedLibrary) = retryPromotingIntegerGlobals(document, device: device) {
                shader = retried
                library = retriedLibrary
            } else {
                throw ISFCompileError.metal(
                    message: shader.translateCompilerMessage(raw),
                    firstError: shader.firstError(in: raw))
            }
        }
        guard let vertex = library.makeFunction(name: shader.vertexFunctionName),
              let fragment = library.makeFunction(name: shader.fragmentFunctionName) else {
            throw ISFCompileError.pipeline("entry points missing from the compiled library")
        }

        var formats: Set<MTLPixelFormat> = [MetalContext.pixelFormat]
        if document.passes.contains(where: \.float) { formats.insert(floatPixelFormat) }

        var pipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
        for format in formats {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "isf:\(document.name)"
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = format
            do {
                pipelines[format] = try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                throw ISFCompileError.pipeline("\(error)")
            }
        }
        return ISFProgram(document: document, shader: shader, pipelines: pipelines)
    }
}

/// Builds programs on a background queue and hands them back on the main thread.
///
/// The one rule this type exists to enforce: nothing that compiles runs on the tick.
/// Programs are cached by source text, so asking for the same file twice — three
/// copies of one card, or a reload that changed nothing — compiles once.
public final class ISFCompiler {

    public static let shared = ISFCompiler()

    private let queue = DispatchQueue(label: "videoboy.isf.compile", qos: .userInitiated)
    /// Touched only on `queue`.
    private var cache: [String: ISFProgram] = [:]

    public init() {}

    /// Compiles `source` off the main thread; `completion` runs on main.
    public func compile(
        source: String, vertexSource: String? = nil, name: String, device: MTLDevice,
        completion: @escaping (Result<ISFProgram, ISFCompileError>) -> Void
    ) {
        queue.async { [self] in
            let key = "\(ISFMetalGenerator.version)\u{0}\(name)\u{0}\(source)\u{0}\(vertexSource ?? "")"
            let result: Result<ISFProgram, ISFCompileError>
            if let cached = cache[key] {
                result = .success(cached)
            } else {
                let started = Date()
                do {
                    let program = try ISFProgram.compile(
                        source: source, vertexSource: vertexSource, name: name, device: device)
                    cache[key] = program
                    let milliseconds = Date().timeIntervalSince(started) * 1000
                    Log.info(.isf, "compiled '\(name)' in \(String(format: "%.1f", milliseconds)) ms")
                    result = .success(program)
                } catch let error as ISFCompileError {
                    Log.error(.isf, "'\(name)' failed: \(error.description)")
                    result = .failure(error)
                } catch {
                    let wrapped = ISFCompileError.pipeline("\(error)")
                    Log.error(.isf, "'\(name)' failed: \(wrapped.description)")
                    result = .failure(wrapped)
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
