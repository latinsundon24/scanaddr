import Foundation

/// 把「模板 + 每个变量的取值集合」展开成待扫描的 URL 列表（笛卡尔积）。
public struct ScanPlan {
    public var template: String
    public var variables: [VariableDef]
    public var maxCandidates: Int = 200_000
    public var deduplicate: Bool = true

    public init(template: String, variables: [VariableDef], maxCandidates: Int = 200_000) {
        self.template = template
        self.variables = variables
        self.maxCandidates = maxCandidates
    }

    public func resolvedVariables() throws -> [String: [CandidateValue]] {
        var map: [String: [CandidateValue]] = [:]
        for v in variables {
            map[v.name] = try IPSpec.expand(v)
        }
        return map
    }

    /// 变量按模板中首次出现顺序排列，最右侧变量变化最快。
    public func totalCount() throws -> Int {
        let tpl = try URLTemplate(template)
        let map = try resolvedVariables()
        var total = 1
        for name in tpl.variableNames() {
            guard let values = map[name] else { throw ScanCoreError.missingVariable(name) }
            let (multiplied, overflow) = total.multipliedReportingOverflow(by: values.count)
            guard !overflow else { throw ScanCoreError.tooManyCandidates("变量 {\(name)} 展开后组合数溢出") }
            total = multiplied
        }
        return total
    }

    /// - Returns: 合法且（可选）去重后的 URL 列表，以及被丢弃的非法 URL 数量。
    public func buildURLs() throws -> (urls: [String], skipped: Int) {
        let tpl = try URLTemplate(template)
        let names = tpl.variableNames()
        let map = try resolvedVariables()
        var active: [[CandidateValue]] = []
        for name in names {
            guard let values = map[name], !values.isEmpty else {
                throw ScanCoreError.missingVariable(name)
            }
            active.append(values)
        }

        var total = 1
        for column in active {
            let (v, overflow) = total.multipliedReportingOverflow(by: column.count)
            guard !overflow else { throw ScanCoreError.tooManyCandidates("组合数溢出") }
            total = v
        }
        guard total <= maxCandidates else {
            throw ScanCoreError.tooManyCandidates("\(total) > \(maxCandidates)")
        }

        var urls: [String] = []
        urls.reserveCapacity(total)
        var seen = Set<String>()
        var skipped = 0
        var indices = [Int](repeating: 0, count: active.count)

        while true {
            var row: [String: CandidateValue] = [:]
            for (i, name) in names.enumerated() { row[name] = active[i][indices[i]] }
            var valid = false
            if let candidate = try? tpl.render(row),
               let url = URL(string: candidate),
               let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
               url.host != nil {
                valid = true
                if !deduplicate || seen.insert(candidate).inserted { urls.append(candidate) }
            }
            if !valid { skipped += 1 }

            if active.isEmpty { break }
            var k = active.count - 1
            while k >= 0 {
                indices[k] += 1
                if indices[k] < active[k].count { break }
                indices[k] = 0
                k -= 1
            }
            if k < 0 { break }
        }
        return (urls, skipped)
    }
}
