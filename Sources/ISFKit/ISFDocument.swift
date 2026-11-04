import Foundation
import ISFGLSLBridge

/// A value of an ISF input as reported by ISFGLSLGenerator.
public enum ISFValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case number(Double)
    case vector([Double])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let d = try? c.decode(Double.self) {
            self = .number(d)
        } else {
            self = .vector(try c.decode([Double].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let b): try c.encode(b)
        case .number(let d): try c.encode(d)
        case .vector(let v): try c.encode(v)
        }
    }

    public var components: [Double] {
        switch self {
        case .bool(let b): return [b ? 1 : 0]
        case .number(let d): return [d]
        case .vector(let v): return v
        }
    }
}

public struct ISFInput: Codable, Equatable, Sendable {
    /// One of ISFGLSLGenerator's StringFromISFValType names: Event, Bool, Long, Float, Point2D, Color, Cube, Image, Audio, AudioFFT.
    public var name: String
    public var type: String
    public var label: String
    public var `default`: ISFValue?
    public var min: ISFValue?
    public var max: ISFValue?
    public var identity: ISFValue?
    public var current: ISFValue?
    public var labels: [String]
    public var values: [Int]
    /// Relative to the end of ISFShaderRenderInfo (48 bytes), as ISFMSLScene writes it.
    public var offset: UInt32?

    public init(name: String, type: String, label: String = "", default: ISFValue? = nil, min: ISFValue? = nil, max: ISFValue? = nil, identity: ISFValue? = nil, current: ISFValue? = nil, labels: [String] = [], values: [Int] = [], offset: UInt32? = nil) {
        self.name = name
        self.type = type
        self.label = label
        self.default = `default`
        self.min = min
        self.max = max
        self.identity = identity
        self.current = current
        self.labels = labels
        self.values = values
        self.offset = offset
    }

    public var usesImage: Bool { ["Image", "Audio", "AudioFFT", "Cube"].contains(type) }
}

public struct ISFPass: Codable, Equatable, Sendable {
    public var target: String
    public var persistent: Bool
    public var float: Bool
    public var widthExpression: String
    public var heightExpression: String
    public var width: UInt32
    public var height: UInt32
    public var offset: UInt32?

    public init(target: String, persistent: Bool = false, float: Bool = false, widthExpression: String = "", heightExpression: String = "", width: UInt32 = 0, height: UInt32 = 0, offset: UInt32? = nil) {
        self.target = target
        self.persistent = persistent
        self.float = float
        self.widthExpression = widthExpression
        self.heightExpression = heightExpression
        self.width = width
        self.height = height
        self.offset = offset
    }
}

public struct ISFImport: Codable, Equatable, Sendable {
    public var name: String
    public var path: String
    public var offset: UInt32?

    public init(name: String, path: String, offset: UInt32? = nil) {
        self.name = name
        self.path = path
        self.offset = offset
    }
}

/// Plain snapshot of an ISFDoc. Everything downstream of the C++ bridge works on this value so it can be built by hand in tests.
public struct ISFDocumentInfo: Codable, Equatable, Sendable {
    public var path: String
    public var name: String
    public var description: String
    public var hasCustomVertShader: Bool
    /// sizeof(ISFShaderRenderInfo) plus every input and pass. ISFMSLKit sizes the uniform buffer from this.
    public var maxUBOSize: UInt32
    public var inputs: [ISFInput]
    public var passes: [ISFPass]
    public var imports: [ISFImport]
    /// The metadata comment including the line break after it. The raw file is exactly jsonSource + fragSource.
    public var jsonSource: String
    public var fragSource: String
    public var vertSource: String

    public init(path: String = "", name: String = "", description: String = "", hasCustomVertShader: Bool = false, maxUBOSize: UInt32 = 0, inputs: [ISFInput] = [], passes: [ISFPass] = [], imports: [ISFImport] = [], jsonSource: String = "", fragSource: String = "", vertSource: String = "") {
        self.path = path
        self.name = name
        self.description = description
        self.hasCustomVertShader = hasCustomVertShader
        self.maxUBOSize = maxUBOSize
        self.inputs = inputs
        self.passes = passes
        self.imports = imports
        self.jsonSource = jsonSource
        self.fragSource = fragSource
        self.vertSource = vertSource
    }

    /// Names the ISF host can bind a texture to.
    public var textureNames: Set<String> {
        var names = Set(inputs.map(\.name))
        names.formUnion(imports.map(\.name))
        names.formUnion(passes.map(\.target).filter { !$0.isEmpty })
        return names
    }
}

public struct ISFGeneratedSource: Equatable, Sendable {
    public var frag: String
    public var vert: String

    public init(frag: String, vert: String) {
        self.frag = frag
        self.vert = vert
    }
}

public struct ISFBridgeError: Error, CustomStringConvertible, Sendable {
    public var message: String
    public var description: String { message }
}

/// Owns an ISFDoc from ISFGLSLGenerator.
public final class ISFDocument {
    private let handle: OpaquePointer

    public init(path: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard let h = isfb_open(path, &err) else {
            throw ISFBridgeError(message: Self.take(err) ?? "failed to open \(path)")
        }
        handle = h
    }

    deinit {
        isfb_close(handle)
    }

    public func generate() throws -> ISFGeneratedSource {
        var frag: UnsafeMutablePointer<CChar>?
        var vert: UnsafeMutablePointer<CChar>?
        var err: UnsafeMutablePointer<CChar>?
        guard isfb_generate(handle, &frag, &vert, &err) else {
            throw ISFBridgeError(message: Self.take(err) ?? "generateShaderSource failed")
        }
        return ISFGeneratedSource(frag: Self.take(frag) ?? "", vert: Self.take(vert) ?? "")
    }

    public func describe() throws -> ISFDocumentInfo {
        guard let json = Self.take(isfb_describe(handle)) else {
            throw ISFBridgeError(message: "describe failed")
        }
        return try JSONDecoder().decode(ISFDocumentInfo.self, from: Data(json.utf8))
    }

    public func setInput(_ name: String, _ values: [Double]) throws {
        var err: UnsafeMutablePointer<CChar>?
        let ok = values.withUnsafeBufferPointer { buf in
            isfb_set_input(handle, name, buf.baseAddress, Int32(buf.count), &err)
        }
        if !ok {
            throw ISFBridgeError(message: Self.take(err) ?? "failed to set \(name)")
        }
    }

    public func evalPassSizes(width: Int, height: Int) throws {
        var err: UnsafeMutablePointer<CChar>?
        if !isfb_eval_pass_sizes(handle, Int32(width), Int32(height), &err) {
            throw ISFBridgeError(message: Self.take(err) ?? "failed to evaluate pass sizes")
        }
    }

    private static func take(_ p: UnsafeMutablePointer<CChar>?) -> String? {
        guard let p else { return nil }
        defer { isfb_free(p) }
        return String(cString: p)
    }
}
