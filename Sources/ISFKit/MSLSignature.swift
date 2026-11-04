import Foundation

/// Entry point names as ISFMSLKit's ISFMSLEntryPointNamesForPath builds them.
public struct EntryPointNames: Equatable, Sendable {
    public var vert: String
    public var frag: String

    public init(path: String) {
        let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        // isalnum in the C locale, so non-ASCII letters become "_" too.
        let name = String(stem.unicodeScalars.map { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0)) ? Character($0) : "_" })
        vert = "VV\(name)VertFunc"
        frag = "VV\(name)FragFunc"
    }
}

/// Metal argument indices read from the entry point declaration of SPIRV-Cross output.
///
/// The indices are read from the MSL text instead of `spirv-cross --reflect`, because reflection reports
/// the SPIR-V bindings, which differ from the indices SPIRV-Cross assigns without `--msl-decoration-binding`.
public struct MSLSignature: Equatable, Sendable {
    public static let uniformsKey = "VVISF_UNIFORMS&"

    public var buffers: [String: Int]
    public var textures: [String: Int]
    public var samplers: [String: Int]

    public init(buffers: [String: Int] = [:], textures: [String: Int] = [:], samplers: [String: Int] = [:]) {
        self.buffers = buffers
        self.textures = textures
        self.samplers = samplers
    }

    /// Port of ISFMSLKit's ISFMSLParseFuncSignature.
    public static func parse(functionName: String, msl: String) -> MSLSignature {
        let args = arguments(of: declarationLine(functionName: functionName, msl: msl))
        return MSLSignature(
            buffers: search(attribute: "buffer", in: args),
            textures: search(attribute: "texture", in: args),
            samplers: search(attribute: "sampler", in: args)
        )
    }

    /// The vertex data buffer goes one past the largest buffer index the vertex function uses.
    public var maxBufferIndex: Int { buffers.values.max() ?? 0 }

    static func declarationLine(functionName: String, msl: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: functionName)
        guard let range = msl.range(of: "\\b\(escaped)\\b", options: .regularExpression) else { return "" }
        let start = msl[..<range.lowerBound].lastIndex(where: \.isNewline).map { msl.index(after: $0) } ?? msl.startIndex
        let end = msl[range.upperBound...].firstIndex(where: \.isNewline) ?? msl.endIndex
        return String(msl[start..<end])
    }

    static func arguments(of line: String) -> [String] {
        guard let open = line.firstIndex(of: "("), let close = line.lastIndex(of: ")"), open < close else { return [] }
        return line[line.index(after: open)..<close]
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t")) }
            .filter { !$0.isEmpty }
    }

    static func search(attribute: String, in args: [String]) -> [String: Int] {
        let regex = try! NSRegularExpression(pattern: "\\[\\[\\s*\(attribute)\\(\\s*([0-9]+)\\s*\\)\\s*\\]\\]")
        var result: [String: Int] = [:]
        for arg in args {
            let ns = arg as NSString
            for match in regex.matches(in: arg, range: NSRange(location: 0, length: ns.length)) {
                guard let index = Int(ns.substring(with: match.range(at: 1))) else { continue }
                let words = arg.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
                guard words.count >= 2 else { continue }
                // The variable name is the second-to-last word, before the [[attribute]].
                var name = words[words.count - 2]
                if words.contains(uniformsKey) {
                    name = uniformsKey
                }
                result[name] = index
            }
        }
        return result
    }
}

public struct UnboundArgument: Codable, Equatable, Sendable {
    public var name: String
    public var kind: String
    public var index: Int

    public init(name: String, kind: String, index: Int) {
        self.name = name
        self.kind = kind
        self.index = index
    }
}

extension MSLSignature {
    /// Port of ISFMSLKit's ISFMSLFindUnboundArgs. Arguments the ISF host has no value for, such as a `uniform`
    /// the shader body declares itself. Samplers need no rule because the host binds one sampler at every index.
    public func unboundArguments(textureNames: Set<String>) -> [UnboundArgument] {
        var result: [UnboundArgument] = []
        for (name, index) in buffers.sorted(by: { $0.value < $1.value }) where name != Self.uniformsKey || index != 0 {
            result.append(UnboundArgument(name: name, kind: "buffer", index: index))
        }
        for (name, index) in textures.sorted(by: { $0.value < $1.value }) where !textureNames.contains(name) {
            result.append(UnboundArgument(name: name, kind: "texture", index: index))
        }
        return result
    }
}
