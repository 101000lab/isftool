import Foundation
import Metal

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

/// Draws an ISF shader the way ISFMSLScene does. Only shaders without named passes or textures are supported so far.
public final class Renderer {
    public let device: MTLDevice
    public let document: ISFDocumentInfo
    let pipeline: MTLRenderPipelineState
    let commandQueue: MTLCommandQueue
    let vertexBufferIndex: Int

    /// - Parameter artifacts: A successful check, with pass sizes evaluated at the output size.
    public init(artifacts: CheckArtifacts, device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else { throw RenderError(description: "no Metal device") }
        guard let document = artifacts.document,
              let vertMSL = artifacts.msl[.vert], let fragMSL = artifacts.msl[.frag],
              let vertSignature = artifacts.signatures[.vert], let fragSignature = artifacts.signatures[.frag]
        else { throw RenderError(description: "the shader did not get through check") }

        let targets = document.passes.map(\.target).filter { !$0.isEmpty }
        if !targets.isEmpty {
            throw RenderError(description: "passes with TARGET (\(targets.joined(separator: ", "))) are not supported yet")
        }
        let textures = Set(vertSignature.textures.keys).union(fragSignature.textures.keys)
        if !textures.isEmpty {
            throw RenderError(description: "image and audio inputs (\(textures.sorted().joined(separator: ", "))) are not supported yet")
        }

        self.device = device
        self.document = document
        guard let queue = device.makeCommandQueue() else { throw RenderError(description: "cannot create a command queue") }
        commandQueue = queue

        let compiler = try MetalLibraryCompiler(device: device)
        guard let vert = try compiler.makeLibrary(vertMSL).makeFunction(name: artifacts.entryPoints.vert),
              let frag = try compiler.makeLibrary(fragMSL).makeFunction(name: artifacts.entryPoints.frag)
        else { throw RenderError(description: "entry points \(artifacts.entryPoints.vert) / \(artifacts.entryPoints.frag) not found") }

        vertexBufferIndex = vertSignature.maxBufferIndex + 1
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float4
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = vertexBufferIndex
        // ISFMSLKit sets layouts[1] whatever the index is. That only works while the vertex function uses buffer 0 alone.
        vertexDescriptor.layouts[vertexBufferIndex].stride = MemoryLayout<SIMD4<Float>>.stride
        vertexDescriptor.layouts[vertexBufferIndex].stepFunction = .perVertex

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vert
        desc.fragmentFunction = frag
        desc.vertexDescriptor = vertexDescriptor
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            throw RenderError(description: "cannot create the pipeline: \(error.localizedDescription)")
        }
    }

    /// Size of the last pass, which is what VDMX shows. ISFGLSLGenerator leaves it 0 when sizes were not evaluated.
    public func outputSize(default size: RenderSize) -> RenderSize {
        guard let last = document.passes.last, last.width > 0, last.height > 0 else { return size }
        return RenderSize(width: Int(last.width), height: Int(last.height))
    }

    public func render(frame: FrameInfo, values: [String: ISFValue]) throws -> RenderedImage {
        let size = outputSize(default: frame.renderSize)
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size.width, height: size.height, mipmapped: false)
        texDesc.usage = [.renderTarget, .shaderRead]
        texDesc.storageMode = .shared
        guard let target = device.makeTexture(descriptor: texDesc),
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { throw RenderError(description: "cannot allocate a \(size) texture") }

        let passes = max(document.passes.count, 1)
        for passIndex in 0..<passes {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[0].loadAction = document.hasCustomVertShader ? .clear : .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                throw RenderError(description: "cannot create a render encoder")
            }
            encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(size.width), height: Double(size.height), znear: -1, zfar: 1))
            encoder.setRenderPipelineState(pipeline)
            let quad = Quad.vertices(width: size.width, height: size.height)
            encoder.setVertexBytes(quad, length: MemoryLayout<SIMD4<Float>>.stride * quad.count, index: vertexBufferIndex)

            var passFrame = frame
            passFrame.passIndex = Int32(passIndex)
            passFrame.renderSize = size
            let uniforms = UniformPacker.pack(document: document, values: values, frame: passFrame)
            // A new buffer per pass, as ISFMSLScene does, so each pass reads its own PASSINDEX when the GPU runs it.
            guard let buffer = uniforms.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) else {
                throw RenderError(description: "cannot allocate the uniform buffer")
            }
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setFragmentBuffer(buffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw RenderError(description: "GPU error: \(error.localizedDescription)")
        }

        var bytes = Data(count: size.width * size.height * 4)
        bytes.withUnsafeMutableBytes { raw in
            target.getBytes(raw.baseAddress!, bytesPerRow: size.width * 4, from: MTLRegionMake2D(0, 0, size.width, size.height), mipmapLevel: 0)
        }
        return RenderedImage(width: size.width, height: size.height, bgra: bytes)
    }
}
