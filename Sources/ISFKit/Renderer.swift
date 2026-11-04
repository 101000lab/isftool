import Foundation
import Metal
import MetalKit

/// ISFMSLScene's quad for one pass: pixel coordinates with z 0 and w 1, drawn as a 4-vertex triangle strip.
public enum Quad {
    public static func vertices(width: Int, height: Int) -> [SIMD4<Float>] {
        let w = Float(width)
        let h = Float(height)
        return [SIMD4(0, 0, 0, 1), SIMD4(0, h, 0, 1), SIMD4(w, 0, 0, 1), SIMD4(w, h, 0, 1)]
    }
}

public struct RenderError: Error, CustomStringConvertible, Sendable {
    public var description: String
}

/// Evaluates pass WIDTH and HEIGHT for the current input values.
public protocol PassSizing {
    func passSizes(values: [String: ISFValue], renderSize: RenderSize) throws -> [RenderSize]
}

/// Lets ISFGLSLGenerator's exprtk evaluate the expressions, with the inputs as variables.
public final class ISFPassSizer: PassSizing {
    let document: ISFDocument
    let inputs: [ISFInput]

    public init(path: String) throws {
        document = try ISFDocument(path: path)
        inputs = try document.describe().inputs
    }

    public func passSizes(values: [String: ISFValue], renderSize: RenderSize) throws -> [RenderSize] {
        for input in inputs where !input.usesImage {
            if let v = values[input.name] { try document.setInput(input.name, v.components) }
        }
        try document.evalPassSizes(width: renderSize.width, height: renderSize.height)
        return try document.describe().passes.map {
            $0.width > 0 && $0.height > 0 ? RenderSize(width: Int($0.width), height: Int($0.height)) : renderSize
        }
    }
}

/// Draws an ISF shader frame after frame the way ISFMSLScene does, keeping pass textures between frames.
public final class Renderer {
    public let device: MTLDevice
    public let document: ISFDocumentInfo
    let sizer: PassSizing
    let commandQueue: MTLCommandQueue
    let vertexFunction: MTLFunction
    let fragmentFunction: MTLFunction
    let vertexDescriptor: MTLVertexDescriptor
    let vertexBufferIndex: Int
    let vertSignature: MSLSignature
    let fragSignature: MSLSignature
    let sampler: MTLSamplerState
    var pipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    var copier: MTLComputePipelineState?
    var copyTarget: MTLTexture?

    /// IMPORTED images and stand-ins for image and audio inputs, by name.
    var fixedTextures: [String: MTLTexture] = [:]
    /// What each pass rendered last, which the next frame reads (and the current frame, for passes not yet drawn).
    var current: [MTLTexture?]
    /// The other texture of each pass, rendered into while `current` is bound.
    var spare: [MTLTexture?]
    var sizes: [RenderSize] = []
    var sizedFor: (values: [String: ISFValue], renderSize: RenderSize)?

    /// - Parameter artifacts: A successful check of the shader.
    public init(artifacts: CheckArtifacts, sizer: PassSizing, device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else { throw RenderError(description: "no Metal device") }
        guard let document = artifacts.document,
              let vertMSL = artifacts.msl[.vert], let fragMSL = artifacts.msl[.frag],
              let vertSignature = artifacts.signatures[.vert], let fragSignature = artifacts.signatures[.frag]
        else { throw RenderError(description: "the shader did not get through check") }
        if document.inputs.contains(where: { $0.type == "Cube" }) {
            throw RenderError(description: "cube inputs are not supported (ISFMSLKit does not implement them either)")
        }

        self.device = device
        self.document = document
        self.sizer = sizer
        self.vertSignature = vertSignature
        self.fragSignature = fragSignature
        guard let queue = device.makeCommandQueue() else { throw RenderError(description: "cannot create a command queue") }
        commandQueue = queue

        let compiler = try MetalLibraryCompiler(device: device)
        guard let vert = try compiler.makeLibrary(vertMSL).makeFunction(name: artifacts.entryPoints.vert),
              let frag = try compiler.makeLibrary(fragMSL).makeFunction(name: artifacts.entryPoints.frag)
        else { throw RenderError(description: "entry points \(artifacts.entryPoints.vert) / \(artifacts.entryPoints.frag) not found") }
        vertexFunction = vert
        fragmentFunction = frag

        vertexBufferIndex = vertSignature.maxBufferIndex + 1
        vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float4
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = vertexBufferIndex
        // ISFMSLKit sets layouts[1] whatever the index is. That only works while the vertex function uses buffer 0 alone.
        vertexDescriptor.layouts[vertexBufferIndex].stride = MemoryLayout<SIMD4<Float>>.stride
        vertexDescriptor.layouts[vertexBufferIndex].stepFunction = .perVertex

        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.normalizedCoordinates = true
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDesc) else { throw RenderError(description: "cannot create a sampler") }
        self.sampler = sampler

        let passCount = max(document.passes.count, 1)
        current = Array(repeating: nil, count: passCount)
        spare = Array(repeating: nil, count: passCount)

        try loadFixedTextures()
    }

    func loadFixedTextures() throws {
        let loader = MTKTextureLoader(device: device)
        for imp in document.imports {
            do {
                // The same loader and options as ISFMSLScene, so the pixel format and row order match VDMX.
                fixedTextures[imp.name] = try loader.newTexture(URL: URL(fileURLWithPath: imp.path), options: [.SRGB: false])
            } catch {
                throw RenderError(description: "cannot load IMPORTED \(imp.name) from \(imp.path): \(error.localizedDescription)")
            }
        }
        // ISFMSLScene gives image and audio inputs without a source an empty 64x64 BGRA8 texture.
        let empty = document.inputs.filter(\.usesImage)
        if !empty.isEmpty {
            let blank = try makeTexture(width: 64, height: 64, format: .bgra8Unorm, clearIn: nil)
            let zeros = [UInt8](repeating: 0, count: 64 * 64 * 4)
            blank.replace(region: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0, withBytes: zeros, bytesPerRow: 64 * 4)
            for input in empty { fixedTextures[input.name] = blank }
        }
    }

    func pipeline(for format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        if let p = pipelines[format] { return p }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFunction
        desc.fragmentFunction = fragmentFunction
        desc.vertexDescriptor = vertexDescriptor
        desc.colorAttachments[0].pixelFormat = format
        do {
            let p = try device.makeRenderPipelineState(descriptor: desc)
            pipelines[format] = p
            return p
        } catch {
            throw RenderError(description: "cannot create the pipeline: \(error.localizedDescription)")
        }
    }

    func format(ofPass index: Int) -> MTLPixelFormat {
        index < document.passes.count && document.passes[index].float ? .rgba32Float : .bgra8Unorm
    }

    /// - Parameter clearIn: When given, the texture is cleared to transparent black in this command buffer.
    func makeTexture(width: Int, height: Int, format: MTLPixelFormat, clearIn commandBuffer: MTLCommandBuffer?) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = commandBuffer == nil ? .shared : .private
        guard let texture = device.makeTexture(descriptor: desc) else {
            throw RenderError(description: "cannot allocate a \(width)x\(height) texture")
        }
        if let commandBuffer {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[0].storeAction = .store
            commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }
        return texture
    }

    static func fits(_ texture: MTLTexture?, _ size: RenderSize, _ format: MTLPixelFormat) -> Bool {
        guard let texture else { return false }
        return texture.width == size.width && texture.height == size.height && texture.pixelFormat == format
    }

    /// Port of VVMetalKit's CopierMTLSceneFunc. ISFMSLScene asks for SizingModeFit, but CopierMTLScene never reads
    /// the sizing mode and stretches the whole source over the whole destination.
    static let copierSource = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void isftoolCopy(texture2d<float, access::sample> src [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float2 norm = float2(gid) / (float2(dst.get_width(), dst.get_height()) - 1.0);
        float2 px = norm * (float2(src.get_width(), src.get_height()) - 1.0) + 0.5;
        constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge, coord::pixel);
        dst.write(src.sample(s, px), gid);
    }
    """

    func copyPipeline() throws -> MTLComputePipelineState {
        if let copier { return copier }
        guard let function = try MetalLibraryCompiler(device: device).makeLibrary(Self.copierSource).makeFunction(name: "isftoolCopy") else {
            throw RenderError(description: "cannot build the float to 8 bit copy")
        }
        let p = try device.makeComputePipelineState(function: function)
        copier = p
        return p
    }

    /// The scene's render target is 8 bit, so ISFMSLScene copies a FLOAT last pass into it instead of drawing there.
    func encodeCopy(from source: MTLTexture, size: RenderSize, into commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
        if copyTarget == nil || copyTarget!.width != size.width || copyTarget!.height != size.height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size.width, height: size.height, mipmapped: false)
            desc.usage = [.shaderWrite, .shaderRead]
            desc.storageMode = .private
            guard let t = device.makeTexture(descriptor: desc) else { throw RenderError(description: "cannot allocate the output texture") }
            copyTarget = t
        }
        let pipeline = try copyPipeline()
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw RenderError(description: "cannot create a compute encoder") }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(copyTarget, index: 1)
        // The same square threadgroups and group count as VVMTLComputeScene.
        let side = Int(Double(pipeline.maxTotalThreadsPerThreadgroup).squareRoot())
        encoder.dispatchThreadgroups(MTLSize(width: size.width / side + 1, height: size.height / side + 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: side, height: side, depth: 1))
        encoder.endEncoding()
        return copyTarget!
    }

    /// Encodes one frame and returns the 8 bit texture that VDMX would show.
    public func encode(frame: FrameInfo, values: [String: ISFValue], into commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
        if sizedFor == nil || sizedFor!.values != values || sizedFor!.renderSize != frame.renderSize {
            sizes = try sizer.passSizes(values: values, renderSize: frame.renderSize)
            sizedFor = (values, frame.renderSize)
        }
        let passCount = current.count
        func size(ofPass i: Int) -> RenderSize { i < sizes.count ? sizes[i] : frame.renderSize }
        func name(ofPass i: Int) -> String { i < document.passes.count ? document.passes[i].target : "" }

        // Persistent buffers start black. A resized buffer starts over, as ISFMSLScene allocates a new texture for it.
        for i in 0..<passCount where !name(ofPass: i).isEmpty && !Self.fits(current[i], size(ofPass: i), format(ofPass: i)) {
            let s = size(ofPass: i)
            current[i] = try makeTexture(width: s.width, height: s.height, format: format(ofPass: i), clearIn: commandBuffer)
        }

        var bound = fixedTextures
        for i in 0..<passCount where !name(ofPass: i).isEmpty {
            bound[name(ofPass: i)] = current[i]
        }

        var output: MTLTexture?
        for i in 0..<passCount {
            let s = size(ofPass: i)
            let fmt = format(ofPass: i)
            if !Self.fits(spare[i], s, fmt) {
                spare[i] = try makeTexture(width: s.width, height: s.height, format: fmt, clearIn: commandBuffer)
            }
            let target = spare[i]!

            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[0].loadAction = document.hasCustomVertShader ? .clear : .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                throw RenderError(description: "cannot create a render encoder")
            }
            encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(s.width), height: Double(s.height), znear: -1, zfar: 1))
            encoder.setRenderPipelineState(try pipeline(for: fmt))
            let quad = Quad.vertices(width: s.width, height: s.height)
            encoder.setVertexBytes(quad, length: MemoryLayout<SIMD4<Float>>.stride * quad.count, index: vertexBufferIndex)

            for (texName, index) in vertSignature.textures { if let t = bound[texName] { encoder.setVertexTexture(t, index: index) } }
            for (texName, index) in fragSignature.textures { if let t = bound[texName] { encoder.setFragmentTexture(t, index: index) } }
            for index in vertSignature.samplers.values { encoder.setVertexSamplerState(sampler, index: index) }
            for index in fragSignature.samplers.values { encoder.setFragmentSamplerState(sampler, index: index) }

            var passFrame = frame
            passFrame.passIndex = Int32(i)
            passFrame.renderSize = s
            let images = bound.mapValues { ImageInfo(width: $0.width, height: $0.height) }
            let uniforms = UniformPacker.pack(document: document, values: values, frame: passFrame, images: images)
            // A new buffer per pass, as ISFMSLScene does, so each pass reads its own PASSINDEX when the GPU runs it.
            guard let buffer = uniforms.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) else {
                throw RenderError(description: "cannot allocate the uniform buffer")
            }
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setFragmentBuffer(buffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()

            // Later passes in this frame, and every pass in the next frame, read what this pass just drew.
            spare[i] = current[i]
            current[i] = target
            if !name(ofPass: i).isEmpty { bound[name(ofPass: i)] = target }
            output = target
        }
        if output!.pixelFormat == .rgba32Float {
            return try encodeCopy(from: output!, size: frame.renderSize, into: commandBuffer)
        }
        return output!
    }

    /// Renders one frame and waits for it.
    public func render(frame: FrameInfo, values: [String: ISFValue]) throws -> RenderedImage {
        var result: RenderedImage?
        try renderFrames(frames: [frame], values: values, capture: [true]) { _, image in result = image }
        return result!
    }

    /// Renders frames in order and hands each one marked in `capture` to `handle` as soon as the GPU finishes it.
    /// Frames are handed over one at a time so a long run does not keep every readback alive.
    public func renderFrames(frames: [FrameInfo], values: [String: ISFValue], capture: [Bool], handle: (Int, RenderedImage) throws -> Void) throws {
        try renderFrames(frames: frames, values: { _ in values }, capture: capture, handle: handle)
    }

    /// - Parameter values: The input values for each frame, for Level inputs that follow a recording.
    public func renderFrames(frames: [FrameInfo], values: (FrameInfo) -> [String: ISFValue], capture: [Bool], handle: (Int, RenderedImage) throws -> Void) throws {
        for (n, frame) in frames.enumerated() {
            guard let commandBuffer = commandQueue.makeCommandBuffer() else { throw RenderError(description: "cannot create a command buffer") }
            let output = try encode(frame: frame, values: values(frame), into: commandBuffer)
            guard capture[n] else {
                commandBuffer.commit()
                continue
            }
            let bpp = 4
            guard let readback = device.makeBuffer(length: output.width * output.height * bpp, options: .storageModeShared),
                  let blit = commandBuffer.makeBlitCommandEncoder()
            else { throw RenderError(description: "cannot read back the frame") }
            blit.copy(from: output, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: output.width, height: output.height, depth: 1),
                      to: readback, destinationOffset: 0, destinationBytesPerRow: output.width * bpp, destinationBytesPerImage: output.width * output.height * bpp)
            blit.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            if let error = commandBuffer.error { throw RenderError(description: "GPU error: \(error.localizedDescription)") }
            try handle(n, RenderedImage(width: output.width, height: output.height, bgra: Data(bytes: readback.contents(), count: output.width * output.height * 4)))
        }
    }
}
