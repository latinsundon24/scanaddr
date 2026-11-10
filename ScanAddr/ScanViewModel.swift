import Foundation
import SwiftUI

/// UI 状态一律在主线程更新；引擎回调经 DispatchQueue.main 派发。
final class ScanViewModel: ObservableObject, @unchecked Sendable {
    @Published var template: String = "http://{A}:{P}/status"
    @Published var variables: [VariableDef] = []
    @Published var settings = ScanSettings()
    @Published var maxCandidates: Int = 200_000
    @Published var hits: [ScanHit] = []
    @Published var scanned = 0
    @Published var total = 0
    @Published var isScanning = false
    @Published var notice = ""
    @Published var previewText = "点「计算组合数」查看扫描规模"

    private var engine: ScanEngine?
    private var scanTask: Task<Void, Never>?

    enum Preset {
        case ipv4, ipv6, multi
    }

    init() {
        loadPreset(.ipv4)
    }

    func loadPreset(_ preset: Preset) {
        switch preset {
        case .ipv4:
            template = "http://{A}:{P}/status"
            variables = [
                VariableDef(name: "A", kind: .mixed, expression: "192.168.1.1-192.168.1.254"),
                VariableDef(name: "P", kind: .port, expression: "80,8080")
            ]
        case .ipv6:
            template = "http://[{A}]:{P}/status"
            variables = [
                VariableDef(name: "A", kind: .mixed, expression: "2001:db8::1-2001:db8::20"),
                VariableDef(name: "P", kind: .port, expression: "80,8080")
            ]
        case .multi:
            template = "http://{A}:{P}/check?peer={B}&raw={A:raw}"
            variables = [
                VariableDef(name: "A", kind: .mixed, expression: "127.0.0.1,::1"),
                VariableDef(name: "B", kind: .mixed, expression: "192.168.1.1-192.168.1.10"),
                VariableDef(name: "P", kind: .port, expression: "8080")
            ]
        }
        syncVariables()
        previewText = "点「计算组合数」查看扫描规模"
    }

    /// 模板改动后同步变量表，保留同名变量已填写的取值。
    func syncVariables() {
        let names = (try? URLTemplate(template).variableNames()) ?? []
        let existing = Dictionary(uniqueKeysWithValues: variables.map { ($0.name, $0) })
        let next = names.map { existing[$0] ?? VariableDef(name: $0) }
        if next.map(\.name) != variables.map(\.name) {
            variables = next
        }
    }

    func refreshPreview() {
        syncVariables()
        var lines: [String] = []
        do {
            for v in variables {
                let count = try IPSpec.expand(v).count
                lines.append("{\(v.name)} \(v.kind.label): \(count) 个")
            }
            let plan = ScanPlan(template: template, variables: variables, maxCandidates: maxCandidates)
            let total = try plan.totalCount()
            lines.append("共 \(total) 个候选 URL" + (total > maxCandidates ? "（超过上限，请先缩小范围）" : ""))
            previewText = lines.joined(separator: "\n")
        } catch {
            previewText = "无法计算: \(Self.describe(error))"
        }
    }

    func start() {
        guard !isScanning else { return }
        syncVariables()
        do {
            let plan = ScanPlan(template: template, variables: variables, maxCandidates: maxCandidates)
            let built = try plan.buildURLs()
            guard !built.urls.isEmpty else {
                notice = "没有生成可扫描的 URL：请检查模板（需 http/https）与变量取值"
                return
            }
            hits = []
            scanned = 0
            total = built.urls.count
            notice = built.skipped > 0 ? "已跳过 \(built.skipped) 个非法 URL" : ""
            isScanning = true

            let engine = ScanEngine(settings: settings)
            self.engine = engine
            scanTask = Task { [weak self] in
                await engine.scan(urls: built.urls,
                                  onHit: { [weak self] hit in
                                      DispatchQueue.main.async { self?.append(hit) }
                                  },
                                  onProgress: { [weak self] done, _ in
                                      DispatchQueue.main.async { self?.update(progress: done) }
                                  })
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isScanning = false
                    self.engine = nil
                    let suffix = "扫描完成，命中 \(self.hits.count) 个"
                    self.notice = self.notice.isEmpty ? suffix : self.notice + "；" + suffix
                }
            }
        } catch {
            notice = "无法开始: \(Self.describe(error))"
        }
    }

    func stop() {
        engine?.cancel()
        notice = "正在停止…"
    }

    func clearResults() {
        hits = []
        scanned = 0
        total = 0
        notice = ""
    }

    private func append(_ hit: ScanHit) {
        hits.append(hit)
    }

    private func update(progress done: Int) {
        scanned = done
    }

    static func describe(_ error: Error) -> String {
        (error as? ScanCoreError)?.description ?? error.localizedDescription
    }
}
