import Foundation

/// Values of VDMX's Audio Analysis captured over OSC, as JSON Lines of `{"t", "address", "value"}`.
public struct Recording: Equatable, Sendable {
    public struct Track: Equatable, Sendable {
        public var times: [Double]
        public var values: [Double]
    }

    public var tracks: [String: Track]
    public var duration: Double

    public init(tracks: [String: Track]) {
        self.tracks = tracks
        duration = tracks.values.compactMap(\.times.last).max() ?? 0
    }

    public init(jsonLines text: String) throws {
        struct Line: Decodable { var t: Double; var address: String; var value: Double }
        var tracks: [String: Track] = [:]
        let decoder = JSONDecoder()
        for (n, line) in text.split(whereSeparator: \.isNewline).enumerated() where !line.allSatisfy(\.isWhitespace) {
            let entry: Line
            do {
                entry = try decoder.decode(Line.self, from: Data(line.utf8))
            } catch {
                throw InputValueError(description: "recording line \(n + 1): expected {\"t\", \"address\", \"value\"}")
            }
            tracks[entry.address, default: Track(times: [], values: [])].times.append(entry.t)
            tracks[entry.address]!.values.append(entry.value)
        }
        self.init(tracks: tracks)
    }

    public init(contentsOf path: String) throws {
        try self.init(jsonLines: try String(contentsOfFile: path, encoding: .utf8))
    }

    /// The `/Filter N` channels, which Level inputs are assigned to.
    /// vj_controller counts the filters of the VDMX project; without a project the recording is what tells.
    public var filterCount: Int {
        tracks.keys.filter { $0.hasPrefix("/Filter ") }.count
    }

    /// Port of vjcomponents' preview `sampleTrack`: the last value at or before the position in the loop.
    public func sample(_ address: String, at time: Double) -> Double? {
        guard let track = tracks[address], !track.times.isEmpty else { return nil }
        let position = duration > 0 ? time.truncatingRemainder(dividingBy: duration) : 0
        // Before the first sample the loop is still holding the value from the end of the previous pass.
        if position < track.times[0] { return track.values[track.values.count - 1] }
        var low = 0
        var high = track.times.count - 1
        while low < high {
            let middle = (low + high + 1) >> 1
            if track.times[middle] <= position { low = middle } else { high = middle - 1 }
        }
        return track.values[low]
    }
}

/// How Level inputs are driven (design chapter 6).
public enum LevelMode: String, CaseIterable, Codable, Sendable {
    case `default`
    case recording
    case max
}

/// Input values for each frame: current values, then Level inputs by mode, then `--set`.
public struct LevelDriver: Sendable {
    public let mode: LevelMode
    let base: InputValues
    let overrides: InputValues
    let assigned: [String]
    let levels: [ISFInput]
    let recording: Recording?

    public init(document: ISFDocumentInfo, mode: LevelMode, matcher: LevelMatcher, recording: Recording? = nil, assignments: [String] = []) throws {
        self.mode = mode
        base = InputValues(document: document)
        levels = document.inputs.filter(matcher.isLevel)
        if mode == .recording {
            guard let recording else { throw InputValueError(description: "--levels recording needs --recording") }
            guard recording.filterCount > 0 else { throw InputValueError(description: "the recording has no /Filter N channels") }
        }
        self.recording = recording
        var overrides = InputValues(values: [:])
        for a in assignments { try overrides.set(a, document: document) }
        self.overrides = overrides
        assigned = Array(overrides.values.keys)
    }

    /// `/Filter n` for each Level input in definition order, wrapping like vj_controller's `n % count + 1`.
    public var filters: [String: String] {
        guard let count = recording?.filterCount, count > 0 else { return [:] }
        var result: [String: String] = [:]
        for (n, input) in levels.enumerated() { result[input.name] = "/Filter \(n % count + 1)" }
        return result
    }

    /// Whether the values change from frame to frame.
    public var varies: Bool { mode == .recording && !levels.isEmpty }

    public func values(at time: Double) -> [String: ISFValue] {
        var values = base.values
        let min = { (i: ISFInput) in i.min?.components.first ?? 0 }
        let max = { (i: ISFInput) in i.max?.components.first ?? 1 }
        switch mode {
        case .default:
            break
        case .max:
            for input in levels { values[input.name] = .number(max(input)) }
        case .recording:
            let filters = self.filters
            for input in levels {
                guard let address = filters[input.name], let v = recording?.sample(address, at: time) else { continue }
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
