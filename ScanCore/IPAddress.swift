import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum ScanCoreError: Error, CustomStringConvertible {
    case invalidExpression(String)
    case tooManyAddresses(String)
    case mixedFamilies(String)
    case invalidTemplate(String)
    case missingVariable(String)
    case tooManyCandidates(String)

    public var description: String {
        switch self {
        case .invalidExpression(let s): return "无效的取值表达式: \(s)"
        case .tooManyAddresses(let s): return "地址数量超过上限: \(s)"
        case .mixedFamilies(let s): return "IPv4 / IPv6 不能混用于同一范围: \(s)"
        case .invalidTemplate(let s): return "无效的 URL 模板: \(s)"
        case .missingVariable(let s): return "模板变量未配置: {\(s)}"
        case .tooManyCandidates(let s): return "组合数超过上限: \(s)"
        }
    }
}

/// 128 位无符号整数。IPv4 只使用 lo 的低 32 位，IPv6 使用 hi:lo 全部 128 位。
/// 这样 IPv4 / IPv6 的「加一」「比较」「掩码」可以共用一套逻辑。
public struct IPNumber: Equatable, Comparable, Hashable {
    public var hi: UInt64
    public var lo: UInt64
    public let bits: Int

    public init(hi: UInt64, lo: UInt64, bits: Int) {
        self.hi = hi
        self.lo = lo
        self.bits = bits
    }

    public static func < (lhs: IPNumber, rhs: IPNumber) -> Bool {
        lhs.hi == rhs.hi ? lhs.lo < rhs.lo : lhs.hi < rhs.hi
    }

    public func advanced(by delta: UInt64) -> IPNumber {
        let (newLo, carry) = lo.addingReportingOverflow(delta)
        return IPNumber(hi: hi &+ (carry ? 1 : 0), lo: newLo, bits: bits)
    }

    /// 16 字节大端表示。IPv4 放在最后 4 字节。
    public var bytes: [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 { out[i] = UInt8(truncatingIfNeeded: hi >> (8 * (7 - i))) }
        for i in 0..<8 { out[8 + i] = UInt8(truncatingIfNeeded: lo >> (8 * (7 - i))) }
        return out
    }

    /// b 为 4 字节（IPv4）或 16 字节（IPv6）网络字节序。
    public init?(bytes b: [UInt8], bits: Int) {
        var full = [UInt8](repeating: 0, count: 16)
        if b.count == 4 && bits == 32 {
            for i in 0..<4 { full[12 + i] = b[i] }
        } else if b.count == 16 && bits == 128 {
            full = b
        } else {
            return nil
        }
        var h: UInt64 = 0
        var l: UInt64 = 0
        for i in 0..<8 { h = (h << 8) | UInt64(full[i]) }
        for i in 0..<8 { l = (l << 8) | UInt64(full[8 + i]) }
        self.init(hi: h, lo: l, bits: bits)
    }

    /// 解析 IPv4 / IPv6 字面量。容忍外层方括号与 IPv6 zone id（%en0）。
    public static func parse(_ raw: String) -> IPNumber? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("[") { s = String(s.dropFirst()) }
        if s.hasSuffix("]") { s = String(s.dropLast()) }
        if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }
        guard !s.isEmpty else { return nil }

        let ipv6 = s.contains(":")
        let family: Int32 = ipv6 ? AF_INET6 : AF_INET
        let count = ipv6 ? 16 : 4
        let ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        defer { ptr.deallocate() }
        ptr.initialize(repeating: 0, count: count)
        let ok = s.withCString { inet_pton(family, $0, UnsafeMutableRawPointer(ptr)) == 1 }
        guard ok else { return nil }
        return IPNumber(bytes: Array(UnsafeBufferPointer(start: ptr, count: count)),
                        bits: ipv6 ? 128 : 32)
    }

    public static func isIPv6Literal(_ raw: String) -> Bool {
        parse(raw)?.bits == 128
    }

    /// 规范化文本：IPv4 点分十进制，IPv6 交给 inet_ntop 做 RFC 5952 压缩。
    public var text: String {
        let b = bytes
        if bits == 32 { return "\(b[12]).\(b[13]).\(b[14]).\(b[15])" }

        var addr = in6_addr()
        withUnsafeMutableBytes(of: &addr) { dst in
            for i in 0..<16 { dst[i] = b[i] }
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let converted = buffer.withUnsafeMutableBufferPointer { bp -> String? in
            withUnsafePointer(to: &addr) { ap -> String? in
                guard inet_ntop(AF_INET6, UnsafeRawPointer(ap), bp.baseAddress,
                                socklen_t(bp.count)) != nil else { return nil }
                return String(cString: bp.baseAddress!)
            }
        }
        return converted ?? b.map { String(format: "%02x", $0) }.joined()
    }
}

private func prefixMask(_ prefix: Int, bits: Int) -> (UInt64, UInt64) {
    var h: UInt64 = 0
    var l: UInt64 = 0
    let p = min(max(prefix, 0), bits)
    if bits == 32 {
        // IPv4 数值存放在 lo 的低 32 位，掩码必须落在 lo 的 bit31..(32-p)，
        // 不能按 128 位布局写到 hi 上，否则整个网络地址会被清零。
        for i in 0..<p { l |= (UInt64(1) << UInt64(31 - i)) }
    } else {
        // IPv6：hi 承载前 64 位，lo 承载后 64 位。
        for i in 0..<p {
            if i < 64 {
                h |= (UInt64(1) << UInt64(63 - i))
            } else {
                l |= (UInt64(1) << UInt64(63 - (i - 64)))
            }
        }
    }
    return (h, l)
}

// MARK: - 变量定义与取值展开

public enum VariableKind: String, Codable, CaseIterable, Identifiable {
    case mixed   // IPv4 / IPv6 混合，支持 CIDR、范围、+N
    case port    // 端口数字
    case number  // 编号数字，支持前导零补位（0000-2000）
    case text    // 任意字符串

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .mixed:  return "IP (v4/v6)"
        case .port:   return "端口"
        case .number: return "编号"
        case .text:   return "文本"
        }
    }
}

public struct CandidateValue: Equatable, Hashable {
    public var text: String
    public var isIPv6: Bool

    public init(_ raw: String) {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isIPv6 = IPNumber.isIPv6Literal(t)
        if t.hasPrefix("[") && t.hasSuffix("]") { t = String(t.dropFirst().dropLast()) }
        self.text = t
    }
}

public struct VariableDef: Equatable, Identifiable, Codable {
    public var id: String { name }
    public var name: String
    public var kind: VariableKind
    public var expression: String

    public init(name: String, kind: VariableKind = .mixed, expression: String = "") {
        self.name = name
        self.kind = kind
        self.expression = expression
    }
}

public enum IPSpec {
    /// 单个变量允许展开的最大地址数，防止 /8、/64 之类把内存打爆。
    public static let defaultMaxCount = 65_536

    public static func tokens(_ expression: String) -> [String] {
        expression
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public static func expand(_ def: VariableDef, maxCount: Int = defaultMaxCount) throws -> [CandidateValue] {
        let parts = tokens(def.expression)
        guard !parts.isEmpty else {
            throw ScanCoreError.invalidExpression("{\(def.name)} 的取值为空")
        }
        var out: [CandidateValue] = []
        for part in parts {
            let chunk: [String]
            switch def.kind {
            case .text:
                chunk = [part]
            case .port:
                chunk = try expandPort(part, maxCount: maxCount - out.count, label: part)
            case .number:
                chunk = try expandNumber(part, maxCount: maxCount - out.count, label: part)
            case .mixed:
                chunk = try expandIP(part, maxCount: maxCount - out.count)
            }
            out.append(contentsOf: chunk.map { CandidateValue($0) })
            if out.count > maxCount {
                throw ScanCoreError.tooManyAddresses("{\(def.name)} 超过 \(maxCount) 个")
            }
        }
        guard !out.isEmpty else {
            throw ScanCoreError.invalidExpression("{\(def.name)} 未展开出任何取值")
        }
        return out
    }

    private static func expandIP(_ token: String, maxCount: Int) throws -> [String] {
        guard maxCount > 0 else { throw ScanCoreError.tooManyAddresses(token) }

        if let slash = token.firstIndex(of: "/") {
            let left = String(token[..<slash])
            let right = String(token[token.index(after: slash)...])
            guard let base = IPNumber.parse(left), let p = Int(right),
                  p >= 0, p <= base.bits else {
                throw ScanCoreError.invalidExpression(token)
            }
            return try expandCIDR(base: base, prefix: p, maxCount: maxCount)
        }

        if let plus = token.firstIndex(of: "+") {
            let left = String(token[..<plus])
            let right = String(token[token.index(after: plus)...])
            guard let base = IPNumber.parse(left), let n = Int(right), n > 0 else {
                throw ScanCoreError.invalidExpression(token)
            }
            guard n <= maxCount else { throw ScanCoreError.tooManyAddresses(token) }
            return (0..<n).map { base.advanced(by: UInt64($0)).text }
        }

        if let dash = token.firstIndex(of: "-") {
            let left = String(token[..<dash])
            let right = String(token[token.index(after: dash)...])
            guard let start = IPNumber.parse(left) else {
                throw ScanCoreError.invalidExpression(token)
            }
            let end = try parseRangeEnd(left: left, right: right, bits: start.bits, token: token)
            guard !(end < start), end.bits == start.bits else {
                throw ScanCoreError.invalidExpression("范围倒置或地址族不一致: \(token)")
            }
            var out: [String] = []
            var cur = start
            while true {
                out.append(cur.text)
                if cur == end { break }
                if out.count >= maxCount { throw ScanCoreError.tooManyAddresses(token) }
                cur = cur.advanced(by: 1)
            }
            return out
        }

        guard let single = IPNumber.parse(token) else {
            throw ScanCoreError.invalidExpression(token)
        }
        return [single.text]
    }

    private static func parseRangeEnd(left: String, right: String, bits: Int, token: String) throws -> IPNumber {
        // 纯数字右端 = 只替换末段。IPv4 按十进制，IPv6 末段按十六进制。
        if !right.isEmpty && right.allSatisfy({ $0.isNumber }), let n = UInt64(right) {
            if bits == 32 {
                var comps = left.split(separator: ".").map(String.init)
                guard comps.count == 4 else { throw ScanCoreError.invalidExpression(token) }
                comps[3] = String(n)
                guard let v = IPNumber.parse(comps.joined(separator: ".")) else {
                    throw ScanCoreError.invalidExpression(token)
                }
                return v
            } else {
                guard let idx = left.lastIndex(of: ":") else {
                    throw ScanCoreError.invalidExpression(token)
                }
                let head = String(left[...idx])
                guard let v = IPNumber.parse(head + String(n, radix: 16)) else {
                    throw ScanCoreError.invalidExpression(token)
                }
                return v
            }
        }
        guard let full = IPNumber.parse(right), full.bits == bits else {
            throw ScanCoreError.mixedFamilies(token)
        }
        return full
    }

    private static func expandCIDR(base: IPNumber, prefix: Int, maxCount: Int) throws -> [String] {
        let (mh, ml) = prefixMask(prefix, bits: base.bits)
        let start = IPNumber(hi: base.hi & mh, lo: base.lo & ml, bits: base.bits)
        let hostBits = base.bits - prefix
        let total: UInt64 = hostBits >= 64 ? UInt64.max : (UInt64(1) << UInt64(hostBits))
        let limit = min(total, UInt64(maxCount))
        guard limit > 0 else { throw ScanCoreError.tooManyAddresses("\(base.text)/\(prefix)") }
        var out: [String] = []
        out.reserveCapacity(Int(limit))
        var i: UInt64 = 0
        while i < limit {
            out.append(start.advanced(by: i).text)
            i += 1
        }
        return out
    }

    private static func expandPort(_ token: String, maxCount: Int, label: String) throws -> [String] {
        func intOrThrow(_ s: String) throws -> Int {
            guard let v = Int(s), v >= 0, v <= 65535 else {
                throw ScanCoreError.invalidExpression(label)
            }
            return v
        }
        if let dash = token.firstIndex(of: "-") {
            let a = try intOrThrow(String(token[..<dash]))
            let b = try intOrThrow(String(token[token.index(after: dash)...]))
            guard b >= a, b - a + 1 <= maxCount else {
                throw ScanCoreError.tooManyAddresses(label)
            }
            return (a...b).map { String($0) }
        }
        if let plus = token.firstIndex(of: "+") {
            let a = try intOrThrow(String(token[..<plus]))
            let n = try intOrThrow(String(token[token.index(after: plus)...]))
            guard n > 0, n <= maxCount else { throw ScanCoreError.tooManyAddresses(label) }
            return (0..<n).map { String(a + $0) }
        }
        let single = try intOrThrow(token)
        return [String(single)]
    }

    /// 编号变量：`0001-9999`、`0001+50`、`0001,0003-0005`、`42`。
    /// 输出形态完全由「起始数字怎么写」决定，不改写用户填写的数值：
    /// 起始带前导零（0001）就按该位数逐 +1 输出 0001…9999；
    /// 起始不带前导零（1）就输出普通十进制 1…9999；位数不限，超宽不截断。
    /// 结束边界只表示数值大小，不改变输出形态。
    private static func expandNumber(_ token: String, maxCount: Int, label: String) throws -> [String] {
        func isDigits(_ s: String) -> Bool {
            !s.isEmpty && s.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
        }
        func intOrThrow(_ s: String) throws -> Int {
            guard isDigits(s), let v = Int(s) else { throw ScanCoreError.invalidExpression(label) }
            return v
        }
        func width(_ s: String) -> Int {
            s.count > 1 && s.hasPrefix("0") ? s.count : 0
        }
        func padded(_ v: Int, width w: Int) -> String {
            let s = String(v)
            return w > s.count ? String(repeating: "0", count: w - s.count) + s : s
        }
        guard maxCount > 0 else { throw ScanCoreError.tooManyAddresses(label) }

        if let dash = token.firstIndex(of: "-") {
            let aText = String(token[..<dash])
            let bText = String(token[token.index(after: dash)...])
            let a = try intOrThrow(aText)
            let b = try intOrThrow(bText)
            guard b >= a, b - a < maxCount else {
                throw ScanCoreError.tooManyAddresses(label)
            }
            // 只看起始字面：不因结束边界的位数不同而改写输出形态。
            let w = width(aText)
            return (a...b).map { padded($0, width: w) }
        }
        if let plus = token.firstIndex(of: "+") {
            let aText = String(token[..<plus])
            let nText = String(token[token.index(after: plus)...])
            let a = try intOrThrow(aText)
            let n = try intOrThrow(nText)
            guard n > 0, n <= maxCount, a <= Int.max - (n - 1) else {
                throw ScanCoreError.tooManyAddresses(label)
            }
            let w = width(aText)
            return (0..<n).map { padded(a + $0, width: w) }
        }
        let v = try intOrThrow(token)
        return [padded(v, width: width(token))]
    }
}
