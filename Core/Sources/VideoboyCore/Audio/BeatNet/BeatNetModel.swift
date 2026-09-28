//
//  BeatNetModel.swift — BeatNet's network, run one frame at a time.
//
//  Purpose : For each 20 ms feature frame, how likely it is that a beat, or a
//            downbeat, falls on it. This is BeatNet's BDA network (model.py):
//            a small convolution, a linear layer, two stacked LSTM layers of 150
//            cells, and a softmax over {beat, downbeat, neither}. The LSTM carries
//            state from frame to frame, which is what lets it be causal and live.
//  Inputs  : 272-value feature frames from BeatNetFeatures, in order.
//  Outputs : `BeatNetActivation` per frame.
//  Connects: BeatNetTracker; weights from BeatNetWeights.
//  Extend  : the arithmetic must stay PyTorch's: LSTM gate order is input, forget,
//            cell, output, and both biases are added. BeatNetTests compares every
//            frame of a 12-second signal against PyTorch.
//

import Accelerate
import Foundation

/// The network's view of one frame.
public struct BeatNetActivation: Equatable, Sendable {
    /// Probability that a beat that is not a downbeat falls on this frame.
    public let beat: Float
    /// Probability that a downbeat falls on this frame.
    public let downbeat: Float

    /// Either kind of beat: what the beat tracker listens to.
    public var anyBeat: Float { max(beat, downbeat) }
}

/// The CRNN, with its LSTM state.
public final class BeatNetModel {

    private static let kernel = 10
    private static let convChannels = 2
    /// Convolution outputs per channel, before and after max-pooling by 2.
    private static let convLength = BeatNetFeatures.featureSize - kernel + 1   // 263
    private static let pooledLength = convLength / 2                             // 131
    private static let hidden = 150

    private let weights: BeatNetWeights

    /// LSTM hidden and cell state per layer.
    private var hiddenState: [[Float]]
    private var cellState: [[Float]]

    // Scratch.
    private var pooled = [Float](repeating: 0, count: convChannels * pooledLength)
    private var projected = [Float](repeating: 0, count: hidden)
    private var gates = [Float](repeating: 0, count: 4 * hidden)
    private var gatesFromHidden = [Float](repeating: 0, count: 4 * hidden)

    public init(weights: BeatNetWeights) {
        self.weights = weights
        hiddenState = Array(repeating: [Float](repeating: 0, count: Self.hidden), count: 2)
        cellState = hiddenState
    }

    /// Zeroes the LSTM state, as a new stream would start.
    public func reset() {
        for layer in 0..<2 {
            hiddenState[layer] = [Float](repeating: 0, count: Self.hidden)
            cellState[layer] = [Float](repeating: 0, count: Self.hidden)
        }
    }

    /// Runs one frame.
    public func process(_ features: [Float]) -> BeatNetActivation {
        precondition(features.count == BeatNetFeatures.featureSize, "BeatNet feature frame size")

        // Conv1d(1→2, k=10), ReLU, max-pool 2. Flattened channel by channel.
        let convWeight = weights.convWeight.values, convBias = weights.convBias.values
        for channel in 0..<Self.convChannels {
            for pooledIndex in 0..<Self.pooledLength {
                var best = -Float.infinity
                for position in (pooledIndex * 2)...(pooledIndex * 2 + 1) {
                    var sum = convBias[channel]
                    for tap in 0..<Self.kernel {
                        sum += convWeight[channel * Self.kernel + tap] * features[position + tap]
                    }
                    best = max(best, max(sum, 0))
                }
                pooled[channel * Self.pooledLength + pooledIndex] = best
            }
        }

        // linear0 (262→150), no activation.
        matrixVector(weights.linear0Weight, pooled, bias: weights.linear0Bias.values, into: &projected)

        // Two LSTM layers.
        var input = projected
        for layer in 0..<2 {
            let parameters = weights.lstm[layer]
            matrixVector(parameters.inputWeight, input, bias: parameters.inputBias.values, into: &gates)
            matrixVector(parameters.hiddenWeight, hiddenState[layer],
                         bias: parameters.hiddenBias.values, into: &gatesFromHidden)
            vDSP_vadd(gates, 1, gatesFromHidden, 1, &gates, 1, vDSP_Length(gates.count))
            let size = Self.hidden
            for cell in 0..<size {
                let inputGate = sigmoid(gates[cell])
                let forgetGate = sigmoid(gates[size + cell])
                let candidate = tanh(gates[2 * size + cell])
                let outputGate = sigmoid(gates[3 * size + cell])
                let newCell = forgetGate * cellState[layer][cell] + inputGate * candidate
                cellState[layer][cell] = newCell
                hiddenState[layer][cell] = outputGate * tanh(newCell)
            }
            input = hiddenState[layer]
        }

        // Output layer and softmax over {beat, downbeat, neither}.
        var logits = [Float](repeating: 0, count: 3)
        matrixVector(weights.outputWeight, input, bias: weights.outputBias.values, into: &logits)
        let peak = logits.max() ?? 0
        let exponentials = logits.map { exp($0 - peak) }
        let total = exponentials.reduce(0, +)
        return BeatNetActivation(beat: exponentials[0] / total, downbeat: exponentials[1] / total)
    }

    /// `output = matrix · vector + bias`, with the matrix rows × columns row-major.
    private func matrixVector(_ matrix: BeatNetTensor, _ vector: [Float], bias: [Float],
                              into output: inout [Float]) {
        let rows = matrix.shape[0], columns = matrix.shape[1]
        vDSP_mmul(matrix.values, 1, vector, 1, &output, 1,
                  vDSP_Length(rows), 1, vDSP_Length(columns))
        vDSP_vadd(output, 1, bias, 1, &output, 1, vDSP_Length(rows))
    }

    private func sigmoid(_ value: Float) -> Float { 1 / (1 + exp(-value)) }
}
