import Foundation

/// Per-band loudness from VDMX's Audio Analysis on a microphone, 0 to 1, captured over OSC for 30 seconds and looped.
public struct Envelope: Equatable, Sendable {
    public struct Channel: Equatable, Sendable {
        public var times: [Double]
        public var values: [Double]

        public init(times: [Double], values: [Double]) {
            self.times = times
            self.values = values
        }
    }

    public var channels: [Channel]
    public var duration: Double

    public init(channels: [Channel]) {
        self.channels = channels
        duration = channels.compactMap(\.times.last).max() ?? 0
    }

    /// Compiled in rather than shipped as a SwiftPM resource, which would need a bundle next to the single binary.
    public static let bundled: Envelope = {
        guard let data = Data(base64Encoded: envelopeData, options: .ignoreUnknownCharacters), let envelope = Envelope(binary: data) else {
            fatalError("EnvelopeData.swift is corrupt. Regenerate it with Scripts/gen_envelope_data.py.")
        }
        return envelope
    }()

    /// The layout Scripts/gen_envelope_data.py writes.
    init?(binary data: Data) {
        var channels: [Channel] = []
        var offset = 0
        func next() -> UInt32? {
            guard offset + 4 <= data.count else { return nil }
            defer { offset += 4 }
            return UInt32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) })
        }
        while offset < data.count {
            guard let count = next() else { return nil }
            var channel = Channel(times: [], values: [])
            for _ in 0..<count {
                guard let t = next(), let v = next() else { return nil }
                channel.times.append(Double(t) / 10000)
                channel.values.append(Double(Float(bitPattern: v)))
            }
            channels.append(channel)
        }
        self.init(channels: channels)
    }

    /// The last value at or before the position in the loop, as the WebGL preview samples it.
    public func sample(channel index: Int, at time: Double) -> Double? {
        guard channels.indices.contains(index) else { return nil }
        let channel = channels[index]
        guard !channel.times.isEmpty else { return nil }
        let position = duration > 0 ? time.truncatingRemainder(dividingBy: duration) : 0
        // Before the first sample the loop is still holding the value from the end of the previous pass.
        if position < channel.times[0] { return channel.values[channel.values.count - 1] }
        var low = 0
        var high = channel.times.count - 1
        while low < high {
            let middle = (low + high + 1) >> 1
            if channel.times[middle] <= position { low = middle } else { high = middle - 1 }
        }
        return channel.values[low]
    }
}

/// How the inputs matching the feed pattern are driven (design chapter 6).
public enum FeedMode: String, CaseIterable, Codable, Sendable {
    case `default`
    case envelope
    case max
}

/// Input values for each frame: current values, then the matched inputs by mode, then `--set`.
public struct InputDriver: Sendable {
    public let mode: FeedMode
    let base: InputValues
    let overrides: InputValues
    let assigned: [String]
    let targets: [ISFInput]
    let envelope: Envelope

    public init(document: ISFDocumentInfo, mode: FeedMode, matcher: FeedMatcher, envelope: Envelope = .bundled, assignments: [String] = []) throws {
        self.mode = mode
        base = InputValues(document: document)
        targets = document.inputs.filter(matcher.matches)
        self.envelope = envelope
        var overrides = InputValues(values: [:])
        for a in assignments { try overrides.set(a, document: document) }
        self.overrides = overrides
        assigned = Array(overrides.values.keys)
    }

    /// The envelope channel of each matched input in definition order, wrapping as `n % count + 1`, the way Level inputs are assigned to VDMX's Filters.
    public var channels: [String: Int] {
        let count = envelope.channels.count
        guard count > 0 else { return [:] }
        var result: [String: Int] = [:]
        for (n, input) in targets.enumerated() { result[input.name] = n % count }
        return result
    }

    /// Whether the values change from frame to frame.
    public var varies: Bool { mode == .envelope && !targets.isEmpty }

    public func values(at time: Double) -> [String: ISFValue] {
        var values = base.values
        let min = { (i: ISFInput) in i.min?.components.first ?? 0 }
        let max = { (i: ISFInput) in i.max?.components.first ?? 1 }
        switch mode {
        case .default:
            break
        case .max:
            for input in targets { values[input.name] = .number(max(input)) }
        case .envelope:
            let channels = self.channels
            for input in targets {
                guard let channel = channels[input.name], let v = envelope.sample(channel: channel, at: time) else { continue }
                values[input.name] = .number(v * (max(input) - min(input)) + min(input))
            }
        }
        for name in assigned { values[name] = overrides.values[name] }
        return values
    }
}

extension InputValues {
    init(values: [String: ISFValue]) {
        self.values = values
    }
}
