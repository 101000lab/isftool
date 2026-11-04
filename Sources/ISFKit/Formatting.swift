import Foundation

public enum SourceExcerpt {
    /// Lines around `line` with right-aligned numbers and a `>` on the target line.
    public static func render(_ source: String, line: Int, context: Int = 2) -> String {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        guard line >= 1, line <= lines.count else { return "" }
        let lo = max(1, line - context)
        let hi = min(lines.count, line + context)
        let width = String(hi).count
        return (lo...hi).map { n in
            let number = String(n)
            let pad = String(repeating: " ", count: width - number.count)
            return "\(n == line ? ">" : " ") \(pad)\(number) | \(lines[n - 1])"
        }.joined(separator: "\n")
    }
}

public enum CheckFormatter {
    public static func format(_ result: CheckResult) -> String {
        let report = result.report
        var out: [String] = []
        let timing = ["parse", "glsl", "spirv_cross", "metal"].compactMap { key in
            report.timings[key].map { "\(key) \(String(format: "%.0f", $0))ms" }
        }.joined(separator: ", ")
        if report.ok {
            out.append("ok    \(report.path)  (\(timing))")
            return out.joined(separator: "\n")
        }
        let where_ = [report.stage?.rawValue, report.shader?.rawValue].compactMap { $0 }.joined(separator: " ")
        out.append("FAIL  \(report.path)  [\(where_)] \(report.error ?? "")")
        let fs = result.artifacts.document.map { $0.jsonSource + $0.fragSource }
        for d in report.diagnostics {
            let location = [d.sourceLine.map { "fs:\($0)" }, d.line.map { "glsl:\($0)" }].compactMap { $0 }.joined(separator: " ")
            out.append("  \(d.severity): \(location.isEmpty ? "" : location + ": ")\(d.message)")
            if let sourceLine = d.sourceLine, let fs {
                out.append(indent(SourceExcerpt.render(fs, line: sourceLine)))
            } else if let line = d.line, let generated = result.artifacts.generated {
                // Errors in the generated preamble (for example a reserved input name in the uniform block) have no .fs line.
                out.append(indent(SourceExcerpt.render(report.shader == .vert ? generated.vert : generated.frag, line: line)))
            }
        }
        for u in report.unbound {
            out.append("  unbound: \(u.name) (\(u.kind) \(u.index))")
        }
        for v in report.lint {
            out.append("  lint: \(v.line.map { "fs:\($0): " } ?? "")\(v.message)")
            if let line = v.line, let fs {
                out.append(indent(SourceExcerpt.render(fs, line: line, context: 0)))
            }
        }
        return out.joined(separator: "\n")
    }

    static func indent(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n")
    }
}

public enum InfoFormatter {
    public static func format(_ result: CheckResult, size: RenderSize, levels: LevelMatcher) -> String {
        guard let doc = result.artifacts.document else { return "" }
        var out: [String] = []
        out.append("shader: \(doc.path)")
        if !doc.description.isEmpty { out.append("description: \(doc.description)") }
        out.append("custom vertex shader: \(doc.hasCustomVertShader ? "yes" : "no")")

        out.append("")
        out.append("inputs:")
        if doc.inputs.isEmpty { out.append("  (none)") }
        for input in doc.inputs {
            var parts = ["  \(input.name)", input.type]
            if let v = input.default { parts.append("default=\(text(v))") }
            if let v = input.min { parts.append("min=\(text(v))") }
            if let v = input.max { parts.append("max=\(text(v))") }
            if levels.isLevel(input) { parts.append("[level]") }
            out.append(parts.joined(separator: " "))
        }

        out.append("")
        out.append("passes (at \(size)):")
        for (i, pass) in doc.passes.enumerated() {
            var parts = ["  #\(i)", pass.target.isEmpty ? "(output)" : pass.target, "\(pass.width)x\(pass.height)"]
            if pass.persistent { parts.append("persistent") }
            if pass.float { parts.append("float") }
            let exprs = [pass.widthExpression, pass.heightExpression]
            if exprs.contains(where: { !$0.isEmpty }) {
                parts.append("WIDTH=\(pass.widthExpression.isEmpty ? "-" : pass.widthExpression) HEIGHT=\(pass.heightExpression.isEmpty ? "-" : pass.heightExpression)")
            }
            out.append(parts.joined(separator: " "))
        }

        if !doc.imports.isEmpty {
            out.append("")
            out.append("imported:")
            for imp in doc.imports {
                let exists = FileManager.default.fileExists(atPath: imp.path)
                out.append("  \(imp.name) \(imp.path)\(exists ? "" : " (missing)")")
            }
        }

        let layout = UniformLayout(document: doc)
        out.append("")
        out.append("uniforms (VVISF_UNIFORMS, \(layout.maxUBOSize) bytes, buffer \(layout.bufferSize) bytes):")
        for e in layout.entries {
            out.append("  \(String(format: "%4d", e.offset))  \(e.glslType) \(e.name)")
        }

        out.append("")
        out.append("metal arguments:")
        for stage in [ShaderStage.vert, .frag] {
            guard let sig = result.artifacts.signatures[stage] else {
                out.append("  \(stage.rawValue): (not available)")
                continue
            }
            func list(_ kind: String, _ map: [String: Int]) -> String? {
                map.isEmpty ? nil : map.sorted { $0.value < $1.value }.map { "\(kind)(\($0.value)) \($0.key)" }.joined(separator: ", ")
            }
            let all = [list("buffer", sig.buffers), list("texture", sig.textures), list("sampler", sig.samplers)].compactMap { $0 }
            out.append("  \(stage.rawValue): \(all.joined(separator: ", "))")
        }
        if let vertSig = result.artifacts.signatures[.vert] {
            out.append("  vertex data: buffer(\(vertSig.maxBufferIndex + 1))")
        }

        if let generated = result.artifacts.generated, let map = result.artifacts.lineMap {
            out.append("")
            out.append("glsl: vert \(lineCount(generated.vert)) lines, frag \(lineCount(generated.frag)) lines, body starts at frag line \(map.generatedBodyStart) (fs line \(map.sourceBodyStart))")
        }
        return out.joined(separator: "\n")
    }

    static func text(_ v: ISFValue) -> String {
        switch v {
        case .bool(let b): return b ? "true" : "false"
        case .number(let d): return number(d)
        case .vector(let a): return a.map(number).joined(separator: ",")
        }
    }

    static func number(_ d: Double) -> String {
        d == d.rounded() && abs(d) < 1e9 ? String(Int(d)) : String(d)
    }

    static func lineCount(_ s: String) -> Int {
        LineMap.newlineCount(s) + (s.hasSuffix("\n") ? 0 : 1)
    }
}
