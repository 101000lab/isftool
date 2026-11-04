import Foundation
import Testing
@testable import ISFKit

let installedToolchain: Toolchain? = {
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin"
    return try? Toolchain.locate(environment: env)
}()

/// Runs the real ISFGLSLGenerator, Homebrew glslang/spirv-cross and Metal.
@Suite(.enabled(if: installedToolchain != nil, "glslang or spirv-cross not installed"))
final class IntegrationTests {
    let toolchain = installedToolchain!
    let workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("isftool-it-\(UUID().uuidString)")

    deinit {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    func fixture(_ name: String) -> String {
        Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)!.path
    }

    func check(_ name: String, lint: Bool = true) throws -> CheckResult {
        let dir = workDirectory.appendingPathComponent(UUID().uuidString)
        let checker = Checker(toolchain: toolchain, metal: try MetalLibraryCompiler(), options: CheckOptions(lint: lint))
        return checker.check(path: fixture(name), workDirectory: dir)
    }

    /// Comments and whitespace differ between the generator output and the copy from VDMX's screen.
    func normalized(_ s: String) -> String {
        Lint.stripComments(s).filter { !$0.isWhitespace }
    }

    // M1 condition 0
    @Test func testGeneratedGLSLMatchesVDMX() throws {
        let generated = try ISFDocument(path: fixture("line_space_layout.fs")).generate()
        let vdmxVert = try String(contentsOfFile: fixture("vdmx_line_space.vert.glsl"), encoding: .utf8)
        let vdmxFrag = try String(contentsOfFile: fixture("vdmx_line_space.frag.glsl"), encoding: .utf8)
        #expect(normalized(generated.vert) == normalized(vdmxVert))
        #expect(normalized(generated.frag).hasPrefix(normalized(vdmxFrag)))
    }

    // M1 condition 1
    @Test func testCurrentLineSpacePasses() throws {
        let r = try check("line_space.fs")
        #expect(r.report.ok, Comment(rawValue: CheckFormatter.format(r)))
    }

    // M1 conditions 2 and 6
    @Test func testLayoutVariableFailsInGLSLWithSourceLine() throws {
        let r = try check("line_space_layout.fs")
        #expect(r.report.stage == .glsl)
        let d = try #require(r.report.diagnostics.first)
        #expect(d.message.contains("unexpected LAYOUT"))
        #expect(d.line == 111, "same number as VDMX's error screen")
        #expect(d.sourceLine == 90)
        let line = try String(contentsOfFile: fixture("line_space_layout.fs"), encoding: .utf8).components(separatedBy: "\n")[89]
        #expect(line.contains("float layout ="))
    }

    // M1 condition 3
    @Test func testLayoutInputNameFails() throws {
        let r = try check("thin_barcode_layout.fs")
        #expect(r.report.stage == .glsl)
        #expect(r.report.diagnostics.contains { $0.message.contains("unexpected LAYOUT") })
    }

    // M1 condition 4
    @Test func testVertexFunctionFailsLint() throws {
        let r = try check("super_polygons_vertex.fs")
        #expect(r.report.stage == .lint)
        #expect(r.report.lint.first?.line == 54)
    }

    /// Records what Homebrew's toolchain does without the lint (design 2.5): SPIRV-Cross renames `vertex` and Metal accepts it.
    @Test func testVertexFunctionPassesHomebrewToolchainWithoutLint() throws {
        let r = try check("super_polygons_vertex.fs", lint: false)
        #expect(r.report.ok, Comment(rawValue: CheckFormatter.format(r)))
        #expect(r.artifacts.msl[.frag]?.contains("vertex0(") ?? false)
    }

    // M1 condition 7
    @Test func testReflectOffsetsMatchGenerator() throws {
        let r = try check("line_space.fs")
        let doc = try #require(r.artifacts.document)
        let reflect = try toolchain.reflect(spirv: try #require(r.artifacts.spirvPaths[.frag]))
        let json = try JSONSerialization.jsonObject(with: Data(reflect.stdout.utf8)) as! [String: Any]
        let types = json["types"] as! [String: [String: Any]]
        let block = types.values.first { $0["name"] as? String == "VVISF_UNIFORMS" }!
        var reflected: [String: Int] = [:]
        for m in block["members"] as! [[String: Any]] {
            reflected[m["name"] as! String] = m["offset"] as? Int
        }
        for input in doc.inputs {
            #expect(reflected[input.name] == Int(UniformLayout.renderInfoSize + input.offset!), Comment(rawValue: input.name))
        }
        for pass in doc.passes where !pass.target.isEmpty {
            #expect(reflected["_\(pass.target)_imgRect"] == Int(UniformLayout.renderInfoSize + pass.offset!), Comment(rawValue: pass.target))
        }
    }

    @Test func testPassSizesEvaluate() throws {
        let doc = try ISFDocument(path: fixture("line_space.fs"))
        try doc.evalPassSizes(width: 1920, height: 1440)
        let passes = try doc.describe().passes
        #expect(passes.map { "\($0.target) \($0.width)x\($0.height) \($0.persistent)" } == ["lineState 4x1 true", " 1920x1440 false"])
    }

    func renderer(_ name: String, size: RenderSize) throws -> (Renderer, ISFDocumentInfo) {
        let checker = Checker(source: ISFGLSLGeneratorSource(renderSize: size), toolchain: toolchain, metal: nil, options: CheckOptions(metal: false))
        let result = checker.check(path: fixture(name), workDirectory: workDirectory.appendingPathComponent(UUID().uuidString))
        try #require(result.report.ok, Comment(rawValue: CheckFormatter.format(result)))
        let document = try #require(result.artifacts.document)
        return (try Renderer(artifacts: result.artifacts, sizer: try ISFPassSizer(path: fixture(name))), document)
    }

    /// Renders frames 0 through `frame` and returns the last one.
    func render(_ name: String, size: RenderSize = RenderSize(width: 64, height: 48), frame: Int = 0, set: [String] = []) throws -> RenderedImage {
        let (renderer, document) = try renderer(name, size: size)
        var values = InputValues(document: document)
        for s in set { try values.set(s, document: document) }
        let frames = (0...frame).map { FrameInfo.at(frame: $0, fps: 60, renderSize: size) }
        var last: RenderedImage?
        try renderer.renderFrames(frames: frames, values: values.values, capture: frames.map { $0.frameIndex == frame }) { _, image in last = image }
        return try #require(last)
    }

    func expectTopHalfWhite(_ image: RenderedImage) {
        for x in [2, image.width - 3] {
            #expect(image.pixel(x: x, y: 2) == (255, 255, 255, 255), "top at x \(x)")
            #expect(image.pixel(x: x, y: image.height - 3) == (0, 0, 0, 0), "bottom at x \(x)")
        }
    }

    /// Design 7.3: normalized y = 1 must be the top row of the PNG and x = 1 the right column, with no flip anywhere.
    @Test func testRenderFacesTheSameWayAsISF() throws {
        let image = try render("orientation.fs")
        #expect(image.width == 64 && image.height == 48)
        #expect(image.pixel(x: 0, y: 0) == (0, 255, 0, 255), "top left is green")
        #expect(image.pixel(x: 63, y: 0) == (255, 255, 0, 255), "top right is yellow")
        #expect(image.pixel(x: 0, y: 47) == (0, 0, 0, 255), "bottom left is black")
        #expect(image.pixel(x: 63, y: 47) == (255, 0, 0, 255), "bottom right is red")
    }

    @Test func testRenderAppliesInputValues() throws {
        let image = try render("orientation.fs", set: ["Tint=0,0,1,1"])
        #expect(image.pixel(x: 0, y: 47) == (0, 0, 255, 255))
    }

    /// Design 7.3 and M3: with _flip = 1, as ISFMSLScene writes it, a persistent buffer read back keeps its top half on top.
    @Test func testPersistentBufferKeepsOrientationAcrossFrames() throws {
        expectTopHalfWhite(try render("persistent_orientation.fs", frame: 10))
    }

    @Test func testImportedImageKeepsOrientation() throws {
        expectTopHalfWhite(try render("imported_orientation.fs"))
    }

    @Test func testFloatBufferKeepsSmallSteps() throws {
        // 100 frames of +0.001 is 0.1, which is 25.5 in 8 bits.
        let float = try render("float_accumulate.fs", frame: 99)
        #expect((25...26).contains(float.pixel(x: 10, y: 10).0), "float buffer: \(float.pixel(x: 10, y: 10))")
        let byte = try render("byte_accumulate.fs", frame: 99)
        #expect(byte.pixel(x: 10, y: 10).0 == 0, "8 bit buffer rounds +0.001 away")
    }

    /// ISFMSLScene copies a FLOAT last pass into the 8 bit render target, stretched to the render size.
    @Test func testFloatLastPassIsCopiedToOutputSize() throws {
        let image = try render("float_output.fs", frame: 99)
        #expect(image.width == 64 && image.height == 48)
        let left = image.pixel(x: 5, y: 24)
        let right = image.pixel(x: 58, y: 24)
        #expect(left.0 == 255 && right.0 == 0, "left \(left), right \(right)")
        #expect((25...26).contains(left.1), "green accumulated in float: \(left)")
    }

    @Test func testPassSizesFollowExpressions() throws {
        let sizes = try ISFPassSizer(path: fixture("line_space.fs")).passSizes(values: [:], renderSize: RenderSize(width: 640, height: 360))
        #expect(sizes == [RenderSize(width: 4, height: 1), RenderSize(width: 640, height: 360)])
    }

    @Test func testBridgeReportsParseErrors() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("broken-\(UUID().uuidString).fs").path
        try "/*{ \"INPUTS\": [ }*/\nvoid main() {}\n".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(throws: (any Error).self) { try ISFDocument(path: path) }
    }
}
