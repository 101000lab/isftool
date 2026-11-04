import Foundation
import Testing
@testable import ISFKit

@Suite struct LineMapTests {
    @Test func testMapsBodyLinesByConstantOffset() {
        let json = "/*{\n\"INPUTS\": []\n}*/\n"
        let body = "void main() {\n  gl_FragColor = vec4(0.0);\n}\n"
        let generated = "#version 400\nprecision highp float;\nuniform float x;\n" + body
        let map = LineMap(jsonSource: json, body: body, generated: generated)

        #expect(map.sourceBodyStart == 4)
        #expect(map.generatedBodyStart == 4)
        #expect(map.sourceLine(forGenerated: 5) == 5)
    }

    @Test func testPreambleLinesHaveNoSourceLine() {
        let map = LineMap(sourceBodyStart: 19, generatedBodyStart: 40)
        #expect(map.sourceLine(forGenerated: 39) == nil)
        #expect(map.sourceLine(forGenerated: 40) == 19)
        #expect(map.sourceLine(forGenerated: 111) == 90)
    }
}

@Suite struct GLSLangDiagnosticsTests {
    // Captured from glslang 16.6.0 with `-G --amb --aml --stdin -S frag`.
    let log = """
    ERROR: stdin:111: '' :  syntax error, unexpected LAYOUT, expecting COMMA or SEMICOLON
    ERROR: 1 compilation errors.  No code generated.


    SPIR-V is not generated for failed compile or link
    """

    @Test func testParsesLineAndMessage() {
        let diags = GLSLangDiagnostics.parse(log, lineMap: LineMap(sourceBodyStart: 19, generatedBodyStart: 40))
        #expect(diags == [
            GLSLDiagnostic(severity: "error", line: 111, sourceLine: 90, message: "'' :  syntax error, unexpected LAYOUT, expecting COMMA or SEMICOLON"),
        ])
    }

    @Test func testKeepsErrorsWithoutLocation() {
        let diags = GLSLangDiagnostics.parse("ERROR: Linking vertex stage: Missing entry point: Each stage requires one entry point\n")
        #expect(diags == [GLSLDiagnostic(severity: "error", line: nil, message: "Linking vertex stage: Missing entry point: Each stage requires one entry point")])
    }
}

@Suite struct MSLSignatureTests {
    // SPIRV-Cross 1.4.363.0 output for line_space.fs, with VIDVOX's arguments.
    let fragMSL = """
    struct VVline_spaceFragFunc_out
    {
        float4 isf_FragColor [[color(0)]];
    };

    fragment VVline_spaceFragFunc_out VVline_spaceFragFunc(VVline_spaceFragFunc_in in [[stage_in]], constant VVISF_UNIFORMS& _215 [[buffer(0)]], texture2d<float> lineState [[texture(0)]], sampler lineStateSmplr [[sampler(0)]])
    {
    """

    @Test func testEntryPointNamesReplaceNonAlphanumerics() {
        let names = EntryPointNames(path: "/a/b/line-space 2.fs")
        #expect(names.vert == "VVline_space_2VertFunc")
        #expect(names.frag == "VVline_space_2FragFunc")
    }

    @Test func testParsesIndicesByName() {
        let sig = MSLSignature.parse(functionName: "VVline_spaceFragFunc", msl: fragMSL)
        #expect(sig.buffers == ["VVISF_UNIFORMS&": 0])
        #expect(sig.textures == ["lineState": 0])
        #expect(sig.samplers == ["lineStateSmplr": 0])
    }

    @Test func testStructNamedAfterFunctionIsNotTheDeclaration() {
        // `VVline_spaceFragFunc_out` must not match as a whole word.
        let line = MSLSignature.declarationLine(functionName: "VVline_spaceFragFunc", msl: fragMSL)
        #expect(line.hasPrefix("fragment "))
    }

    @Test func testMultipleTextures() {
        let msl = "fragment F_out F(F_in in [[stage_in]], constant VVISF_UNIFORMS& _1 [[buffer(0)]], texture2d<float> bufA [[texture(0)]], texture2d<float> img [[texture(1)]], sampler bufASmplr [[sampler(0)]], sampler imgSmplr [[sampler(1)]])\n"
        let sig = MSLSignature.parse(functionName: "F", msl: msl)
        #expect(sig.textures == ["bufA": 0, "img": 1])
        #expect(sig.samplers == ["bufASmplr": 0, "imgSmplr": 1])
    }

    @Test func testUnboundArguments() {
        let sig = MSLSignature(
            buffers: ["VVISF_UNIFORMS&": 0, "_99": 1],
            textures: ["lineState": 0, "myTex": 1]
        )
        #expect(sig.unboundArguments(textureNames: ["lineState"]) == [
            UnboundArgument(name: "_99", kind: "buffer", index: 1),
            UnboundArgument(name: "myTex", kind: "texture", index: 1),
        ])
    }

    @Test func testUniformsAtNonZeroIndexIsUnbound() {
        let sig = MSLSignature(buffers: ["VVISF_UNIFORMS&": 1])
        #expect(sig.unboundArguments(textureNames: []) == [UnboundArgument(name: "VVISF_UNIFORMS&", kind: "buffer", index: 1)])
    }

    @Test func testVertexDataGoesAfterLargestBuffer() {
        #expect(MSLSignature(buffers: ["VVISF_UNIFORMS&": 0]).maxBufferIndex + 1 == 1)
    }
}

@Suite struct LintTests {
    @Test func testFindsReservedIdentifiersWithPositions() {
        let src = "/*{ \"INPUTS\": [] }*/\nvec2 vertex(float a) {\n  return vec2(a);\n}\n"
        let v = Lint.scan(source: src)
        #expect(v == [LintViolation(identifier: "vertex", line: 2, column: 6, message: "'vertex' is a Metal keyword")])
    }

    @Test func testIgnoresCommentsAndLongerIdentifiers() {
        let src = "// vertex here\n/* kernel\n device */ float vertexCount; float my_half;\n"
        #expect(Lint.scan(source: src) == [])
    }

    @Test func testReportsDeclaredNamesFromMetadata() {
        let src = "/*{\n  \"INPUTS\": [ { \"NAME\": \"half\", \"TYPE\": \"float\" } ]\n}*/\nvoid main() {}\n"
        let v = Lint.scan(source: src, declaredNames: ["half"])
        #expect(v.map(\.identifier) == ["half"])
        #expect(v.first?.line == 2)
    }

    @Test func testAllowsNamesVDMXAccepts() {
        #expect(Lint.scan(source: "void main() {\n  float visible = 1.0;\n}\n") == [])
    }
}

@Suite struct ToolchainTests {
    final class Recorder: CommandRunner, @unchecked Sendable {
        var calls: [(String, [String], String?)] = []
        var result = CommandResult(status: 0)
        func run(_ executable: String, _ arguments: [String], stdin: String?) throws -> CommandResult {
            calls.append((executable, arguments, stdin))
            return result
        }
    }

    @Test func testGlslangArgumentsMatchVIDVOX() {
        #expect(Toolchain.glslangArguments(stage: .frag, output: "f.spv") == ["-G", "--amb", "--aml", "--stdin", "-S", "frag", "-o", "f.spv"])
    }

    @Test func testSpirvCrossArgumentsMatchVIDVOX() {
        #expect(
            Toolchain.spirvCrossArguments(input: "v.spv", entryPoint: "VVxVertFunc", stage: .vert, output: "v.metal")
                == ["v.spv", "--rename-entry-point", "main", "VVxVertFunc", "vert", "--msl", "--output", "v.metal"]
        )
    }

    @Test func testCompilePassesSourceOnStdin() throws {
        let rec = Recorder()
        let tc = Toolchain(glslang: "/g", spirvCross: "/s", runner: rec)
        _ = try tc.compileGLSL("void main(){}", stage: .vert, output: "o.spv")
        #expect(rec.calls.first?.0 == "/g")
        #expect(rec.calls.first?.2 == "void main(){}")
    }

    @Test func testLocateSearchesPath() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["glslangValidator", "spirv-cross"] {
            let p = dir.appendingPathComponent(name).path
            FileManager.default.createFile(atPath: p, contents: Data(), attributes: [.posixPermissions: 0o755])
        }
        let tc = try Toolchain.locate(environment: ["PATH": "/nonexistent:\(dir.path)"])
        #expect(tc.glslang == dir.appendingPathComponent("glslangValidator").path)
        #expect(tc.spirvCross == dir.appendingPathComponent("spirv-cross").path)
    }

    @Test func testLocateFailsWhenMissing() {
        #expect(throws: (any Error).self) { try Toolchain.locate(environment: ["PATH": "/nonexistent"]) }
    }
}

@Suite struct CheckerTests {
    struct StubSource: ISFSourceGenerating {
        var document: ISFDocumentInfo
        var generated: ISFGeneratedSource
        func load(path: String) throws -> (ISFDocumentInfo, ISFGeneratedSource) { (document, generated) }
    }

    struct FailingSource: ISFSourceGenerating {
        func load(path: String) throws -> (ISFDocumentInfo, ISFGeneratedSource) { throw ISFBridgeError(message: "JSON error") }
    }

    /// Fails glslang for one stage, otherwise writes `msl` as spirv-cross output.
    final class FakeTools: CommandRunner, @unchecked Sendable {
        var failStage: ShaderStage?
        var glslangLog = ""
        var msl: [ShaderStage: String] = [:]
        func run(_ executable: String, _ arguments: [String], stdin: String?) throws -> CommandResult {
            if executable == "glslang" {
                let stage = ShaderStage(rawValue: arguments[arguments.firstIndex(of: "-S")! + 1])!
                return stage == failStage ? CommandResult(status: 2, stdout: glslangLog) : CommandResult(status: 0)
            }
            let stage = ShaderStage(rawValue: arguments[4])!
            let out = arguments[arguments.firstIndex(of: "--output")! + 1]
            try msl[stage, default: ""].write(toFile: out, atomically: true, encoding: .utf8)
            return CommandResult(status: 0)
        }
    }

    struct NoMetal: MSLCompiling {
        func compile(_ source: String) throws {}
    }

    let document = ISFDocumentInfo(
        inputs: [ISFInput(name: "Level", type: "Float")],
        jsonSource: "/*{}*/\n",
        fragSource: "void main() {\n  gl_FragColor = vec4(Level);\n}\n"
    )

    func tmp() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("isftool-test-\(UUID().uuidString)")
    }

    func cleanMSL() -> [ShaderStage: String] {
        [
            .vert: "vertex V_out VVsVertFunc(V_in in [[stage_in]], constant VVISF_UNIFORMS& _1 [[buffer(0)]])\n",
            .frag: "fragment F_out VVsFragFunc(F_in in [[stage_in]], constant VVISF_UNIFORMS& _2 [[buffer(0)]])\n",
        ]
    }

    func checker(_ tools: FakeTools, document: ISFDocumentInfo? = nil) -> Checker {
        let doc = document ?? self.document
        let generated = ISFGeneratedSource(frag: "#version 400\nuniform float Level;\n" + doc.fragSource, vert: "#version 400\n")
        return Checker(source: StubSource(document: doc, generated: generated), toolchain: Toolchain(glslang: "glslang", spirvCross: "spirv-cross", runner: tools), metal: NoMetal())
    }

    @Test func testParseFailure() {
        let c = Checker(source: FailingSource(), toolchain: Toolchain(glslang: "glslang", spirvCross: "spirv-cross", runner: FakeTools()), metal: nil)
        let r = c.check(path: "s.fs", workDirectory: tmp())
        #expect(r.report.stage == .parse)
        #expect(!(r.report.ok))
    }

    @Test func testGLSLFailureMapsLinesAndKeepsGeneratedSource() {
        let tools = FakeTools()
        tools.failStage = .frag
        tools.glslangLog = "ERROR: stdin:4: 'x' : undeclared identifier\n"
        let dir = tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = checker(tools).check(path: "s.fs", workDirectory: dir)
        #expect(r.report.stage == .glsl)
        #expect(r.report.shader == .frag)
        #expect(r.report.diagnostics.first?.line == 4)
        #expect(r.report.diagnostics.first?.sourceLine == 3)
        #expect(r.artifacts.generated != nil, "dump glsl-frag must work when glslang fails")
    }

    @Test func testSucceeds() {
        let tools = FakeTools()
        tools.msl = cleanMSL()
        let dir = tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = checker(tools).check(path: "s.fs", workDirectory: dir)
        #expect(r.report.ok, "\(r.report)")
        #expect(r.artifacts.signatures[.frag]?.buffers == ["VVISF_UNIFORMS&": 0])
        #expect(r.report.timings["glsl"] != nil)
    }

    @Test func testUnboundTexture() {
        let tools = FakeTools()
        tools.msl = cleanMSL()
        tools.msl[.frag] = "fragment F_out VVsFragFunc(F_in in [[stage_in]], constant VVISF_UNIFORMS& _2 [[buffer(0)]], texture2d<float> mine [[texture(0)]])\n"
        let dir = tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = checker(tools).check(path: "s.fs", workDirectory: dir)
        #expect(r.report.stage == .unbound)
        #expect(r.report.unbound == [UnboundArgument(name: "mine", kind: "texture", index: 0)])
    }

    @Test func testLintRunsLastAndCanBeDisabled() {
        let tools = FakeTools()
        tools.msl = cleanMSL()
        var doc = document
        doc.fragSource = "float kernel = 1.0;\nvoid main() {}\n"
        let dir = tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        var c = checker(tools, document: doc)
        #expect(c.check(path: "s.fs", workDirectory: dir).report.stage == .lint)
        c.options.lint = false
        #expect(c.check(path: "s.fs", workDirectory: dir).report.ok)
    }
}

@Suite struct UniformLayoutTests {
    @Test func testOffsetsAreShiftedPastRenderInfo() {
        // Offsets as ISFDoc reports them for line_space.fs.
        let doc = ISFDocumentInfo(
            maxUBOSize: 104,
            inputs: [ISFInput(name: "Items", type: "Float", offset: 32), ISFInput(name: "Clear", type: "Event", offset: 40)],
            passes: [ISFPass(target: "lineState", persistent: true, offset: 0), ISFPass(target: "")]
        )
        let layout = UniformLayout(document: doc)
        let custom = layout.entries.filter { $0.kind != .renderInfo }.map { "\($0.offset) \($0.name)" }
        #expect(custom == ["48 lineState", "80 Items", "88 Clear"])
    }

    @Test func testBufferSizeFollowsISFMSLScene() {
        #expect(UniformLayout(document: ISFDocumentInfo(maxUBOSize: 104)).bufferSize == 144)
        #expect(UniformLayout(document: ISFDocumentInfo(maxUBOSize: 96)).bufferSize == 144)
    }
}

@Suite struct UniformPackerTests {
    // Offsets as ISFDoc reports them for spiral_gratings.fs, cut down to three inputs.
    let doc = ISFDocumentInfo(
        maxUBOSize: 88,
        inputs: [
            ISFInput(name: "Speed", type: "Float", current: .number(0.4), offset: 0),
            ISFInput(name: "Type", type: "Long", current: .number(1), offset: 8),
            ISFInput(name: "Opacity", type: "Float", current: .number(1), offset: 36),
        ]
    )

    func read<T>(_ data: Data, _ offset: Int, as: T.Type) -> T {
        data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: T.self) }
    }

    @Test func testWritesRenderInfoAndInputsAtISFMSLSceneOffsets() {
        let frame = FrameInfo(passIndex: 2, time: 5, timeDelta: 1.0 / 60, frameIndex: 300, renderSize: RenderSize(width: 1920, height: 1440), date: SIMD4(2026, 11, 4, 3600))
        let data = UniformPacker.pack(document: doc, values: InputValues(document: doc).values, frame: frame)
        #expect(data.count == 96)
        #expect(read(data, 0, as: Int32.self) == 2)
        #expect(read(data, 4, as: Float.self) == 5)
        #expect(read(data, 8, as: Float.self) == 1920)
        #expect(read(data, 12, as: Float.self) == 1440)
        #expect(read(data, 16, as: Float.self) == 2026)
        #expect(read(data, 28, as: Float.self) == 3600)
        #expect(read(data, 32, as: Float.self) == Float(1.0 / 60))
        #expect(read(data, 36, as: Int32.self) == 300)
        #expect(read(data, 48, as: Float.self) == Float(0.4))
        #expect(read(data, 56, as: Int32.self) == 1)
        #expect(read(data, 84, as: Float.self) == 1)
    }

    @Test func testPacksVectorsAndBools() {
        let doc = ISFDocumentInfo(maxUBOSize: 80, inputs: [
            ISFInput(name: "On", type: "Bool", current: .bool(true), offset: 0),
            ISFInput(name: "Center", type: "Point2D", current: .vector([0.25, 0.75]), offset: 8),
            ISFInput(name: "Tint", type: "Color", current: .vector([0.1, 0.2, 0.3, 0.4]), offset: 16),
        ])
        let data = UniformPacker.pack(document: doc, values: InputValues(document: doc).values, frame: FrameInfo(renderSize: RenderSize(width: 1, height: 1)))
        #expect(read(data, 48, as: UInt32.self) == 1)
        #expect(read(data, 56, as: Float.self) == 0.25)
        #expect(read(data, 60, as: Float.self) == 0.75)
        #expect(read(data, 64 + 12, as: Float.self) == Float(0.4))
    }

    @Test func testClockFollowsFps() {
        let f = FrameInfo.at(frame: 150, fps: 30, renderSize: RenderSize(width: 2, height: 2))
        #expect(f.time == 5)
        #expect(f.frameIndex == 150)
        #expect(f.timeDelta == Float(1.0 / 30))
    }
}

@Suite struct ImageInfoPackingTests {
    @Test func testWritesRectSizeAndFlipForEveryKindOfTexture() {
        let doc = ISFDocumentInfo(
            maxUBOSize: 144,
            inputs: [ISFInput(name: "inputImage", type: "Image", offset: 64)],
            passes: [ISFPass(target: "state", persistent: true, offset: 32), ISFPass(target: "")],
            imports: [ISFImport(name: "logo", path: "/x.png", offset: 0)]
        )
        let images = ["logo": ImageInfo(width: 640, height: 480), "state": ImageInfo(width: 48, height: 1), "inputImage": ImageInfo(width: 64, height: 64)]
        let data = UniformPacker.pack(document: doc, values: [:], frame: FrameInfo(renderSize: RenderSize(width: 1, height: 1)), images: images)
        func float(_ o: Int) -> Float { data.withUnsafeBytes { $0.load(fromByteOffset: o, as: Float.self) } }
        func uint(_ o: Int) -> UInt32 { data.withUnsafeBytes { $0.load(fromByteOffset: o, as: UInt32.self) } }
        for (base, w, h) in [(48, 640, 480), (80, 48, 1), (112, 64, 64)] {
            #expect([float(base), float(base + 4), float(base + 8), float(base + 12)] == [0, 0, 1, 1])
            #expect(float(base + 16) == Float(w) && float(base + 20) == Float(h))
            #expect(uint(base + 24) == 1)
        }
    }
}

@Suite struct RenderPlanTests {
    @Test func testDrawsFromFrameZeroAndWritesFromAt() {
        let plan = RenderPlan(at: 0.5, fps: 60, frames: 3)
        #expect(plan.drawn == 0..<33)
        #expect(plan.written == 30..<33)
    }

    @Test func testOutputPaths() throws {
        #expect(try RenderPlan(at: 0, fps: 60, frames: 1).outputPaths(out: "a/b.png", shader: "x/s.fs").map(\.path).last!.hasSuffix("a/b.png"))
        let many = try RenderPlan(at: 1, fps: 60, frames: 2).outputPaths(out: "out", shader: "x/line_space.fs").map(\.lastPathComponent)
        #expect(many == ["line_space_00060.png", "line_space_00061.png"])
        #expect(throws: RenderError.self) { try RenderPlan(at: 0, fps: 60, frames: 2).outputPaths(out: "b.png", shader: "s.fs") }
    }
}

@Suite struct RecordingTests {
    let recording = try! Recording(jsonLines: """
    {"t": 0.0, "address": "/Filter 1", "value": 0.1}
    {"t": 1.0, "address": "/Filter 1", "value": 0.5}
    {"t": 0.5, "address": "/Filter 2", "value": 0.9}
    {"t": 2.0, "address": "/Filter 2", "value": 0.2}

    """)

    @Test func testHoldsTheLastValueAndLoops() {
        #expect(recording.duration == 2)
        #expect(recording.filterCount == 2)
        #expect(recording.sample("/Filter 1", at: 0.99) == 0.1)
        #expect(recording.sample("/Filter 1", at: 1.0) == 0.5)
        #expect(recording.sample("/Filter 1", at: 3.5) == 0.5, "3.5 is 1.5 into the second loop")
        #expect(recording.sample("/Filter 9", at: 0) == nil)
    }

    @Test func testBeforeTheFirstSampleUsesTheLastValue() {
        // As the preview's sampleTrack does: the loop still holds what the end of the previous pass left.
        #expect(recording.sample("/Filter 2", at: 0.2) == 0.2)
    }

    @Test func testRejectsMalformedLines() {
        #expect(throws: InputValueError.self) { try Recording(jsonLines: "{\"t\": 0}") }
    }
}

@Suite struct LevelDriverTests {
    let matcher = try! LevelMatcher()
    let recording = Recording(tracks: [
        "/Filter 1": .init(times: [0], values: [0.5]),
        "/Filter 2": .init(times: [0], values: [1.0]),
    ])

    func doc(levels: Int) -> ISFDocumentInfo {
        var inputs = (1...levels).map { ISFInput(name: "Level\($0)", type: "Float", min: .number(0.2), max: .number(0.8), current: .number(0)) }
        inputs.append(ISFInput(name: "LevelGain", type: "Float", max: .number(4), current: .number(1)))
        return ISFDocumentInfo(inputs: inputs)
    }

    @Test func testDefaultKeepsCurrentValues() throws {
        let d = try LevelDriver(document: doc(levels: 1), mode: .default, matcher: matcher)
        #expect(d.values(at: 0)["Level1"] == .number(0))
        #expect(!d.varies)
    }

    @Test func testMaxSetsLevelsButNotLevelGain() throws {
        let v = try LevelDriver(document: doc(levels: 2), mode: .max, matcher: matcher).values(at: 0)
        #expect(v["Level1"] == .number(0.8))
        #expect(v["LevelGain"] == .number(1))
    }

    @Test func testRecordingAssignsFiltersInOrderAndWraps() throws {
        let d = try LevelDriver(document: doc(levels: 3), mode: .recording, matcher: matcher, recording: recording)
        #expect(d.filters == ["Level1": "/Filter 1", "Level2": "/Filter 2", "Level3": "/Filter 1"])
        let v = d.values(at: 0)
        // value × (MAX − MIN) + MIN
        #expect(v["Level1"] == .number(0.5 * 0.6 + 0.2))
        #expect(v["Level2"] == .number(0.8))
        #expect(d.varies)
    }

    @Test func testSetWinsOverTheMode() throws {
        let v = try LevelDriver(document: doc(levels: 1), mode: .max, matcher: matcher, assignments: ["Level1=0.3"]).values(at: 0)
        #expect(v["Level1"] == .number(0.3))
    }

    @Test func testRecordingModeNeedsARecording() {
        #expect(throws: InputValueError.self) { try LevelDriver(document: doc(levels: 1), mode: .recording, matcher: matcher) }
    }
}

@Suite struct StatsTests {
    @Test func testSummary() throws {
        let s = try #require(Stats((1...20).map(Double.init)))
        #expect(s.median == 10.5)
        #expect(s.p95 == 19, "nearest rank: the 19th of 20")
        #expect(s.min == 1)
        #expect(s.mean == 10.5)
        #expect(abs(s.stddev - 5.766) < 0.001, "population standard deviation")
        #expect(Stats([]) == nil)
        #expect(Stats.median([3, 1, 2]) == 2)
    }
}

@Suite struct ResultsStoreTests {
    func result(_ shader: String, mode: LevelMode = .default, frames: Int = 240, median: Double) -> BenchResult {
        BenchResult(at: "2026-11-04T00:00:00Z", shader: shader, sha256: "", git: nil, size: [1920, 1440], fps: 60, mode: mode,
                    warmup: 60, frames: frames, repeat: 1, ms: Stats(median: median, p95: median, min: median, mean: median, stddev: 0),
                    repeats: nil, passes: 1, compile_ms: .init(glsl: 0, spirv_cross: 0, metal: 0), device: "GPU", isftool: "0")
    }

    @Test func testAppendsAndFindsTheLatestMatchingRun() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("isftool-\(UUID().uuidString)/results.jsonl")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ResultsStore(path: url.path)
        try store.append(result("a.fs", median: 2))
        try store.append(result("a.fs", mode: .max, median: 9))
        try store.append(result("a.fs", frames: 10, median: 7))
        try store.append(result("a.fs", median: 3))
        let history = store.load()
        #expect(history.count == 4)
        let previous = ResultsStore.previous(of: result("a.fs", median: 4), in: history)
        #expect(previous?.ms.median == 3)
        #expect(ResultsStore.previous(of: result("b.fs", median: 1), in: history) == nil)
        let row = BenchRow(shader: "a.fs", mode: "default", result: result("a.fs", median: 4.5), previous: previous)
        #expect(row.change == 50)
    }
}

@Suite struct BenchFormatterTests {
    @Test func testSortsSlowestFirstAndMarksBudgets() {
        let r = ResultsStoreTests()
        let rows = [
            BenchRow(shader: "light.fs", mode: "default", result: r.result("light.fs", median: 0.5)),
            BenchRow(shader: "broken.fs", mode: "-", note: "check failed"),
            BenchRow(shader: "heavy.fs", mode: "default", result: r.result("heavy.fs", median: 20)),
            BenchRow(shader: "mid.fs", mode: "default", result: r.result("mid.fs", median: 10)),
        ]
        let lines = BenchFormatter.format(BenchFormatter.sorted(rows, by: .median), compare: false).split(separator: "\n").map(String.init)
        #expect(lines[1].hasPrefix("!!") && lines[1].contains("heavy.fs"))
        #expect(lines[2].hasPrefix("! ") && lines[2].contains("mid.fs"))
        #expect(lines[3].contains("light.fs"))
        #expect(lines[4].contains("broken.fs") && lines[4].contains("check failed"))
    }
}

@Suite struct InputValuesTests {
    let doc = ISFDocumentInfo(inputs: [
        ISFInput(name: "Speed", type: "Float", default: .number(0.4), current: .number(0.4)),
        ISFInput(name: "Clear", type: "Event"),
        ISFInput(name: "Tint", type: "Color", current: .vector([0, 0, 0, 1])),
        ISFInput(name: "Center", type: "Point2D"),
        ISFInput(name: "inputImage", type: "Image"),
    ])

    @Test func testStartsFromCurrentValuesWithEventsOff() {
        let v = InputValues(document: doc)
        #expect(v.values["Speed"] == .number(0.4))
        #expect(v.values["Clear"] == .bool(false))
        #expect(v.values["inputImage"] == nil)
    }

    @Test func testSetParsesByType() throws {
        var v = InputValues(document: doc)
        try v.set("Speed=-2", document: doc)
        try v.set("Clear=1", document: doc)
        try v.set("Tint=1,0.5,0,1", document: doc)
        try v.set("Center=0.1, 0.9", document: doc)
        #expect(v.values["Speed"] == .number(-2))
        #expect(v.values["Clear"] == .bool(true))
        #expect(v.values["Tint"] == .vector([1, 0.5, 0, 1]))
        #expect(v.values["Center"] == .vector([0.1, 0.9]))
    }

    @Test func testSetRejectsBadInput() {
        var v = InputValues(document: doc)
        #expect(throws: InputValueError.self) { try v.set("Speed", document: doc) }
        #expect(throws: InputValueError.self) { try v.set("Nope=1", document: doc) }
        #expect(throws: InputValueError.self) { try v.set("Tint=1,0", document: doc) }
        #expect(throws: InputValueError.self) { try v.set("inputImage=1", document: doc) }
    }
}

@Suite struct RenderOutputTests {
    @Test func testQuadMatchesISFMSLScene() {
        #expect(Quad.vertices(width: 4, height: 3) == [SIMD4(0, 0, 0, 1), SIMD4(0, 3, 0, 1), SIMD4(4, 0, 0, 1), SIMD4(4, 3, 0, 1)])
    }

    @Test func testPNGKeepsStraightAlphaAndRowOrder() throws {
        // Top row: half transparent red. Bottom row: opaque blue. BGRA order.
        let image = RenderedImage(width: 1, height: 2, bgra: Data([0, 0, 255, 128, 255, 0, 0, 255]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("isftool-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try PNGWriter.write(image, to: url)
        let back = try #require(PNGReader.read(url))
        #expect(back.pixel(x: 0, y: 0) == (255, 0, 0, 128))
        #expect(back.pixel(x: 0, y: 1) == (0, 0, 255, 255))
    }
}

@Suite struct LevelMatcherTests {
    @Test func testDefaultPattern() throws {
        let m = try LevelMatcher()
        func level(_ name: String, _ type: String = "Float") -> Bool { m.isLevel(ISFInput(name: name, type: type)) }
        #expect(level("Level"))
        #expect(level("Level2"))
        #expect(level("LvBass"))
        #expect(!(level("LevelGain")))
        #expect(!(level("Levels")))
        #expect(!(level("Level", "Bool")))
    }
}

@Suite struct FormattingTests {
    @Test func testRenderSize() {
        #expect(RenderSize(parsing: "1920x1440") == RenderSize(width: 1920, height: 1440))
        #expect(RenderSize(parsing: "1920") == nil)
        #expect(RenderSize(parsing: "0x10") == nil)
    }

    @Test func testExcerptMarksLine() {
        let s = "a\nb\nc\nd\ne\n"
        #expect(SourceExcerpt.render(s, line: 3, context: 1) == "  2 | b\n> 3 | c\n  4 | d")
    }
}
