//
//  SeededRandom.swift — a small, explicit, reproducible random source.
//
//  Purpose : The corruptor must be deterministic: the same seed and the same input
//            must give the same output, so a check is repeatable and a performance
//            can be replayed. Swift's `SystemRandomNumberGenerator` cannot be seeded,
//            so this is the generator the wedge uses.
//  Inputs  : a 64-bit seed.
//  Outputs : a `RandomNumberGenerator`.
//  Connects: DIFCorruptor, and any other module that needs repeatable randomness.
//  Extend  : do not swap the algorithm. Changing it would silently change every
//            saved performance that depends on a seed.
//
//  Algorithm: SplitMix64. Chosen because it is tiny, has no hidden state beyond one
//  UInt64, passes the usual statistical tests, and is trivially portable — which
//  matters more here than raw speed.
//

import Foundation

/// A seedable, reproducible random number generator.
public struct SeededRandom: RandomNumberGenerator {

    private var state: UInt64

    /// - Parameter seed: any value. The same seed always yields the same sequence.
    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        // SplitMix64. The constants are from the reference implementation and are
        // not tunable — they are chosen for their avalanche properties.
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A value in `0..<upperBound`. Returns 0 when the bound is not positive.
    public mutating func next(below upperBound: Int) -> Int {
        guard upperBound > 0 else { return 0 }
        return Int(next() % UInt64(upperBound))
    }

    /// A value in 0...1.
    public mutating func nextUnitValue() -> Double {
        // 53 bits is the mantissa width of a Double, so this uses every bit that
        // can affect the result and no more.
        Double(next() >> 11) / Double(1 << 53)
    }
}
