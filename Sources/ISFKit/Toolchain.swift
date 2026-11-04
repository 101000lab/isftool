import Foundation

public struct CommandResult: Equatable, Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public init(status: Int32, stdout: String = "", stderr: String = "") {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var output: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

public protocol CommandRunner: Sendable {
    func run(_ executable: String, _ arguments: [String], stdin: String?) throws -> CommandResult
}

public struct ProcessRunner: CommandRunner {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], stdin: String?) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let input = Pipe()
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input
        try process.run()

        // Drain both pipes concurrently, otherwise a child that fills one pipe blocks forever.
        let group = DispatchGroup()
        let box = OutputBox()
        DispatchQueue.global().async(group: group) { box.out = out.fileHandleForReading.readDataToEndOfFile() }
        DispatchQueue.global().async(group: group) { box.err = err.fileHandleForReading.readDataToEndOfFile() }
        if let stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        }
        group.wait()
        process.waitUntilExit()
        return CommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: box.out, as: UTF8.self),
            stderr: String(decoding: box.err, as: UTF8.self)
        )
    }

    private final class OutputBox: @unchecked Sendable {
        var out = Data()
        var err = Data()
    }
}

public enum ShaderStage: String, Codable, Sendable {
    case vert
    case frag
}

public struct ToolchainError: Error, CustomStringConvertible, Sendable {
    public var message: String
    public var description: String { message }
}

/// glslang and SPIRV-Cross invoked with the same arguments as VIDVOX's GLSLangValidatorLib and SPIRVCrossLib.
public struct Toolchain: Sendable {
    public var glslang: String
    public var spirvCross: String
    public var runner: CommandRunner

    public init(glslang: String, spirvCross: String, runner: CommandRunner = ProcessRunner()) {
        self.glslang = glslang
        self.spirvCross = spirvCross
        self.runner = runner
    }

    /// Resolves each tool from an explicit path or from PATH.
    public static func locate(glslang: String? = nil, spirvCross: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment, runner: CommandRunner = ProcessRunner()) throws -> Toolchain {
        func find(_ explicit: String?, _ names: [String]) throws -> String {
            if let explicit { return explicit }
            let dirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            for name in names {
                for dir in dirs {
                    let candidate = (dir as NSString).appendingPathComponent(name)
                    if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
                }
            }
            throw ToolchainError(message: "\(names[0]) not found in PATH")
        }
        return Toolchain(
            glslang: try find(glslang, ["glslang", "glslangValidator"]),
            spirvCross: try find(spirvCross, ["spirv-cross"]),
            runner: runner
        )
    }

    /// `-G --amb --aml --stdin -S <stage>`. The source goes through stdin so error lines read `stdin:<line>` like VDMX.
    public static func glslangArguments(stage: ShaderStage, output: String) -> [String] {
        ["-G", "--amb", "--aml", "--stdin", "-S", stage.rawValue, "-o", output]
    }

    /// `--rename-entry-point main <name> <stage> --msl`. No MSL version and no `--msl-decoration-binding`, as in SPIRVCrossLib.
    public static func spirvCrossArguments(input: String, entryPoint: String, stage: ShaderStage, output: String) -> [String] {
        [input, "--rename-entry-point", "main", entryPoint, stage.rawValue, "--msl", "--output", output]
    }

    public func compileGLSL(_ source: String, stage: ShaderStage, output: String) throws -> CommandResult {
        try runner.run(glslang, Self.glslangArguments(stage: stage, output: output), stdin: source)
    }

    public func convertToMSL(spirv: String, entryPoint: String, stage: ShaderStage, output: String) throws -> CommandResult {
        try runner.run(spirvCross, Self.spirvCrossArguments(input: spirv, entryPoint: entryPoint, stage: stage, output: output), stdin: nil)
    }

    public func reflect(spirv: String) throws -> CommandResult {
        try runner.run(spirvCross, [spirv, "--reflect"], stdin: nil)
    }

    /// Human-readable SPIR-V. glslang has no disassembler for an existing module, so this recompiles with `-H`.
    public func disassemble(_ source: String, stage: ShaderStage, output: String) throws -> CommandResult {
        try runner.run(glslang, ["-G", "--amb", "--aml", "--stdin", "-S", stage.rawValue, "-H", "-o", output], stdin: source)
    }
}
