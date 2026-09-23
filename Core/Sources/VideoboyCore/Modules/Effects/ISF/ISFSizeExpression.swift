//
//  ISFSizeExpression.swift — the arithmetic in a pass's WIDTH / HEIGHT.
//
//  Purpose : ISF lets a pass render at a size written as an expression, e.g.
//            `"$WIDTH/4"` or `"max($HEIGHT*blurAmount, 1.0)"`. This parses such an
//            expression ONCE, when a program is installed, and evaluates the parsed
//            tree each frame — so there is no string handling on the render path.
//  Inputs  : the expression text; at evaluation, a lookup for `$NAME` variables.
//  Outputs : a number (the caller rounds and clamps it to a legal texture size).
//  Connects: ISFNode.
//  Extend  : a new function is one case in `call(_:_:)`.
//
//  Grammar (deliberately small):
//    expression := term (("+" | "-") term)*
//    term       := unary (("*" | "/") unary)*
//    unary      := "-" unary | primary
//    primary    := number | "$" name | name "(" args ")" | "(" expression ")"
//

import Foundation

/// A parsed size expression.
public indirect enum ISFSizeExpression: Equatable, Sendable {
    case number(Double)
    /// `$WIDTH`, `$HEIGHT`, or `$inputName`.
    case variable(String)
    case negate(ISFSizeExpression)
    case binary(Character, ISFSizeExpression, ISFSizeExpression)
    case call(String, [ISFSizeExpression])

    /// Parses `text`, or returns nil when it is not a valid expression — the caller
    /// then falls back to the full render size and logs why.
    public static func parse(_ text: String) -> ISFSizeExpression? {
        var parser = Parser(characters: Array(text))
        guard let result = parser.expression() else { return nil }
        parser.skipSpaces()
        return parser.position == parser.characters.count ? result : nil
    }

    /// Evaluates with `lookup` supplying variables (without the `$`). An unknown
    /// variable evaluates to 0, which the caller's clamp turns into a 1-pixel pass.
    public func evaluate(_ lookup: (String) -> Double?) -> Double {
        switch self {
        case .number(let value):
            return value
        case .variable(let name):
            return lookup(name) ?? 0
        case .negate(let inner):
            return -inner.evaluate(lookup)
        case .binary(let op, let left, let right):
            let a = left.evaluate(lookup)
            let b = right.evaluate(lookup)
            switch op {
            case "+": return a + b
            case "-": return a - b
            case "*": return a * b
            default: return b == 0 ? 0 : a / b
            }
        case .call(let name, let arguments):
            return ISFSizeExpression.call(name, arguments.map { $0.evaluate(lookup) })
        }
    }

    private static func call(_ name: String, _ values: [Double]) -> Double {
        switch (name, values.count) {
        case ("max", 2): return max(values[0], values[1])
        case ("min", 2): return min(values[0], values[1])
        case ("floor", 1): return values[0].rounded(.down)
        case ("ceil", 1): return values[0].rounded(.up)
        case ("round", 1): return values[0].rounded()
        case ("abs", 1): return abs(values[0])
        default: return 0
        }
    }

    // MARK: - Parser

    private struct Parser {
        let characters: [Character]
        var position = 0

        mutating func skipSpaces() {
            while position < characters.count, characters[position].isWhitespace { position += 1 }
        }

        mutating func peek() -> Character? {
            skipSpaces()
            return position < characters.count ? characters[position] : nil
        }

        mutating func expression() -> ISFSizeExpression? {
            guard var left = term() else { return nil }
            while let op = peek(), op == "+" || op == "-" {
                position += 1
                guard let right = term() else { return nil }
                left = .binary(op, left, right)
            }
            return left
        }

        mutating func term() -> ISFSizeExpression? {
            guard var left = unary() else { return nil }
            while let op = peek(), op == "*" || op == "/" {
                position += 1
                guard let right = unary() else { return nil }
                left = .binary(op, left, right)
            }
            return left
        }

        mutating func unary() -> ISFSizeExpression? {
            if peek() == "-" {
                position += 1
                return unary().map { .negate($0) }
            }
            return primary()
        }

        mutating func primary() -> ISFSizeExpression? {
            guard let character = peek() else { return nil }
            if character == "(" {
                position += 1
                let inner = expression()
                guard peek() == ")" else { return nil }
                position += 1
                return inner
            }
            if character == "$" {
                position += 1
                let name = identifier()
                return name.isEmpty ? nil : .variable(name)
            }
            if character.isNumber || character == "." {
                let start = position
                while position < characters.count,
                      characters[position].isNumber || characters[position] == "." {
                    position += 1
                }
                return Double(String(characters[start..<position])).map { .number($0) }
            }
            if character.isLetter {
                let name = identifier()
                guard peek() == "(" else { return nil }
                position += 1
                var arguments: [ISFSizeExpression] = []
                if peek() != ")" {
                    while true {
                        guard let argument = expression() else { return nil }
                        arguments.append(argument)
                        if peek() == "," { position += 1; continue }
                        break
                    }
                }
                guard peek() == ")" else { return nil }
                position += 1
                return .call(name, arguments)
            }
            return nil
        }

        mutating func identifier() -> String {
            let start = position
            while position < characters.count,
                  characters[position].isLetter || characters[position].isNumber || characters[position] == "_" {
                position += 1
            }
            return String(characters[start..<position])
        }
    }
}
