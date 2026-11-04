import CToolchain
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
        let input = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input
        try process.run()

        // Drain both pipes concurrently, otherwise a child that fills one pipe blocks forever.
        // The readers get their own threads instead of DispatchQueue.global(): when many checks run in parallel
        // (swift-testing does), every global worker can be one of them waiting here, and the reads never start.
        let box = OutputBox()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread { box.out = out.fileHandleForReading.readDataToEndOfFile(); done.signal() }
        Thread.detachNewThread { box.err = err.fileHandleForReading.readDataToEndOfFile(); done.signal() }
        if let stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        }
        done.wait()
        done.wait()
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

/// GLSL to SPIR-V to MSL. Paths name the files each step writes, so `--keep-intermediates` can keep them.
public protocol Toolchain: Sendable {
    /// Writes the SPIR-V to `output`. A non-zero status carries glslang's log in `stdout`.
    func compileGLSL(_ source: String, stage: ShaderStage, output: String) throws -> CommandResult
    /// Reads the SPIR-V at `spirv` and writes the MSL to `output`.
    func convertToMSL(spirv: String, entryPoint: String, stage: ShaderStage, output: String) throws -> CommandResult
    /// SPIRV-Cross's reflection JSON in `stdout`.
    func reflect(spirv: String) throws -> CommandResult
    /// Compiles like `compileGLSL` and puts the readable SPIR-V after glslang's log in `stdout`.
    func disassemble(_ source: String, stage: ShaderStage, output: String) throws -> CommandResult
}

/// glslang and SPIRV-Cross linked into isftool at the commits VDMX's ISFMSLKit was built from (design 2.5).
public struct LinkedToolchain: Toolchain {
    public static let glslangVersion = String(cString: isft_glslang_version())
    public static let spirvCrossRevision = String(cString: isft_spirv_cross_revision())
    /// The VDMX whose bundled glslang and SPIRV-Cross give the same SPIR-V and MSL as these, byte for byte (design 2.5).
    public static let vdmxVersion = "VDMX6 Plus 6.1.3.6"
    public static var versionSummary: String {
        "glslang \(glslangVersion), SPIRV-Cross \(spirvCrossRevision.prefix(8)), as in \(vdmxVersion)"
    }

    public init() {}

    public func compileGLSL(_ source: String, stage: ShaderStage, output: String) throws -> CommandResult {
        let (words, log) = Self.compile(source, stage: stage)
        guard let words else { return CommandResult(status: 1, stdout: log) }
        try Self.data(words).write(to: URL(fileURLWithPath: output))
        return CommandResult(status: 0, stdout: log)
    }

    public func convertToMSL(spirv: String, entryPoint: String, stage: ShaderStage, output: String) throws -> CommandResult {
        let words = try Self.words(at: spirv)
        var msl: UnsafeMutablePointer<CChar>?
        var error: UnsafeMutablePointer<CChar>?
        defer { isft_free(msl); isft_free(error) }
        let ok = words.withUnsafeBufferPointer { isft_spirv_to_msl($0.baseAddress, $0.count, entryPoint, stage.cStage, &msl, &error) }
        guard ok, let msl else { return CommandResult(status: 1, stderr: error.map { String(cString: $0) } ?? "") }
        try String(cString: msl).write(toFile: output, atomically: true, encoding: .utf8)
        return CommandResult(status: 0)
    }

    public func reflect(spirv: String) throws -> CommandResult {
        let words = try Self.words(at: spirv)
        var json: UnsafeMutablePointer<CChar>?
        var error: UnsafeMutablePointer<CChar>?
        defer { isft_free(json); isft_free(error) }
        let ok = words.withUnsafeBufferPointer { isft_spirv_reflect($0.baseAddress, $0.count, &json, &error) }
        guard ok, let json else { return CommandResult(status: 1, stderr: error.map { String(cString: $0) } ?? "") }
        return CommandResult(status: 0, stdout: String(cString: json))
    }

    public func disassemble(_ source: String, stage: ShaderStage, output: String) throws -> CommandResult {
        let (words, log) = Self.compile(source, stage: stage)
        guard let words else { return CommandResult(status: 1, stdout: log) }
        try Self.data(words).write(to: URL(fileURLWithPath: output))
        let text = words.withUnsafeBufferPointer { isft_spirv_disassemble($0.baseAddress, $0.count) }
        defer { isft_free(text) }
        return CommandResult(status: 0, stdout: log + (text.map { String(cString: $0) } ?? ""))
    }

    static func compile(_ source: String, stage: ShaderStage) -> ([UInt32]?, String) {
        var words: UnsafeMutablePointer<UInt32>?
        var count = 0
        var log: UnsafeMutablePointer<CChar>?
        defer { isft_free(words); isft_free(log) }
        let ok = isft_glsl_to_spirv(source, stage.cStage, &words, &count, &log)
        let text = log.map { String(cString: $0) } ?? ""
        guard ok, let words else { return (nil, text) }
        return (Array(UnsafeBufferPointer(start: words, count: count)), text)
    }

    static func data(_ words: [UInt32]) -> Data {
        words.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func words(at path: String) throws -> [UInt32] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return data.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
    }
}

extension ShaderStage {
    var cStage: ISFTStage { self == .vert ? ISFT_STAGE_VERTEX : ISFT_STAGE_FRAGMENT }
}
