import Foundation

/// Which frames `render` draws and which it writes out.
///
/// Drawing always starts at frame 0, even when only a later frame is written, because persistent buffers
/// hold what every earlier frame left in them.
public struct RenderPlan: Equatable, Sendable {
    /// The first frame written.
    public var start: Int
    /// How many frames are written.
    public var count: Int

    public init(at seconds: Double, fps: Double, frames: Int) {
        start = Int((seconds * fps).rounded())
        count = frames
    }

    public var drawn: Range<Int> { 0..<(start + count) }
    public var written: Range<Int> { start..<(start + count) }

    /// One frame to a `.png` path is written to that file. Otherwise `out` is a directory of `<stem>_<frame>.png`.
    public func outputPaths(out: String, shader: String) throws -> [URL] {
        let isFile = out.lowercased().hasSuffix(".png")
        if isFile {
            guard count == 1 else { throw RenderError(description: "--out \(out) is a file, but \(count) frames were asked for. Give a directory.") }
            return [URL(fileURLWithPath: out)]
        }
        let stem = URL(fileURLWithPath: shader).deletingPathExtension().lastPathComponent
        let dir = URL(fileURLWithPath: out, isDirectory: true)
        return written.map { dir.appendingPathComponent(String(format: "%@_%05d.png", stem, $0)) }
    }
}
