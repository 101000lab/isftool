/// Maps line numbers in the generated fragment GLSL back to the original .fs.
///
/// ISFGLSLGenerator appends the shader body last, and its IMG_* rewrites stay on one line,
/// so the body keeps its line count and one constant offset covers the whole body.
/// A multi-line IMG_* call is collapsed by its lexer, which shifts later lines; that case is not corrected.
public struct LineMap: Equatable, Sendable {
    /// 1-based line in the .fs where the body (after the metadata comment) starts.
    public var sourceBodyStart: Int
    /// 1-based line in the generated GLSL where the same body starts.
    public var generatedBodyStart: Int

    public init(sourceBodyStart: Int, generatedBodyStart: Int) {
        self.sourceBodyStart = sourceBodyStart
        self.generatedBodyStart = generatedBodyStart
    }

    public init(jsonSource: String, body: String, generated: String) {
        sourceBodyStart = Self.newlineCount(jsonSource) + 1
        generatedBodyStart = Self.newlineCount(generated) - Self.newlineCount(body) + 1
    }

    /// Returns nil for lines in the generated preamble, which have no counterpart in the .fs.
    public func sourceLine(forGenerated line: Int) -> Int? {
        guard line >= generatedBodyStart else { return nil }
        return line - generatedBodyStart + sourceBodyStart
    }

    static func newlineCount(_ s: String) -> Int {
        s.utf8.reduce(0) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }
    }
}
