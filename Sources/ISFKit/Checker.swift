import Foundation

public enum CheckStage: String, Codable, Sendable, CaseIterable {
    case parse
    case glsl
    case spirvCross = "spirv-cross"
    case metal
    case unbound
}

/// Produces the ISF snapshot and generated GLSL. The default goes through ISFGLSLGenerator; tests can supply strings.
public protocol ISFSourceGenerating {
    func load(path: String) throws -> (ISFDocumentInfo, ISFGeneratedSource)
}

public struct ISFGLSLGeneratorSource: ISFSourceGenerating {
    /// When set, pass sizes are evaluated at this output size before the snapshot is taken.
    public var renderSize: RenderSize?

    public init(renderSize: RenderSize? = nil) {
        self.renderSize = renderSize
    }

    public func load(path: String) throws -> (ISFDocumentInfo, ISFGeneratedSource) {
        let doc = try ISFDocument(path: path)
        let generated = try doc.generate()
        if let renderSize {
            try doc.evalPassSizes(width: renderSize.width, height: renderSize.height)
        }
        return (try doc.describe(), generated)
    }
}

public struct RenderSize: Equatable, Sendable, CustomStringConvertible {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// Parses `WxH`, for example `1920x1440`.
    public init?(parsing text: String) {
        let parts = text.lowercased().split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 else { return nil }
        width = w
        height = h
    }

    public var description: String { "\(width)x\(height)" }
}

public struct CheckReport: Codable, Equatable, Sendable {
    public var path: String
    public var ok: Bool
    public var stage: CheckStage?
    /// Which shader failed, for the stages that compile vertex and fragment separately.
    public var shader: ShaderStage?
    public var error: String?
    public var diagnostics: [GLSLDiagnostic]
    public var unbound: [UnboundArgument]
    /// Milliseconds per stage, keyed by stage name.
    public var timings: [String: Double]

    public init(path: String, ok: Bool = true, stage: CheckStage? = nil, error: String? = nil, diagnostics: [GLSLDiagnostic] = [], unbound: [UnboundArgument] = [], timings: [String: Double] = [:]) {
        self.path = path
        self.ok = ok
        self.stage = stage
        self.error = error
        self.diagnostics = diagnostics
        self.unbound = unbound
        self.timings = timings
    }
}

/// Everything produced up to the stage that failed, so `dump` can show what exists even for a broken shader.
public struct CheckArtifacts: Sendable {
    public var document: ISFDocumentInfo?
    public var generated: ISFGeneratedSource?
    public var lineMap: LineMap?
    public var entryPoints: EntryPointNames
    public var spirvPaths: [ShaderStage: String] = [:]
    public var msl: [ShaderStage: String] = [:]
    public var signatures: [ShaderStage: MSLSignature] = [:]

    public init(entryPoints: EntryPointNames) {
        self.entryPoints = entryPoints
    }
}

public struct CheckResult: Sendable {
    public var report: CheckReport
    public var artifacts: CheckArtifacts
}

public struct CheckOptions: Sendable {
    public var metal: Bool

    public init(metal: Bool = true) {
        self.metal = metal
    }
}

/// Runs the same path as VDMX: ISFGLSLGenerator, glslang, SPIRV-Cross, Metal, then isftool's own checks.
public struct Checker {
    public var source: ISFSourceGenerating
    public var toolchain: Toolchain
    public var metal: MSLCompiling?
    public var options: CheckOptions

    public init(source: ISFSourceGenerating = ISFGLSLGeneratorSource(), toolchain: Toolchain, metal: MSLCompiling?, options: CheckOptions = CheckOptions()) {
        self.source = source
        self.toolchain = toolchain
        self.metal = metal
        self.options = options
    }

    /// - Parameter workDirectory: Where SPIR-V and MSL are written. The caller owns it and decides whether to keep it.
    public func check(path: String, workDirectory: URL) -> CheckResult {
        var report = CheckReport(path: path)
        var artifacts = CheckArtifacts(entryPoints: EntryPointNames(path: path))

        func fail(_ stage: CheckStage, _ message: String?) -> CheckResult {
            report.ok = false
            report.stage = stage
            report.error = message
            return CheckResult(report: report, artifacts: artifacts)
        }
        func timed<T>(_ key: String, _ body: () throws -> T) rethrows -> T {
            let start = DispatchTime.now()
            defer {
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                report.timings[key, default: 0] += elapsed
            }
            return try body()
        }

        let document: ISFDocumentInfo
        let generated: ISFGeneratedSource
        do {
            (document, generated) = try timed("parse") { try source.load(path: path) }
        } catch {
            return fail(.parse, "\(error)")
        }
        artifacts.document = document
        artifacts.generated = generated
        let lineMap = LineMap(jsonSource: document.jsonSource, body: document.fragSource, generated: generated.frag)
        artifacts.lineMap = lineMap

        do {
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        } catch {
            return fail(.glsl, "cannot create \(workDirectory.path): \(error)")
        }
        let stages: [(ShaderStage, String)] = [(.vert, generated.vert), (.frag, generated.frag)]

        for (stage, glsl) in stages {
            let spv = workDirectory.appendingPathComponent("\(stage.rawValue).spv").path
            let result: CommandResult
            do {
                result = try timed("glsl") { try toolchain.compileGLSL(glsl, stage: stage, output: spv) }
            } catch {
                return fail(.glsl, "\(error)")
            }
            if result.status != 0 {
                // Line numbers only map back to the .fs for the fragment stage, where the body lives.
                report.diagnostics = GLSLangDiagnostics.parse(result.output, lineMap: stage == .frag ? lineMap : nil)
                report.shader = stage
                return fail(.glsl, "failed to compile to SPIR-V")
            }
            artifacts.spirvPaths[stage] = spv
        }

        for (stage, _) in stages {
            let out = workDirectory.appendingPathComponent("\(stage.rawValue).metal").path
            let entry = stage == .vert ? artifacts.entryPoints.vert : artifacts.entryPoints.frag
            let result: CommandResult
            do {
                result = try timed("spirv_cross") { try toolchain.convertToMSL(spirv: artifacts.spirvPaths[stage]!, entryPoint: entry, stage: stage, output: out) }
            } catch {
                return fail(.spirvCross, "\(error)")
            }
            guard result.status == 0, let msl = try? String(contentsOfFile: out, encoding: .utf8) else {
                report.shader = stage
                return fail(.spirvCross, result.output.isEmpty ? "spirv-cross exited with \(result.status)" : result.output)
            }
            artifacts.msl[stage] = msl
            artifacts.signatures[stage] = MSLSignature.parse(functionName: entry, msl: msl)
        }

        if options.metal, let metal {
            for (stage, _) in stages {
                do {
                    try timed("metal") { try metal.compile(artifacts.msl[stage]!) }
                } catch {
                    report.shader = stage
                    return fail(.metal, "\(error)")
                }
            }
        }

        let names = document.textureNames
        report.unbound = stages.flatMap { artifacts.signatures[$0.0]?.unboundArguments(textureNames: names) ?? [] }
        if !report.unbound.isEmpty {
            let list = report.unbound.map { "\($0.name) (\($0.kind) \($0.index))" }.joined(separator: ", ")
            return fail(.unbound, "declares arguments the ISF host cannot supply: \(list)")
        }

        return CheckResult(report: report, artifacts: artifacts)
    }
}
