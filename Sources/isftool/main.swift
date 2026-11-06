import ArgumentParser
import Foundation
import ISFKit

let isftoolVersion = "0.1.0"

struct IsfTool: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "isftool",
        abstract: "Check, render and benchmark ISF shaders through the same GLSL to SPIR-V to Metal path as VDMX.",
        version: "\(isftoolVersion) (\(LinkedToolchain.versionSummary))",
        subcommands: [Check.self, Render.self, Bench.self, Info.self, Dump.self]
    )
}

struct ToolOptions: ParsableArguments {
    @Option(name: .customLong("keep-intermediates"), help: "Keep generated SPIR-V and MSL under this directory.")
    var keepIntermediates: String?

    func toolchain() throws -> Toolchain {
        LinkedToolchain()
    }

    /// Runs body with a work directory that is removed afterwards unless --keep-intermediates is set.
    func withWorkDirectory<T>(for shader: String, _ body: (URL) throws -> T) rethrows -> T {
        let name = URL(fileURLWithPath: shader).deletingPathExtension().lastPathComponent
        if let keep = keepIntermediates {
            let dir = URL(fileURLWithPath: keep).appendingPathComponent(name)
            return try body(dir)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("isftool-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        return try body(dir)
    }
}

struct FeedOptions: ParsableArguments {
    @Flag(name: .customLong("feed-envelope"), help: "Feed an envelope of VDMX's Audio Analysis into the Float inputs whose names match --feed-envelope-pattern.")
    var feedEnvelope = false

    @Option(name: .customLong("feed-envelope-pattern"), help: ArgumentHelp("Regular expression for the names of the inputs to feed. (default: \(FeedMatcher.defaultPattern))", valueName: "regex"))
    var feedEnvelopePattern: String?

    @Option(name: .customLong("set"), help: "Fix an input to a value, as NAME=VALUE. Color is r,g,b,a and Point2D is x,y. Repeatable. Applied after the envelope.")
    var assignments: [String] = []

    func validate() throws {
        if feedEnvelopePattern != nil && !feedEnvelope { throw ValidationError("--feed-envelope-pattern needs --feed-envelope") }
    }

    func matcher() throws -> FeedMatcher {
        do {
            return try FeedMatcher(pattern: feedEnvelopePattern ?? FeedMatcher.defaultPattern)
        } catch {
            throw ValidationError("invalid --feed-envelope-pattern: \(error.localizedDescription)")
        }
    }

    func driver(document: ISFDocumentInfo, mode: FeedMode, matcher: FeedMatcher) throws -> InputDriver {
        do {
            return try InputDriver(document: document, mode: mode, matcher: matcher, assignments: assignments)
        } catch {
            throw ValidationError("\(error)")
        }
    }
}


func parseSize(_ text: String) throws -> RenderSize {
    guard let size = RenderSize(parsing: text) else { throw ValidationError("invalid size '\(text)', expected WxH") }
    return size
}

struct Check: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Compile a shader to Metal and report where it fails.")

    @Argument(help: "ISF fragment shader (.fs).")
    var shader: String

    @OptionGroup var tools: ToolOptions

    @Flag(help: "Print JSON instead of text.")
    var json = false

    func run() throws {
        let checker = Checker(toolchain: try tools.toolchain(), metal: try MetalLibraryCompiler(), options: CheckOptions())
        let result = tools.withWorkDirectory(for: shader) { checker.check(path: shader, workDirectory: $0) }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(result.report), as: UTF8.self))
        } else {
            print(CheckFormatter.format(result))
        }
        if !result.report.ok {
            throw ExitCode.failure
        }
    }
}

struct Render: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Render frames of a shader to PNG.")

    @Argument(help: "ISF fragment shader (.fs).")
    var shader: String

    @Option(help: "Output PNG file for one frame, or a directory for several.")
    var out: String

    @Option(help: "Output size.")
    var size = "1920x1440"

    @Option(help: "Time of the first frame written, in seconds. Frames before it are drawn too, so persistent buffers fill up.")
    var at: Double = 0

    @Option(help: "Number of frames to write.")
    var frames = 1

    @Option(help: "Clock rate. TIME = i / fps, TIMEDELTA = 1 / fps, FRAMEINDEX = i.")
    var fps: Double = 60

    @OptionGroup var feedOptions: FeedOptions

    @OptionGroup var tools: ToolOptions

    func validate() throws {
        guard fps > 0 else { throw ValidationError("--fps must be positive") }
        guard at >= 0 else { throw ValidationError("--at must not be negative") }
        guard frames >= 1 else { throw ValidationError("--frames must be at least 1") }
    }

    func run() throws {
        let renderSize = try parseSize(size)
        // The renderer compiles the MSL itself, so check stops before Metal to avoid compiling twice.
        let checker = Checker(source: ISFGLSLGeneratorSource(renderSize: renderSize), toolchain: try tools.toolchain(), metal: nil, options: CheckOptions(metal: false))
        let result = tools.withWorkDirectory(for: shader) { checker.check(path: shader, workDirectory: $0) }
        guard result.report.ok, let document = result.artifacts.document else {
            print(CheckFormatter.format(result))
            throw ExitCode.failure
        }
        let driver = try feedOptions.driver(document: document, mode: feedOptions.feedEnvelope ? .envelope : .default, matcher: try feedOptions.matcher())
        let plan = RenderPlan(at: at, fps: fps, frames: frames)
        let paths: [URL]
        do {
            paths = try plan.outputPaths(out: out, shader: shader)
        } catch {
            throw ValidationError("\(error)")
        }
        do {
            let renderer = try Renderer(artifacts: result.artifacts, sizer: try ISFPassSizer(path: shader))
            let drawn = plan.drawn.map { FrameInfo.at(frame: $0, fps: fps, renderSize: renderSize, date: FrameInfo.localDate()) }
            try renderer.renderFrames(frames: drawn, values: { driver.values(at: Double($0.time)) }, capture: plan.drawn.map(plan.written.contains)) { n, image in
                let path = paths[n - plan.start]
                try PNGWriter.write(image, to: path)
                print("wrote \(path.path)  (\(image.width)x\(image.height), TIME \(drawn[n].time), FRAMEINDEX \(drawn[n].frameIndex))")
            }
        } catch {
            FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
            throw ExitCode.failure
        }
    }
}

struct Bench: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Measure the GPU time per frame of a shader, also with the envelope and at MAX when --feed-envelope is given.")

    @Argument(help: "ISF fragment shader (.fs).")
    var shader: String

    @Option(help: "Output size.")
    var size = "1920x1440"

    @Option(help: "Clock rate. TIME = i / fps, TIMEDELTA = 1 / fps, FRAMEINDEX = i.")
    var fps: Double = 60

    @OptionGroup var feedOptions: FeedOptions

    @Option(help: "Frames drawn before measuring, so persistent buffers fill up.")
    var warmup = 60

    @Option(help: "Frames measured per repeat.")
    var frames = 240

    @Option(help: "How many times to measure. The reported median is the median of each repeat's median.")
    var `repeat` = 1

    @Option(help: "Append results to this JSON Lines file.")
    var results = ".isftool/results.jsonl"

    @Flag(name: .customLong("no-compare"), help: "Leave out the change from the previous run.")
    var noCompare = false

    @Flag(help: "Print JSON instead of the table.")
    var json = false

    @OptionGroup var tools: ToolOptions

    func validate() throws {
        guard fps > 0 else { throw ValidationError("--fps must be positive") }
        guard warmup >= 0, frames >= 1, `repeat` >= 1 else { throw ValidationError("--warmup must be 0 or more, --frames and --repeat at least 1") }
    }

    func run() throws {
        let renderSize = try parseSize(size)
        let modes: [FeedMode] = feedOptions.feedEnvelope ? [.default, .envelope, .max] : [.default]
        let matcher = try feedOptions.matcher()
        let store = ResultsStore(path: results)
        let history = noCompare ? [] : store.load()
        let toolchain = try tools.toolchain()
        let options = BenchOptions(size: renderSize, fps: fps, warmup: warmup, frames: frames, repeats: `repeat`)
        let checker = Checker(source: ISFGLSLGeneratorSource(renderSize: renderSize), toolchain: toolchain, metal: nil, options: CheckOptions(metal: false))
        var rows: [BenchRow] = []
        var failures: [BenchFailure] = []
        var measured: [BenchResult] = []

        let path = shader
        func report() throws {
            if json {
                struct Output: Encodable { var results: [BenchResult]; var failures: [BenchFailure] }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                print(String(decoding: try encoder.encode(Output(results: measured, failures: failures)), as: UTF8.self))
            } else {
                print(BenchFormatter.format(rows, compare: !noCompare))
            }
            if !failures.isEmpty { throw ExitCode.failure }
        }
        func fail(_ message: String) {
            failures.append(BenchFailure(shader: path, error: message))
            rows.append(BenchRow(shader: path, mode: "-", note: message))
            if !json { FileHandle.standardError.write(Data("FAIL  \(path)  \(message)\n".utf8)) }
        }
        let check = tools.withWorkDirectory(for: path) { checker.check(path: path, workDirectory: $0) }
        guard check.report.ok, let document = check.artifacts.document else {
            fail("check failed at \(check.report.stage?.rawValue ?? "?"): \(check.report.error?.split(separator: "\n").first.map(String.init) ?? "")")
            return try report()
        }
        let notes = BenchFormatter.notes(for: document)
        let sha = BenchRunner.sha256(ofFile: path)
        let git = GitInfo.of(path: path)
        for mode in modes {
            do {
                let driver = try feedOptions.driver(document: document, mode: mode, matcher: matcher)
                // A fresh renderer per mode, so persistent buffers start black and warmup fills them again.
                var metalMs: Double?
                var device = ""
                let times = try BenchRunner.measure(makeRenderer: {
                    let start = DispatchTime.now()
                    let renderer = try Renderer(artifacts: check.artifacts, sizer: try ISFPassSizer(path: path))
                    // Only the first build counts. Later ones hit the OS's Metal cache and say nothing about VDMX.
                    if metalMs == nil { metalMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000 }
                    device = renderer.device.name
                    return renderer
                }, driver: driver, options: options)
                guard let stats = Stats(times.flatMap { $0 }) else { continue }
                var ms = stats
                var repeats: [Double]?
                if `repeat` > 1 {
                    repeats = times.map { Stats.median($0) }
                    ms.median = Stats.median(repeats!)
                }
                let result = BenchResult(
                    at: BenchRunner.iso8601(), shader: path, sha256: sha, git: git,
                    size: [renderSize.width, renderSize.height], fps: fps, mode: mode,
                    warmup: warmup, frames: frames, repeat: `repeat`, ms: ms, repeats: repeats,
                    passes: max(document.passes.count, 1),
                    compile_ms: .init(glsl: check.report.timings["glsl"] ?? 0, spirv_cross: check.report.timings["spirv_cross"] ?? 0, metal: metalMs ?? 0),
                    device: device, isftool: isftoolVersion
                )
                // Written as soon as it is measured, so a long run that stops halfway keeps what it has.
                try store.append(result)
                measured.append(result)
                let previous = ResultsStore.previous(of: result, in: history)
                rows.append(BenchRow(shader: path, mode: mode.rawValue, result: result, previous: previous, note: notes.joined(separator: ", ")))
                if !json { FileHandle.standardError.write(Data(String(format: "%@  %@  %.2f ms\n", path, mode.rawValue, ms.median).utf8)) }
            } catch {
                fail("\(mode.rawValue): \(error)")
            }
        }

        try report()
    }
}

struct Info: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Summarize inputs, passes, uniform layout and Metal argument indices.")

    @Argument(help: "ISF fragment shader (.fs).")
    var shader: String

    @Option(help: "Output size used to evaluate pass sizes.")
    var size = "1920x1440"

    @Option(name: .customLong("feed-envelope-pattern"), help: ArgumentHelp("Regular expression for the names of the inputs --feed-envelope feeds. They are marked [envelope].", valueName: "regex"))
    var feedEnvelopePattern = FeedMatcher.defaultPattern

    @OptionGroup var tools: ToolOptions

    func run() throws {
        let renderSize = try parseSize(size)
        let matcher: FeedMatcher
        do {
            matcher = try FeedMatcher(pattern: feedEnvelopePattern)
        } catch {
            throw ValidationError("invalid --feed-envelope-pattern: \(error.localizedDescription)")
        }
        let checker = Checker(source: ISFGLSLGeneratorSource(renderSize: renderSize), toolchain: try tools.toolchain(), metal: nil)
        let result = tools.withWorkDirectory(for: shader) { checker.check(path: shader, workDirectory: $0) }
        guard result.artifacts.document != nil else {
            print(CheckFormatter.format(result))
            throw ExitCode.failure
        }
        print(InfoFormatter.format(result, size: renderSize, feed: matcher))
        if !result.report.ok {
            print("")
            print(CheckFormatter.format(result))
            throw ExitCode.failure
        }
    }
}

struct Dump: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print one generated artifact to stdout.")

    enum What: String, ExpressibleByArgument, CaseIterable {
        case glslVert = "glsl-vert"
        case glslFrag = "glsl-frag"
        case spirvVert = "spirv-vert"
        case spirvFrag = "spirv-frag"
        case mslVert = "msl-vert"
        case mslFrag = "msl-frag"
        case reflectVert = "reflect-vert"
        case reflectFrag = "reflect-frag"

        var stage: ShaderStage { rawValue.hasSuffix("vert") ? .vert : .frag }
    }

    @Argument(help: "ISF fragment shader (.fs).")
    var shader: String

    @Argument(help: "One of: \(What.allCases.map(\.rawValue).joined(separator: ", ")).")
    var what: What

    @OptionGroup var tools: ToolOptions

    func run() throws {
        let toolchain = try tools.toolchain()
        let checker = Checker(toolchain: toolchain, metal: nil, options: CheckOptions(metal: false))
        let output: String? = try tools.withWorkDirectory(for: shader) { dir in
            let result = checker.check(path: shader, workDirectory: dir)
            let a = result.artifacts
            let stage = what.stage
            var text: String?
            switch what {
            case .glslVert: text = a.generated?.vert
            case .glslFrag: text = a.generated?.frag
            case .mslVert, .mslFrag: text = a.msl[stage]
            case .spirvVert, .spirvFrag:
                if let glsl = stage == .vert ? a.generated?.vert : a.generated?.frag {
                    let r = try toolchain.disassemble(glsl, stage: stage, output: dir.appendingPathComponent("\(stage.rawValue)-dis.spv").path)
                    text = r.status == 0 ? r.stdout : nil
                }
            case .reflectVert, .reflectFrag:
                if let spv = a.spirvPaths[stage] {
                    let r = try toolchain.reflect(spirv: spv)
                    text = r.status == 0 ? r.stdout : nil
                }
            }
            if text == nil {
                FileHandle.standardError.write(Data((CheckFormatter.format(result) + "\n").utf8))
            }
            return text
        }
        guard let output else { throw ExitCode.failure }
        print(output, terminator: output.hasSuffix("\n") ? "" : "\n")
    }
}

// ArgumentParser exits with 64 on usage errors; the design asks for 2.
do {
    var command = try IsfTool.parseAsRoot()
    try command.run()
} catch {
    let code = IsfTool.exitCode(for: error)
    if code == .validationFailure {
        FileHandle.standardError.write(Data((IsfTool.fullMessage(for: error) + "\n").utf8))
        exit(2)
    }
    IsfTool.exit(withError: error)
}
