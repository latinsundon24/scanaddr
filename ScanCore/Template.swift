import Foundation

/// URL 模板：支持在任意位置出现任意多个 {变量} 占位符。
///
/// - 主机位（authority）里的 IPv6 会自动补上方括号；模板里若已写成 [{A}]，
///   当实际取值是 IPv4 时会自动去掉方括号，是 IPv6 时保持单对方括号。
/// - 路径 / 查询参数位置一律插入裸地址（不带方括号）。
/// - {A:raw} 强制按裸地址插入，把加括号的决定权交给模板本身。
public struct URLTemplate {
    public struct Slot {
        public let name: String
        public let raw: Bool
        public let inHost: Bool
        /// 替换范围：若模板写成 [{A}]，该范围含外侧的一对方括号。
        public let range: Range<String.Index>
        public let hadBrackets: Bool
    }

    public let source: String
    public let slots: [Slot]

    public init(_ source: String) throws {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScanCoreError.invalidTemplate("模板为空")
        }
        self.source = source

        // 定位 authority（主机位）：scheme:// 之后、第一个 / ? # 之前。
        // 没有 scheme 时把开头当作 authority，便于 {A}:8080/path 这种写法。
        let authStart = source.range(of: "://").map { $0.upperBound } ?? source.startIndex
        var authEnd = source.endIndex
        for ch: Character in ["/", "?", "#"] {
            if let i = source[authStart...].firstIndex(of: ch), i < authEnd { authEnd = i }
        }

        var parsed: [Slot] = []
        var cursor = source.startIndex
        while cursor < source.endIndex, let open = source[cursor...].firstIndex(of: "{") {
            let innerStart = source.index(after: open)
            guard innerStart < source.endIndex,
                  let close = source[innerStart...].firstIndex(of: "}") else {
                throw ScanCoreError.invalidTemplate("占位符缺少右花括号: \(source[open...])")
            }
            let inner = String(source[innerStart..<close])
            let parts = inner.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            let name = (parts.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !name.contains(where: { $0 == "{" || $0 == "}" }) else {
                throw ScanCoreError.invalidTemplate("占位符缺少变量名: {\(inner)}")
            }
            let raw = parts.dropFirst().contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == "raw" }

            var lower = open
            var upper = source.index(after: close)
            var bracketed = false
            if open > source.startIndex && upper < source.endIndex,
               source[source.index(before: open)] == "[", source[upper] == "]" {
                lower = source.index(before: open)
                upper = source.index(after: upper)
                bracketed = true
            }

            parsed.append(Slot(name: name,
                               raw: raw,
                               inHost: open >= authStart && open < authEnd,
                               range: lower..<upper,
                               hadBrackets: bracketed))
            cursor = upper
        }
        self.slots = parsed
    }

    /// 模板中变量首次出现的顺序（去重）。
    public func variableNames() -> [String] {
        var seen = Set<String>()
        return slots.compactMap { seen.insert($0.name).inserted ? $0.name : nil }
    }

    public func render(_ values: [String: CandidateValue]) throws -> String {
        var out = ""
        var cursor = source.startIndex
        for slot in slots {
            guard let v = values[slot.name] else {
                throw ScanCoreError.missingVariable(slot.name)
            }
            out.append(contentsOf: source[cursor..<slot.range.lowerBound])

            var text = v.text
            if text.hasPrefix("[") && text.hasSuffix("]") {
                text = String(text.dropFirst().dropLast())
            }
            if slot.inHost && !slot.raw && v.isIPv6 {
                text = "[" + text + "]"
            }
            out.append(contentsOf: text)
            cursor = slot.range.upperBound
        }
        out.append(contentsOf: source[cursor...])
        return out
    }
}
