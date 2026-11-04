import Foundation

/// The per-frame values of ISFShaderRenderInfo.
public struct FrameInfo: Equatable, Sendable {
    public var passIndex: Int32
    public var time: Float
    public var timeDelta: Float
    public var frameIndex: Int32
    public var renderSize: RenderSize
    /// year, month, day, seconds since local midnight
    public var date: SIMD4<Float>

    public init(passIndex: Int32 = 0, time: Float = 0, timeDelta: Float = 0, frameIndex: Int32 = 0, renderSize: RenderSize, date: SIMD4<Float> = .zero) {
        self.passIndex = passIndex
        self.time = time
        self.timeDelta = timeDelta
        self.frameIndex = frameIndex
        self.renderSize = renderSize
        self.date = date
    }

    /// Frame `index` of a clock ticking at `fps`, as design chapter 5 defines `--fps`.
    public static func at(frame index: Int, fps: Double, renderSize: RenderSize, date: SIMD4<Float> = .zero) -> FrameInfo {
        FrameInfo(time: Float(Double(index) / fps), timeDelta: Float(1 / fps), frameIndex: Int32(index), renderSize: renderSize, date: date)
    }

    /// ISFMSLScene fills DATE from the local clock on every frame.
    public static func localDate(_ now: Date = Date(), calendar: Calendar = .current) -> SIMD4<Float> {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        let seconds = (c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0)
        return SIMD4(Float(c.year ?? 0), Float(c.month ?? 0), Float(c.day ?? 0), Float(seconds))
    }
}

public struct InputValueError: Error, CustomStringConvertible, Sendable {
    public var description: String
}

/// Input values for one frame: each input's current value from ISFGLSLGenerator, then `--set` overrides.
public struct InputValues: Equatable, Sendable {
    public var values: [String: ISFValue]

    public init(document: ISFDocumentInfo) {
        var values: [String: ISFValue] = [:]
        for input in document.inputs where !input.usesImage {
            // Events stay false unless set, so a render never depends on when an event happened to fire (design chapter 6).
            values[input.name] = input.type == "Event" ? .bool(false) : (input.current ?? input.default)
        }
        self.values = values
    }

    /// Applies `NAME=VALUE`. Color is `r,g,b,a` and Point2D is `x,y`.
    public mutating func set(_ assignment: String, document: ISFDocumentInfo) throws {
        guard let eq = assignment.firstIndex(of: "=") else {
            throw InputValueError(description: "expected NAME=VALUE, got '\(assignment)'")
        }
        let name = String(assignment[..<eq])
        let text = String(assignment[assignment.index(after: eq)...])
        guard let input = document.inputs.first(where: { $0.name == name }) else {
            throw InputValueError(description: "no input named '\(name)'")
        }
        let parts = text.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        func numbers(_ count: Int) throws -> [Double] {
            let parsed = parts.compactMap(Double.init)
            guard parsed.count == count, parts.count == count else {
                throw InputValueError(description: "\(name) is \(input.type) and needs \(count) number\(count == 1 ? "" : "s"), got '\(text)'")
            }
            return parsed
        }
        switch input.type {
        case "Event", "Bool":
            switch text.lowercased() {
            case "1", "true", "yes", "on": values[name] = .bool(true)
            case "0", "false", "no", "off": values[name] = .bool(false)
            default: throw InputValueError(description: "\(name) is \(input.type) and needs true or false, got '\(text)'")
            }
        case "Long", "Float": values[name] = .number(try numbers(1)[0])
        case "Point2D": values[name] = .vector(try numbers(2))
        case "Color": values[name] = .vector(try numbers(4))
        default: throw InputValueError(description: "\(name) is \(input.type) and cannot be set from the command line")
        }
    }
}

/// What ISFMSLScene writes into an ISFShaderImgInfo for a texture.
public struct ImageInfo: Equatable, Sendable {
    public var width: Int
    public var height: Int
    /// 1 for every texture ISFMSLScene binds (VVMTLTextureImage.flipV is NO for pool and MTKTextureLoader textures).
    /// The generated GLSL then reads with a bottom-left origin from a texture whose first row is the top.
    public var flip: Bool

    public init(width: Int, height: Int, flip: Bool = true) {
        self.width = width
        self.height = height
        self.flip = flip
    }
}

/// Builds the bytes of VVISF_UNIFORMS the way ISFMSLScene writes them.
public enum UniformPacker {
    /// - Parameter images: Keyed by input, IMPORTED or pass TARGET name. Names without an entry keep zeros, as an unbound texture would.
    public static func pack(document: ISFDocumentInfo, values: [String: ISFValue], frame: FrameInfo, images: [String: ImageInfo] = [:]) -> Data {
        let layout = UniformLayout(document: document)
        var data = Data(count: layout.bufferSize)
        data.withUnsafeMutableBytes { raw in
            func put<T>(_ value: T, at offset: Int) {
                guard offset + MemoryLayout<T>.size <= raw.count else { return }
                raw.storeBytes(of: value, toByteOffset: offset, as: T.self)
            }
            put(frame.passIndex, at: 0)
            put(frame.time, at: 4)
            put(Float(frame.renderSize.width), at: 8)
            put(Float(frame.renderSize.height), at: 12)
            for i in 0..<4 { put(frame.date[i], at: 16 + i * 4) }
            put(frame.timeDelta, at: 32)
            put(frame.frameIndex, at: 36)

            let base = Int(UniformLayout.renderInfoSize)
            func putImage(_ name: String, relative: UInt32?) {
                guard let relative, let info = images[name] else { return }
                let offset = base + Int(relative)
                for (i, v) in [Float(0), 0, 1, 1].enumerated() { put(v, at: offset + i * 4) }
                put(Float(info.width), at: offset + 16)
                put(Float(info.height), at: offset + 20)
                put(UInt32(info.flip ? 1 : 0), at: offset + 24)
            }
            for imp in document.imports { putImage(imp.name, relative: imp.offset) }
            for pass in document.passes where !pass.target.isEmpty { putImage(pass.target, relative: pass.offset) }
            for input in document.inputs where input.usesImage && input.type != "Cube" { putImage(input.name, relative: input.offset) }

            for input in document.inputs {
                guard let relative = input.offset else { continue }
                let offset = base + Int(relative)
                let components = values[input.name]?.components ?? []
                func component(_ i: Int) -> Double { i < components.count ? components[i] : 0 }
                switch input.type {
                case "Event", "Bool": put(UInt32(component(0) != 0 ? 1 : 0), at: offset)
                case "Long": put(Int32(component(0).clamped(to: Double(Int32.min)...Double(Int32.max)).rounded(.towardZero)), at: offset)
                case "Float": put(Float(component(0)), at: offset)
                case "Point2D": for i in 0..<2 { put(Float(component(i)), at: offset + i * 4) }
                case "Color": for i in 0..<4 { put(Float(component(i)), at: offset + i * 4) }
                default: break
                }
            }
        }
        return data
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        isNaN ? 0 : Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
