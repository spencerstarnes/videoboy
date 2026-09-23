//
//  GLSLTokenizer.swift — splits GLSL into tokens without losing a single character.
//
//  Purpose : The ISF → Metal converter makes a handful of small, local rewrites
//            (`inout vec2 p` → `thread vec2& p`, `float[3](…)` → `{…}`). Doing those
//            on raw text with search-and-replace would also rewrite matching text
//            inside comments and inside longer names. Doing them on tokens does not.
//  Inputs  : GLSL source text.
//  Outputs : `[GLSLToken]`. Joining every token's `text` gives back the input exactly,
//            byte for byte. That property is what keeps line numbers right, and it
//            is unit-tested.
//  Connects: ISFMetalGenerator, the only caller.
//  Extend  : this is deliberately NOT a parser. It knows what a word, a number, a
//            comment and a preprocessor line look like, and nothing about grammar.
//            Metal's own compiler does the parsing. Keep it that way.
//

import Foundation

/// What kind of text a token is.
public enum GLSLTokenKind: Equatable, Sendable {
    /// A name or keyword: `vec2`, `main`, `inout`, `gl_FragColor`.
    case identifier
    /// A numeric literal: `1`, `0.5`, `1e-3`, `2.0f`, `0x1F`.
    case number
    /// Spaces, tabs and newlines.
    case whitespace
    /// A `//` or `/* */` comment.
    case comment
    /// A whole `#…` line, including any backslash continuations.
    case preprocessor
    /// Any other character or operator: `(`, `{`, `;`, `+=`, `.`.
    case symbol
}

/// One token and the exact text it came from.
public struct GLSLToken: Equatable, Sendable {
    public var kind: GLSLTokenKind
    public var text: String

    public init(_ kind: GLSLTokenKind, _ text: String) {
        self.kind = kind
        self.text = text
    }

    /// True for tokens the grammar ignores (whitespace and comments).
    public var isTrivia: Bool { kind == .whitespace || kind == .comment }

    /// Number of line breaks inside this token.
    public var newlineCount: Int { text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 } }
}

/// Turns GLSL text into tokens.
public enum GLSLTokenizer {

    /// Multi-character operators, longest first so `<<=` wins over `<<`.
    private static let operators: [String] = [
        "<<=", ">>=", "++", "--", "<<", ">>", "<=", ">=", "==", "!=", "&&", "||", "^^",
        "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^="
    ]

    /// Splits `source` into tokens. Never fails: anything unrecognised becomes a
    /// one-character symbol and is left for Metal's compiler to complain about.
    public static func tokenize(_ source: String) -> [GLSLToken] {
        let characters = Array(source.unicodeScalars)
        var tokens: [GLSLToken] = []
        var index = 0
        // A preprocessor directive is only a directive at the start of a line.
        var atLineStart = true

        func text(_ start: Int, _ end: Int) -> String {
            var result = String.UnicodeScalarView()
            result.append(contentsOf: characters[start..<end])
            return String(result)
        }

        while index < characters.count {
            let start = index
            let character = characters[index]
            let next: Unicode.Scalar? = index + 1 < characters.count ? characters[index + 1] : nil

            if character == " " || character == "\t" || character == "\n" || character == "\r" {
                while index < characters.count,
                      [" ", "\t", "\n", "\r"].contains(characters[index]) {
                    if characters[index] == "\n" { atLineStart = true }
                    index += 1
                }
                tokens.append(GLSLToken(.whitespace, text(start, index)))
                continue
            }

            if character == "#" && atLineStart {
                // To the end of the line, following `\` continuations.
                while index < characters.count, characters[index] != "\n" {
                    if characters[index] == "\\", index + 1 < characters.count,
                       characters[index + 1] == "\n" {
                        index += 2
                        continue
                    }
                    index += 1
                }
                tokens.append(GLSLToken(.preprocessor, text(start, index)))
                continue
            }
            atLineStart = false

            if character == "/" && next == "/" {
                while index < characters.count, characters[index] != "\n" { index += 1 }
                tokens.append(GLSLToken(.comment, text(start, index)))
                continue
            }
            if character == "/" && next == "*" {
                index += 2
                while index < characters.count {
                    if characters[index] == "*", index + 1 < characters.count,
                       characters[index + 1] == "/" {
                        index += 2
                        break
                    }
                    index += 1
                }
                tokens.append(GLSLToken(.comment, text(start, index)))
                continue
            }

            if isIdentifierStart(character) {
                while index < characters.count, isIdentifierBody(characters[index]) { index += 1 }
                tokens.append(GLSLToken(.identifier, text(start, index)))
                continue
            }

            if isDigit(character) || (character == "." && next.map(isDigit) == true) {
                index = endOfNumber(characters, from: index)
                tokens.append(GLSLToken(.number, text(start, index)))
                continue
            }

            // Operators: longest match first.
            var matched = false
            for op in operators {
                let length = op.unicodeScalars.count
                if index + length <= characters.count, text(index, index + length) == op {
                    index += length
                    tokens.append(GLSLToken(.symbol, op))
                    matched = true
                    break
                }
            }
            if matched { continue }

            index += 1
            tokens.append(GLSLToken(.symbol, text(start, index)))
        }
        return tokens
    }

    /// Joins tokens back into text. The inverse of `tokenize`.
    public static func join(_ tokens: [GLSLToken]) -> String {
        tokens.map(\.text).joined()
    }

    // MARK: - Character classes

    private static func isDigit(_ c: Unicode.Scalar) -> Bool { c >= "0" && c <= "9" }

    private static func isIdentifierStart(_ c: Unicode.Scalar) -> Bool {
        (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || c == "_"
    }

    private static func isIdentifierBody(_ c: Unicode.Scalar) -> Bool {
        isIdentifierStart(c) || isDigit(c)
    }

    /// Consumes a numeric literal: hex, decimal, fraction, exponent and suffix.
    private static func endOfNumber(_ characters: [Unicode.Scalar], from start: Int) -> Int {
        var index = start
        func at(_ i: Int) -> Unicode.Scalar? { i < characters.count ? characters[i] : nil }

        if at(index) == "0", let x = at(index + 1), x == "x" || x == "X" {
            index += 2
            while let c = at(index), isDigit(c) || ("a"..."f").contains(c) || ("A"..."F").contains(c) {
                index += 1
            }
        } else {
            while let c = at(index), isDigit(c) { index += 1 }
            if at(index) == "." {
                index += 1
                while let c = at(index), isDigit(c) { index += 1 }
            }
            if let e = at(index), e == "e" || e == "E" {
                var look = index + 1
                if let sign = at(look), sign == "+" || sign == "-" { look += 1 }
                if let c = at(look), isDigit(c) {
                    index = look
                    while let c = at(index), isDigit(c) { index += 1 }
                }
            }
        }
        // Suffixes: f, F, u, U, lf, LF.
        while let c = at(index), "fFuUlL".unicodeScalars.contains(c) { index += 1 }
        return index
    }
}
