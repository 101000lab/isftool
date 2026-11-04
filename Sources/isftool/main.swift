import ArgumentParser
import Foundation
import ISFKit

let isftoolVersion = "0.1.0"

struct IsfTool: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "isftool",
        abstract: "Check, render and benchmark ISF shaders through the same GLSL to SPIR-V to Metal path as VDMX.",
        version: isftoolVersion,
        subcommands: [Check.self, Render.self, Info.self, Dump.self]
    )
}

struct ToolOptions: ParsableArguments {
    @Option(name: .customLong("glslang"), help: "Path to glslang (default: from PATH).")
    var glslang: String?

    @Option(name: .customLong("spirv-cross"), help: "Path to spirv-cross (default: from PATH).")
    var spirvCross: String?

    @Option(name: .customLong("keep-intermediates"), help: "Keep generated SPIR-V and MSL under this directory.")
    var keepIntermediates: String?

    func toolchain() throws -> Toolchain {
        try Toolchain.locate(glslang: glslang, spirvCross: spirvCross)
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

struct ShaderList: ParsableArguments {
    @Argument(help: "ISF fragment shaders (.fs).")
    var shaders: [String] = []

    @Option(name: .customLong("from"), help: "Read shader paths from a file, one per line (- for stdin).")
    var from: String?

    func resolve() throws -> [String] {
        var paths = shaders
        if let from {
            let text: String
            if from == "-" {
                text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            } else {
                text = try String(contentsOfFile: from, encoding: .utf8)
            }
            paths += text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if paths.isEmpty {
            throw ValidationError("no shaders given")
        }
        return paths
    }
}

func parseSize(_ text: String) throws -> RenderSize {
    guard let size = RenderSize(parsing: text) else { throw ValidationError("invalid size '\(text)', expected WxH") }
    return size
}

struct Check: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Compile shaders to Metal and report failures.")

    @OptionGroup var list: ShaderList
    @OptionGroup var tools: ToolOptions

    @Flag(help: "Print JSON instead of text.")
    var json = false

    @Flag(name: .customLong("no-lint"), help: "Skip the Metal keyword check.")
    var noLint = false

    func run() throws {
        let paths = try list.resolve()
        let checker = Checker(toolchain: try tools.toolchain(), metal: try MetalLibraryCompiler(), options: CheckOptions(lint: !noLint))
        var reports: [CheckReport] = []
        for path in paths {
            let result = tools.withWorkDirectory(for: path) { checker.check(path: path, workDirectory: $0) }
            reports.append(result.report)
            if !json {
                print(CheckFormatter.format(result))
            }
        }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(reports), as: UTF8.self))
        } else if paths.count > 1 {
            let failed = reports.filter { !$0.ok }.count
            print("\n\(paths.count - failed) ok, \(failed) failed")
        }
        if reports.contains(where: { !$0.ok }) {
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

    @Option(name: .customLong("set"), help: "Fix an input to a value, as NAME=VALUE. Color is r,g,b,a and Point2D is x,y. Repeatable.")
    var assignments: [String] = []

    @Flag(name: .customLong("no-lint"), help: "Skip the Metal keyword check.")
    var noLint = false

    @OptionGroup var tools: ToolOptions

    func validate() throws {
        guard fps > 0 else { throw ValidationError("--fps must be positive") }
        guard at >= 0 else { throw ValidationError("--at must not be negative") }
        guard frames >= 1 else { throw ValidationError("--frames must be at least 1") }
    }

    func run() throws {
        let renderSize = try parseSize(size)
        // The renderer compiles the MSL itself, so check stops before Metal to avoid compiling twice.
        let checker = Checker(source: ISFGLSLGeneratorSource(renderSize: renderSize), toolchain: try tools.toolchain(), metal: nil, options: CheckOptions(lint: !noLint, metal: false))
        let result = tools.withWorkDirectory(for: shader) { checker.check(path: shader, workDirectory: $0) }
        guard result.report.ok, let document = result.artifacts.document else {
            print(CheckFormatter.format(result))
            throw ExitCode.failure
        }
        var values = InputValues(document: document)
        for assignment in assignments {
            do {
                try values.set(assignment, document: document)
            } catch {
                throw ValidationError("\(error)")
            }
        }
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
            try renderer.renderFrames(frames: drawn, values: values.values, capture: plan.drawn.map(plan.written.contains)) { n, image in
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
        let checker = Checker(toolchain: toolchain, metal: nil, options: CheckOptions(lint: false, metal: false))
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
