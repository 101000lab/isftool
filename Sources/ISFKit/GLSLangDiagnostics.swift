import Foundation

public struct GLSLDiagnostic: Codable, Equatable, Sendable {
    public var severity: String
    /// Line in the generated GLSL, numbered the same way as VDMX's error screen.
    public var line: Int?
    /// Line in the original .fs, when the error falls inside the shader body.
    public var sourceLine: Int?
    public var message: String

    public init(severity: String, line: Int?, sourceLine: Int? = nil, message: String) {
        self.severity = severity
        self.line = line
        self.sourceLine = sourceLine
        self.message = message
    }
}

public enum GLSLangDiagnostics {
    nonisolated(unsafe) private static let locationPattern = try! Regex<(Substring, Substring, Substring)>(#"^[^:\s]*:(\d+): ?(.*)$"#)

    /// Parses glslang's log, for example `ERROR: stdin:3: '' :  syntax error, unexpected RIGHT_BRACE`.
    /// The summary line (`ERROR: 2 compilation errors.  No code generated.`) is skipped.
    public static func parse(_ log: String, lineMap: LineMap? = nil) -> [GLSLDiagnostic] {
        var result: [GLSLDiagnostic] = []
        for raw in log.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            guard let (severity, rest) = splitSeverity(line) else { continue }
            if rest.range(of: #"^\d+ compilation errors?\."#, options: .regularExpression) != nil {
                continue
            }
            if let m = rest.firstMatch(of: locationPattern), let generated = Int(m.output.1) {
                result.append(GLSLDiagnostic(
                    severity: severity,
                    line: generated,
                    sourceLine: lineMap?.sourceLine(forGenerated: generated),
                    message: String(m.output.2).trimmingCharacters(in: .whitespaces)
                ))
            } else {
                result.append(GLSLDiagnostic(severity: severity, line: nil, message: rest))
            }
        }
        return result
    }

    private static func splitSeverity(_ line: String) -> (String, String)? {
        for severity in ["ERROR", "WARNING"] where line.hasPrefix(severity + ": ") {
            return (severity.lowercased(), String(line.dropFirst(severity.count + 2)))
        }
        return nil
    }
}
