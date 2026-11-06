import CryptoKit
import Foundation
import Metal

/// One line of `.isftool/results.jsonl` (design 7.5).
public struct BenchResult: Codable, Equatable, Sendable {
    public struct Git: Codable, Equatable, Sendable {
        public var commit: String
        public var dirty: Bool
    }

    public struct CompileTimes: Codable, Equatable, Sendable {
        public var glsl: Double
        public var spirv_cross: Double
        public var metal: Double

        public init(glsl: Double, spirv_cross: Double, metal: Double) {
            self.glsl = glsl
            self.spirv_cross = spirv_cross
            self.metal = metal
        }
    }

    public var at: String
    /// The path as given on the command line, so lists from `--from` compare with earlier runs of the same list.
    public var shader: String
    public var sha256: String
    public var git: Git?
    public var size: [Int]
    public var fps: Double
    public var mode: FeedMode
    public var warmup: Int
    public var frames: Int
    public var `repeat`: Int
    public var ms: Stats
    /// The median of each repeat, present when `repeat` is more than 1.
    public var repeats: [Double]?
    public var passes: Int
    public var compile_ms: CompileTimes
    public var device: String
    public var isftool: String

    public init(at: String, shader: String, sha256: String, git: Git?, size: [Int], fps: Double, mode: FeedMode, warmup: Int, frames: Int, repeat: Int, ms: Stats, repeats: [Double]?, passes: Int, compile_ms: CompileTimes, device: String, isftool: String) {
        self.at = at
        self.shader = shader
        self.sha256 = sha256
        self.git = git
        self.size = size
        self.fps = fps
        self.mode = mode
        self.warmup = warmup
        self.frames = frames
        self.repeat = `repeat`
        self.ms = ms
        self.repeats = repeats
        self.passes = passes
        self.compile_ms = compile_ms
        self.device = device
        self.isftool = isftool
    }
}

/// A shader that could not be measured, for the table and `--json`. It never goes into the results file.
public struct BenchFailure: Codable, Equatable, Sendable {
    public var shader: String
    public var error: String

    public init(shader: String, error: String) {
        self.shader = shader
        self.error = error
    }
}

public enum GitInfo {
    /// The commit and whether the repository holding `path` has uncommitted changes, or nil outside a repository.
    public static func of(path: String, runner: CommandRunner = ProcessRunner()) -> BenchResult.Git? {
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard let head = try? runner.run("/usr/bin/git", ["-C", dir, "rev-parse", "--short", "HEAD"], stdin: nil), head.status == 0,
              let status = try? runner.run("/usr/bin/git", ["-C", dir, "status", "--porcelain"], stdin: nil), status.status == 0
        else { return nil }
        return BenchResult.Git(commit: head.stdout.trimmingCharacters(in: .whitespacesAndNewlines), dirty: !status.stdout.isEmpty)
    }
}

/// Appends results and finds the previous run to compare with.
public struct ResultsStore {
    public var url: URL

    public init(path: String) {
        url = URL(fileURLWithPath: path)
    }

    public func load() -> [BenchResult] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        // Lines from other isftool versions that no longer decode are skipped rather than failing the run.
        return text.split(whereSeparator: \.isNewline).compactMap { try? decoder.decode(BenchResult.self, from: Data($0.utf8)) }
    }

    public func append(_ result: BenchResult) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(result)
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: url)
        }
    }

    /// The latest earlier result for the same shader, size, mode and frame count.
    public static func previous(of result: BenchResult, in history: [BenchResult]) -> BenchResult? {
        history.last { $0.shader == result.shader && $0.size == result.size && $0.mode == result.mode && $0.frames == result.frames }
    }
}

public struct BenchOptions: Sendable {
    public var size: RenderSize
    public var fps: Double
    public var warmup: Int
    public var frames: Int
    public var repeats: Int

    public init(size: RenderSize, fps: Double = 60, warmup: Int = 60, frames: Int = 240, repeats: Int = 1) {
        self.size = size
        self.fps = fps
        self.warmup = warmup
        self.frames = frames
        self.repeats = repeats
    }
}

public enum BenchRunner {
    /// GPU milliseconds of each measured frame.
    ///
    /// Each frame is its own command buffer, committed and waited for, so the GPU idles between frames
    /// and the numbers run a little high. The clock runs on through warmup into the measured frames.
    public static func measure(renderer: Renderer, driver: InputDriver, options: BenchOptions) throws -> [Double] {
        guard let queue = renderer.device.makeCommandQueue() else { throw RenderError(description: "cannot create a command queue") }
        var times: [Double] = []
        let date = FrameInfo.localDate()
        for i in 0..<(options.warmup + options.frames) {
            let frame = FrameInfo.at(frame: i, fps: options.fps, renderSize: options.size, date: date)
            let values = driver.values(at: Double(frame.time))
            guard let commandBuffer = queue.makeCommandBuffer() else { throw RenderError(description: "cannot create a command buffer") }
            _ = try renderer.encode(frame: frame, values: values, into: commandBuffer)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            if let error = commandBuffer.error { throw RenderError(description: "GPU error: \(error.localizedDescription)") }
            guard i >= options.warmup else { continue }
            // gpuStartTime and gpuEndTime are seconds, and only meaningful once the buffer has completed.
            times.append((commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000)
        }
        return times
    }

    /// Measures `options.repeats` times. Every repeat starts from frame 0 with a fresh renderer, so all of them
    /// draw the same frames and differ only by measurement noise, not by what the shader shows at a later time.
    public static func measure(makeRenderer: () throws -> Renderer, driver: InputDriver, options: BenchOptions, spinUp: Double = 0.5) throws -> [[Double]] {
        try spin(renderer: try makeRenderer(), driver: driver, options: options, seconds: spinUp)
        return try (0..<options.repeats).map { _ in try measure(renderer: try makeRenderer(), driver: driver, options: options) }
    }

    /// Keeps the GPU busy for a while on a renderer that is thrown away. The GPU lowers its clock while check runs
    /// glslang and SPIRV-Cross, and a light shader's warmup frames alone are too short to bring it back up,
    /// so without this the first repeat of a light shader came out about twice as slow as the next ones.
    static func spin(renderer: Renderer, driver: InputDriver, options: BenchOptions, seconds: Double) throws {
        guard seconds > 0, let queue = renderer.device.makeCommandQueue() else { return }
        let end = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
        var i = 0
        while DispatchTime.now().uptimeNanoseconds < end {
            let frame = FrameInfo.at(frame: i, fps: options.fps, renderSize: options.size)
            guard let commandBuffer = queue.makeCommandBuffer() else { return }
            _ = try renderer.encode(frame: frame, values: driver.values(at: Double(frame.time)), into: commandBuffer)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            i += 1
        }
    }

    public static func sha256(ofFile path: String) -> String {
        guard let data = FileManager.default.contents(atPath: path) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func iso8601(_ date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}

public struct BenchRow: Sendable {
    public var shader: String
    public var mode: String
    public var result: BenchResult?
    public var previous: BenchResult?
    public var note: String

    public init(shader: String, mode: String, result: BenchResult? = nil, previous: BenchResult? = nil, note: String = "") {
        self.shader = shader
        self.mode = mode
        self.result = result
        self.previous = previous
        self.note = note
    }

    /// Percent change of the median from the previous run.
    public var change: Double? {
        guard let now = result?.ms.median, let before = previous?.ms.median, before > 0 else { return nil }
        return (now - before) / before * 100
    }
}

public enum BenchFormatter {
    /// 120 fps and 60 fps frame budgets. They only flag outliers, VDMX's own fps also includes compositing and output.
    public static let budgets: (warn: Double, over: Double) = (1000.0 / 120, 1000.0 / 60)

    public static func format(_ rows: [BenchRow], compare: Bool) -> String {
        let anyRepeat = rows.contains { ($0.result?.repeats?.count ?? 0) > 1 }
        var header = ["", "shader", "mode", "median", "p95", "passes"]
        if anyRepeat { header.append("spread") }
        if compare { header.append("vs prev") }
        header.append("note")
        var table = [header]
        for r in rows {
            var cells: [String]
            if let res = r.result {
                let mark = res.ms.median > budgets.over ? "!!" : res.ms.median > budgets.warn ? "!" : ""
                cells = [mark, r.shader, r.mode, ms(res.ms.median), ms(res.ms.p95), String(res.passes)]
                if anyRepeat {
                    if let reps = res.repeats, reps.count > 1, let lo = reps.min(), let hi = reps.max(), res.ms.median > 0 {
                        cells.append(String(format: "%.1f%%", (hi - lo) / res.ms.median * 100))
                    } else {
                        cells.append("")
                    }
                }
                if compare { cells.append(r.change.map { String(format: "%+.1f%%", $0) } ?? "") }
            } else {
                cells = ["", r.shader, r.mode, "-", "-", "-"]
                if anyRepeat { cells.append("") }
                if compare { cells.append("") }
            }
            cells.append(r.note)
            table.append(cells)
        }
        let widths = (0..<header.count).map { c in table.map { $0[c].count }.max() ?? 0 }
        let numeric: Set<String> = ["median", "p95", "passes", "spread", "vs prev"]
        return table.map { cells in
            zip(cells, zip(widths, header)).map { cell, wh in
                let pad = String(repeating: " ", count: wh.0 - cell.count)
                return numeric.contains(wh.1) ? pad + cell : cell + pad
            }.joined(separator: "  ").replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }.joined(separator: "\n") + "\n\n! over \(ms(budgets.warn)) ms (120 fps), !! over \(ms(budgets.over)) ms (60 fps). GPU time of this shader alone, for ranking and before/after comparison."
    }

    static func ms(_ v: Double) -> String { String(format: "%.2f", v) }

    /// What the numbers leave out for this shader.
    public static func notes(for document: ISFDocumentInfo) -> [String] {
        var notes: [String] = []
        if document.inputs.contains(where: { $0.type == "Audio" || $0.type == "AudioFFT" }) { notes.append("audio: blank texture") }
        if document.inputs.contains(where: { $0.type == "Image" }) { notes.append("image input: blank texture") }
        return notes
    }
}
