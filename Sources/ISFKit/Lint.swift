import Foundation

public struct LintViolation: Codable, Equatable, Sendable {
    public var identifier: String
    /// 1-based line in the .fs, nil when the name only comes from metadata that could not be located.
    public var line: Int?
    public var column: Int?
    public var message: String

    public init(identifier: String, line: Int?, column: Int?, message: String) {
        self.identifier = identifier
        self.line = line
        self.column = column
        self.message = message
    }
}

/// Finds identifiers that are Metal keywords. SPIRV-Cross renames some of them silently,
/// but VDMX failed on `vertex` (super_polygons), so they are reported as errors regardless of what the local toolchain does.
/// `visible` is left out because VDMX loads shaders that use it (structure, ridge_lines).
/// `level` is left out too. VDMX fails on it, but the Metal stage already reports the same error.
public enum Lint {
    public static let metalReservedWords: Set<String> = [
        "vertex", "fragment", "kernel", "device", "constant", "thread", "threadgroup",
        "threadgroup_imageblock", "half", "ray_data", "object", "mesh", "stage_in",
    ]

    /// - Parameters:
    ///   - source: The whole .fs, metadata comment included, so reported lines match the file.
    ///   - declaredNames: Input, IMPORTED and pass TARGET names. They become GLSL identifiers although they only appear inside the metadata comment.
    public static func scan(source: String, declaredNames: [String] = [], reserved: Set<String> = metalReservedWords) -> [LintViolation] {
        var result: [LintViolation] = []
        var seen = Set<String>()
        for token in identifiers(in: stripComments(source)) where reserved.contains(token.text) {
            let key = "\(token.text):\(token.line)"
            if seen.insert(key).inserted {
                result.append(LintViolation(identifier: token.text, line: token.line, column: token.column, message: "'\(token.text)' is a Metal keyword"))
            }
        }
        for name in declaredNames where reserved.contains(name) {
            let location = locateQuoted(name, in: source)
            result.append(LintViolation(identifier: name, line: location?.line, column: location?.column, message: "ISF name '\(name)' is a Metal keyword"))
        }
        return result.sorted { ($0.line ?? 0, $0.column ?? 0) < ($1.line ?? 0, $1.column ?? 0) }
    }

    struct Token: Equatable {
        var text: String
        var line: Int
        var column: Int
    }

    /// Replaces comments with spaces, keeping line breaks so positions stay valid.
    static func stripComments(_ source: String) -> String {
        var out: [Character] = []
        out.reserveCapacity(source.count)
        let chars = Array(source)
        var i = 0
        while i < chars.count {
            if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" {
                    out.append(" ")
                    i += 1
                }
            } else if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                out.append(" ")
                out.append(" ")
                i += 2
                while i < chars.count, !(chars[i] == "*" && i + 1 < chars.count && chars[i + 1] == "/") {
                    out.append(chars[i] == "\n" ? "\n" : " ")
                    i += 1
                }
                if i < chars.count {
                    out.append(" ")
                    out.append(" ")
                    i += 2
                }
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return String(out)
    }

    static func identifiers(in source: String) -> [Token] {
        var tokens: [Token] = []
        var line = 1
        var column = 1
        var current = ""
        var startColumn = 0
        func flush() {
            if !current.isEmpty, !(current.first!.isNumber) {
                tokens.append(Token(text: current, line: line, column: startColumn))
            }
            current = ""
        }
        for ch in source {
            if ch == "_" || (ch.isASCII && (ch.isLetter || ch.isNumber)) {
                if current.isEmpty { startColumn = column }
                current.append(ch)
            } else {
                flush()
            }
            if ch == "\n" {
                line += 1
                column = 1
            } else {
                column += 1
            }
        }
        flush()
        return tokens
    }

    static func locateQuoted(_ name: String, in source: String) -> (line: Int, column: Int)? {
        guard let range = source.range(of: "\"\(name)\"") else { return nil }
        let prefix = source[..<range.lowerBound]
        let line = prefix.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        let column = prefix.distance(from: prefix.lastIndex(of: "\n").map { prefix.index(after: $0) } ?? prefix.startIndex, to: prefix.endIndex) + 2
        return (line, column)
    }
}
