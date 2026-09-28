//
//  BeatNetWeights.swift — the trained BeatNet network, read from one binary file.
//
//  Purpose : Loads `beatnet-model1.bin`: the madmom log filterbank BeatNet's features
//            are built with, and the weights of BeatNet's CRNN (model 1, the one
//            BeatNet itself uses by default). Everything the port needs that came
//            out of training lives in this one file; nothing is recomputed.
//  Inputs  : a file URL. The App ships it at Contents/Resources/BeatNet/; tests read
//            it from App/Resources/BeatNet/ in the repo.
//  Outputs : `BeatNetWeights`, handed to BeatNetFeatures and BeatNetModel.
//  Connects: BeatNetTracker loads it once per audio input.
//  Extend  : the file is written by the export script described in
//            docs/BEATNET.md. A new model is a new file with the same layout.
//
//  Credit  : BeatNet by Mojtaba Heydari, Frank Cwitkowitz and Zhiyao Duan (ISMIR
//            2021), github.com/mjhydri/BeatNet, CC BY 4.0. The weights are theirs,
//            converted to this layout unchanged. The filterbank is computed by
//            madmom (BSD); see docs/THIRD-PARTY.md.
//
//  ── FILE LAYOUT (little-endian) ─────────────────────────────────────────────────
//
//  "BNET", u32 version (1), u32 tensor count, then for each tensor: u32 rank,
//  u32 dims[rank], float32 values in row-major order. Tensors, in order:
//  filterbank (705×136), conv1 weight (2×1×10) and bias (2), linear0 weight
//  (150×262) and bias (150), LSTM layer 0 and layer 1 (each W_ih 600×150,
//  W_hh 600×150, b_ih 600, b_hh 600), linear weight (3×150) and bias (3).
//

import Foundation

/// One tensor: its shape and its values, row-major.
public struct BeatNetTensor {
    public let shape: [Int]
    public let values: [Float]
}

/// Why the weights file could not be used.
public enum BeatNetWeightsError: Error, CustomStringConvertible {
    case unreadable(String)
    case malformed(String)

    public var description: String {
        switch self {
        case .unreadable(let why): return "BeatNet weights unreadable: \(why)"
        case .malformed(let why): return "BeatNet weights malformed: \(why)"
        }
    }
}

/// The filterbank and network weights, checked against the shapes the port expects.
public struct BeatNetWeights {
    /// Rows are FFT bins (705), columns are log-frequency bands (136).
    public let filterbank: BeatNetTensor
    public let convWeight: BeatNetTensor
    public let convBias: BeatNetTensor
    public let linear0Weight: BeatNetTensor
    public let linear0Bias: BeatNetTensor
    /// Per LSTM layer: input weights, hidden weights, input bias, hidden bias.
    public let lstm: [(inputWeight: BeatNetTensor, hiddenWeight: BeatNetTensor,
                       inputBias: BeatNetTensor, hiddenBias: BeatNetTensor)]
    public let outputWeight: BeatNetTensor
    public let outputBias: BeatNetTensor

    /// The shapes the file must hold, in order. Anything else is refused rather than
    /// run: a network with the wrong shapes produces confident nonsense, not an error.
    static let expectedShapes: [[Int]] = [
        [BeatNetFeatures.fftBins, BeatNetFeatures.bands],
        [2, 1, 10], [2],
        [150, 262], [150],
        [600, 150], [600, 150], [600], [600],
        [600, 150], [600, 150], [600], [600],
        [3, 150], [3]
    ]

    /// Where the shipped weights are: inside the app bundle when running as the
    /// .app, else in the repo (tests, `swift run`) — the ISF built-ins' rule.
    public static var bundledURL: URL {
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("BeatNet/beatnet-model1.bin")
            if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        }
        return RepoPaths.root.appendingPathComponent("App/Resources/BeatNet/beatnet-model1.bin")
    }

    /// The shipped weights, read once and shared (they are 2 MB and never change).
    /// The error says why, when they cannot be used.
    public static let shared: Result<BeatNetWeights, Error> = Result {
        try BeatNetWeights(contentsOf: bundledURL)
    }

    /// Reads and validates the file.
    public init(contentsOf url: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BeatNetWeightsError.unreadable("\(url.path): \(error.localizedDescription)")
        }
        let tensors = try Self.parse(data)
        guard tensors.map(\.shape) == Self.expectedShapes else {
            throw BeatNetWeightsError.malformed(
                "shapes \(tensors.map(\.shape)) are not the BeatNet model-1 layout")
        }
        filterbank = tensors[0]
        convWeight = tensors[1]
        convBias = tensors[2]
        linear0Weight = tensors[3]
        linear0Bias = tensors[4]
        lstm = [(tensors[5], tensors[6], tensors[7], tensors[8]),
                (tensors[9], tensors[10], tensors[11], tensors[12])]
        outputWeight = tensors[13]
        outputBias = tensors[14]
    }

    /// Splits the file into tensors.
    private static func parse(_ data: Data) throws -> [BeatNetTensor] {
        var offset = 0
        func readUInt32() throws -> Int {
            guard offset + 4 <= data.count else { throw BeatNetWeightsError.malformed("truncated header") }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            offset += 4
            return Int(UInt32(littleEndian: value))
        }
        guard data.count >= 12, data.prefix(4) == Data("BNET".utf8) else {
            throw BeatNetWeightsError.malformed("missing BNET signature")
        }
        offset = 4
        let version = try readUInt32()
        guard version == 1 else { throw BeatNetWeightsError.malformed("version \(version), expected 1") }
        let count = try readUInt32()
        var tensors: [BeatNetTensor] = []
        for _ in 0..<count {
            let rank = try readUInt32()
            guard (1...4).contains(rank) else { throw BeatNetWeightsError.malformed("rank \(rank)") }
            var shape: [Int] = []
            for _ in 0..<rank { shape.append(try readUInt32()) }
            let elements = shape.reduce(1, *)
            let byteCount = elements * 4
            guard offset + byteCount <= data.count else {
                throw BeatNetWeightsError.malformed("truncated tensor \(shape)")
            }
            var values = [Float](repeating: 0, count: elements)
            _ = values.withUnsafeMutableBytes { destination in
                data.copyBytes(to: destination, from: offset..<(offset + byteCount))
            }
            offset += byteCount
            tensors.append(BeatNetTensor(shape: shape, values: values))
        }
        guard offset == data.count else { throw BeatNetWeightsError.malformed("trailing bytes") }
        return tensors
    }
}
