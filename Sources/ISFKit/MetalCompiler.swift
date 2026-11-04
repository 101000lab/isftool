import Foundation
import Metal

public protocol MSLCompiling {
    /// Throws with the compiler log on failure.
    func compile(_ source: String) throws
}

public struct MetalCompileError: Error, CustomStringConvertible, Sendable {
    public var message: String
    public var description: String { message }
}

public final class MetalLibraryCompiler: MSLCompiling {
    public let device: MTLDevice

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else { throw MetalCompileError(message: "no Metal device") }
        self.device = device
    }

    public func compile(_ source: String) throws {
        do {
            _ = try device.makeLibrary(source: source, options: nil)
        } catch {
            throw MetalCompileError(message: (error as NSError).localizedDescription)
        }
    }
}
