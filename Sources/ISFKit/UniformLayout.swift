import Foundation

/// Byte layout of the VVISF_UNIFORMS block, built from the offsets ISFGLSLGenerator assigns.
public struct UniformLayout: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public enum Kind: String, Sendable {
            case renderInfo
            case imageInfo
            case input
        }

        public var name: String
        public var kind: Kind
        /// Absolute offset from the start of the buffer.
        public var offset: UInt32
        public var size: UInt32
        public var glslType: String
    }

    /// sizeof(ISFShaderRenderInfo)
    public static let renderInfoSize: UInt32 = 48
    /// sizeof(ISFShaderImgInfo)
    public static let imageInfoSize: UInt32 = 32

    public static let renderInfoEntries: [Entry] = [
        Entry(name: "PASSINDEX", kind: .renderInfo, offset: 0, size: 4, glslType: "int"),
        Entry(name: "TIME", kind: .renderInfo, offset: 4, size: 4, glslType: "float"),
        Entry(name: "RENDERSIZE", kind: .renderInfo, offset: 8, size: 8, glslType: "vec2"),
        Entry(name: "DATE", kind: .renderInfo, offset: 16, size: 16, glslType: "vec4"),
        Entry(name: "TIMEDELTA", kind: .renderInfo, offset: 32, size: 4, glslType: "float"),
        Entry(name: "FRAMEINDEX", kind: .renderInfo, offset: 36, size: 4, glslType: "int"),
        Entry(name: "PADDING_INFO", kind: .renderInfo, offset: 40, size: 8, glslType: "vec2"),
    ]

    public var entries: [Entry]
    public var maxUBOSize: UInt32

    public init(document: ISFDocumentInfo) {
        var entries = Self.renderInfoEntries
        let base = Self.renderInfoSize
        for imp in document.imports {
            if let o = imp.offset { entries.append(Entry(name: imp.name, kind: .imageInfo, offset: base + o, size: Self.imageInfoSize, glslType: "ISFShaderImgInfo")) }
        }
        for pass in document.passes where !pass.target.isEmpty {
            if let o = pass.offset { entries.append(Entry(name: pass.target, kind: .imageInfo, offset: base + o, size: Self.imageInfoSize, glslType: "ISFShaderImgInfo")) }
        }
        for input in document.inputs {
            guard let o = input.offset, let (size, type) = Self.storage(forType: input.type) else { continue }
            entries.append(Entry(name: input.name, kind: input.usesImage ? .imageInfo : .input, offset: base + o, size: size, glslType: type))
        }
        self.entries = entries.sorted { $0.offset < $1.offset }
        maxUBOSize = document.maxUBOSize
    }

    /// The MTLBuffer size ISFMSLScene allocates. It always adds a block, even when maxUBOSize is already a multiple of 48.
    public var bufferSize: Int {
        let block = Int(Self.renderInfoSize)
        let size = Int(maxUBOSize)
        return size + (block - size % block)
    }

    static func storage(forType type: String) -> (UInt32, String)? {
        switch type {
        case "Event", "Bool": return (4, "bool")
        case "Long": return (4, "int")
        case "Float": return (4, "float")
        case "Point2D": return (8, "vec2")
        case "Color": return (16, "vec4")
        case "Image", "Audio", "AudioFFT": return (imageInfoSize, "ISFShaderImgInfo")
        case "Cube": return (16, "ISFShaderCubeInfo")
        default: return nil
        }
    }
}

/// Decides which inputs are audio Level inputs (design chapter 6).
public struct LevelMatcher: Sendable {
    public static let defaultPattern = "^(Level|Lv)(?![a-z]|Gain$)"

    private let regex: NSRegularExpression

    public init(pattern: String = defaultPattern) throws {
        regex = try NSRegularExpression(pattern: pattern)
    }

    public func isLevel(_ input: ISFInput) -> Bool {
        guard input.type == "Float" else { return false }
        return regex.firstMatch(in: input.name, range: NSRange(input.name.startIndex..., in: input.name)) != nil
    }
}
