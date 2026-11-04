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

struct LevelOptions: ParsableArguments {
    @Option(name: .customLong("recording"), help: "Recording of VDMX's Audio Analysis as JSON Lines of {t, address, value}. Enables the recording mode.")
    var recording: String?

    @Option(name: .customLong("level-pattern"), help: "Regular expression for Level input names.")
    var levelPattern = LevelMatcher.defaultPattern

    @Option(name: .customLong("set"), help: "Fix an input to a value, as NAME=VALUE. Color is r,g,b,a and Point2D is x,y. Repeatable. Applied after the Level mode.")
    var assignments: [String] = []

    func load() throws -> (LevelMatcher, Recording?) {
        let matcher: LevelMatcher
        do {
            matcher = try LevelMatcher(pattern: levelPattern)
        } catch {
            throw ValidationError("invalid --level-pattern: \(error.localizedDescription)")
        }
        guard let recording else { return (matcher, nil) }
        do {
            return (matcher, try Recording(contentsOf: recording))
        } catch {
            throw ValidationError("cannot read --recording \(recording): \(error)")
        }
    }

    func driver(document: ISFDocumentInfo, mode: LevelMode, matcher: LevelMatcher, recording: Recording?) throws -> LevelDriver {
        do {
            return try LevelDriver(document: document, mode: mode, matcher: matcher, recording: recording, assignments: assignments)
        } catch {
            throw ValidationError("\(error)")
        }
    }
}

extension LevelMode: ExpressibleByArgument {}
extension BenchSort: ExpressibleByArgument {}

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

    @Option(help: "How Level inputs are driven: default (DEFAULT values), recording (from --recording) or max (MAX).")
    var levels: LevelMode = .default

    @OptionGroup var levelOptions: LevelOptions

    @OptionGroup var tools: ToolOptions

    func validate() throws {
        guard fps > 0 else { throw ValidationError("--fps must be positive") }
        if levels == .recording && levelOptions.recording == nil { throw ValidationError("--levels recording needs --recording") }
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
        let (matcher, recording) = try levelOptions.load()
        let driver = try levelOptions.driver(document: document, mode: levels, matcher: matcher, recording: recording)
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
    static let configuration = CommandConfiguration(abstract: "Measure the GPU time per frame of a shader in each mode.")

    @Argument(help: "ISF fragment shader (.fs).")
    var shader: String

    @Option(help: "Output size.")
    var size = "1920x1440"

    @Option(help: "Clock rate. TIME = i / fps, TIMEDELTA = 1 / fps, FRAMEINDEX = i.")
    var fps: Double = 60

    @OptionGroup var levelOptions: LevelOptions

    @Option(help: "Frames drawn before measuring, so persistent buffers fill up.")
    var warmup = 60

    @Option(help: "Frames measured per repeat.")
    var frames = 240

    @Option(help: "How many times to measure. The reported median is the median of each repeat's median.")
    var `repeat` = 1

    @Option(help: "Level modes to measure, comma separated (default, recording, max). Default: default,max, plus recording when --recording is given.")
    var modes: String?

    @Option(help: "Append results to this JSON Lines file.")
    var results = ".isftool/results.jsonl"

    @Flag(name: .customLong("no-compare"), help: "Leave out the change from the previous run.")
    var noCompare = false

    @Flag(help: "Print JSON instead of the table.")
    var json = false

    @Option(help: "Sort the table by median, p95 or shader.")
    var sort: BenchSort = .median

    @OptionGroup var tools: ToolOptions

    func resolvedModes() throws -> [LevelMode] {
        guard let modes else { return levelOptions.recording == nil ? [.default, .max] : [.default, .recording, .max] }
        return try modes.split(separator: ",").map {
            let name = $0.trimmingCharacters(in: .whitespaces)
            guard let mode = LevelMode(rawValue: name) else { throw ValidationError("unknown mode '\(name)' in --modes") }
            return mode
        }
    }

    func validate() throws {
        guard fps > 0 else { throw ValidationError("--fps must be positive") }
        guard warmup >= 0, frames >= 1, `repeat` >= 1 else { throw ValidationError("--warmup must be 0 or more, --frames and --repeat at least 1") }
        if try resolvedModes().contains(.recording) && levelOptions.recording == nil {
            throw ValidationError("the recording mode needs --recording")
        }
    }

    func run() throws {
        let renderSize = try parseSize(size)
        let modes = try resolvedModes()
        let (matcher, recording) = try levelOptions.load()
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
                print(BenchFormatter.format(BenchFormatter.sorted(rows, by: sort), compare: !noCompare))
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
                let driver = try levelOptions.driver(document: document, mode: mode, matcher: matcher, recording: recording)
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

    @Option(name: .customLong("level-pattern"), help: "Regular expression for Level input names.")
    var levelPattern = LevelMatcher.defaultPattern

    @OptionGroup var tools: ToolOptions

    func run() throws {
        let renderSize = try parseSize(size)
        let matcher = try LevelMatcher(pattern: levelPattern)
        let checker = Checker(source: ISFGLSLGeneratorSource(renderSize: renderSize), toolchain: try tools.toolchain(), metal: nil)
        let result = tools.withWorkDirectory(for: shader) { checker.check(path: shader, workDirectory: $0) }
        guard result.artifacts.document != nil else {
            print(CheckFormatter.format(result))
            throw ExitCode.failure
        }
        print(InfoFormatter.format(result, size: renderSize, levels: matcher))
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
