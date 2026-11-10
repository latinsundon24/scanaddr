import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// scanaddr Swift 自检入口。
// 编译： swiftc -O -o scanaddr-selftest ScanCore/*.swift tests/SelfTestMain.swift
// 运行： ./scanaddr-selftest            （工作目录为仓库根目录）
// 只有全部检查通过才返回 0，build-ipa.yml 用它作为编译 IPA 的前置门禁。

private struct Fixtures: Decodable {
    struct ExpandCase: Decodable {
        let name: String
        let kind: String
        let expression: String
        let expect: [String]
    }
    struct RenderCase: Decodable {
        let name: String
        let template: String
        let values: [String: [String]]
        let expect: [String]
    }
    let expand: [ExpandCase]
    let render: [RenderCase]
}

private final class HitCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ScanHit] = []
    func add(_ hit: ScanHit) {
        lock.lock()
        items.append(hit)
        lock.unlock()
    }
    func snapshot() -> [ScanHit] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

private struct MockServer {
    let process: Process
    let port: Int
    let logFile: String
}

private final class Runner: @unchecked Sendable {
    let root: String
    private var passed = 0
    private var failed = 0

    init() {
        if let env = ProcessInfo.processInfo.environment["SCANADDR_ROOT"] {
            root = env
        } else {
            root = FileManager.default.currentDirectoryPath
        }
    }

    func pass(_ name: String) {
        passed += 1
        print("  PASS  \(name)")
    }

    func fail(_ message: String) {
        failed += 1
        print("  FAIL  \(message)")
    }

    func check<T: Equatable>(_ name: String, _ actual: T, _ expected: T) {
        if actual == expected {
            pass(name)
        } else {
            fail("\(name)\n        expect: \(expected)\n        actual: \(actual)")
        }
    }

    func checkTrue(_ name: String, _ condition: Bool, _ detail: String = "") {
        if condition { pass(name) } else { fail("\(name)  \(detail)") }
    }

    func fixtures() throws -> Fixtures {
        let url = URL(fileURLWithPath: root).appendingPathComponent("tests/fixtures.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Fixtures.self, from: data)
    }

    /// 与 Python 参考实现 render_all 完全一致的顺序：变量按首次出现排列，最右列变化最快。
    func renderAll(_ source: String, _ values: [String: [String]]) throws -> [String] {
        let tpl = try URLTemplate(source)
        let names = tpl.variableNames()
        let columns: [[CandidateValue]] = names.map { (values[$0] ?? []).map { CandidateValue($0) } }
        if columns.isEmpty { return [try tpl.render([:])] }
        guard columns.allSatisfy({ !$0.isEmpty }) else {
            throw ScanCoreError.invalidExpression("render case 缺少变量取值")
        }
        var indices = [Int](repeating: 0, count: columns.count)
        var out: [String] = []
        while true {
            var row: [String: CandidateValue] = [:]
            for (i, name) in names.enumerated() { row[name] = columns[i][indices[i]] }
            out.append(try tpl.render(row))
            var k = columns.count - 1
            while k >= 0 {
                indices[k] += 1
                if indices[k] < columns[k].count { break }
                indices[k] = 0
                k -= 1
            }
            if k < 0 { break }
        }
        return out
    }

    func fixtureChecks() {
        do {
            let f = try fixtures()
            print("\n[1] 地址展开 / 变量语法 (\(f.expand.count) cases)")
            for c in f.expand {
                do {
                    guard let kind = VariableKind(rawValue: c.kind) else {
                        fail("\(c.name) 未知变量类型 \(c.kind)")
                        continue
                    }
                    let def = VariableDef(name: "X", kind: kind, expression: c.expression)
                    let got = try IPSpec.expand(def).map(\.text)
                    check(c.name, got, c.expect)
                } catch {
                    fail("\(c.name) 抛出异常: \(error)")
                }
            }

            print("\n[2] 多位置变量 / IPv6 方括号 / 笛卡尔积 (\(f.render.count) cases)")
            for c in f.render {
                do {
                    check(c.name, try renderAll(c.template, c.values), c.expect)
                } catch {
                    fail("\(c.name) 抛出异常: \(error)")
                }
            }
        } catch {
            fail("读取 fixtures.json 失败: \(error)")
        }
    }

    /// 通用「编号区段」能力：按填写的数值原样逐 +1 展开，位数不限；可与 IP/端口变量共存。
    func numberChecks() {
        print("\n[2b] 编号区段（按填写数值原样展开，位数不限）")
        let widths: [(String, [String])] = [
            ("01-03", ["01", "02", "03"]),
            ("001-003", ["001", "002", "003"]),
            ("0001-0003", ["0001", "0002", "0003"]),
            ("00001-00003", ["00001", "00002", "00003"]),
            ("00000001-00000003", ["00000001", "00000002", "00000003"]),
            ("0000000001-0000000003", ["0000000001", "0000000002", "0000000003"]),
            ("1-3", ["1", "2", "3"]),
            ("000001+3", ["000001", "000002", "000003"]),
            ("099-101", ["099", "100", "101"]),
            ("001-0003", ["001", "002", "003"]),
            ("1-0003", ["1", "2", "3"]),
            ("007", ["007"]),
            ("12345", ["12345"])
        ]
        for (expr, expect) in widths {
            do {
                let got = try IPSpec.expand(VariableDef(name: "N", kind: .number,
                                                        expression: expr)).map(\.text)
                check("编号宽度 \(expr)", got, expect)
            } catch {
                fail("编号宽度 \(expr) 异常: \(error)")
            }
        }
        do {
            let def = VariableDef(name: "N", kind: .number, expression: "0001-9999")
            let values = try IPSpec.expand(def).map(\.text)
            check("0001-9999 展开 9999 个", values.count, 9999)
            check("首值为 0001", values.first, "0001")
            check("末值为 9999", values.last, "9999")
            check("中间值按起始位数输出", values[998], "0999")
            let plan = ScanPlan(template: "http://example.com/live/{N}_1.m3u8",
                                variables: [def])
            let built = try plan.buildURLs()
            check("候选 URL 全部生成", built.urls.count, 9999)
            check("非法 URL 为 0", built.skipped, 0)
            check("首个 URL", built.urls.first,
                  "http://example.com/live/0001_1.m3u8")
            check("末个 URL", built.urls.last,
                  "http://example.com/live/9999_1.m3u8")
            checkTrue("该用例(0001-9999)所有 URL 编号均为 4 位",
                      built.urls.allSatisfy {
                          $0.range(of: #"/live/[0-9]{4}_1\.m3u8$"#,
                                   options: .regularExpression) != nil
                      },
                      "\(built.urls.prefix(2))")

            let combined = ScanPlan(template: "http://{A}:{P}/live/{N}_1.m3u8",
                                    variables: [
                                        VariableDef(name: "A", kind: .mixed, expression: "127.0.0.1,::1"),
                                        VariableDef(name: "P", kind: .port, expression: "8080"),
                                        VariableDef(name: "N", kind: .number, expression: "0001-0003")
                                    ])
            let both = try combined.buildURLs()
            check("IP + 端口 + 编号组合 = 6 个 URL", both.urls.count, 6)
            checkTrue("IPv6 主机位仍自动加方括号",
                      both.urls.contains("http://[::1]:8080/live/0002_1.m3u8"), "\(both.urls)")
        } catch {
            fail("编号区段检查异常: \(error)")
        }
    }

    func planChecks(port: Int) {
        print("\n[3] 候选 URL 生成")
        do {
            let plan = ScanPlan(template: "http://{A}:{P}/which", variables: [
                VariableDef(name: "A", kind: .mixed, expression: "127.0.0.1,::1"),
                VariableDef(name: "P", kind: .port, expression: "\(port),\(port + 1)")
            ])
            let built = try plan.buildURLs()
            check("2 IP x 2 端口 = 4 URL", built.urls.count, 4)
            checkTrue("IPv6 主机位带方括号", built.urls.contains { $0.contains("[::1]") }, "\(built.urls)")

            let dedupPlan = ScanPlan(template: "http://{A}/which", variables: [
                VariableDef(name: "A", kind: .mixed, expression: "127.0.0.1,127.0.0.1")
            ])
            check("重复取值去重", try dedupPlan.buildURLs().urls.count, 1)

            let badPlan = ScanPlan(template: "{A}:8080/which", variables: [
                VariableDef(name: "A", kind: .mixed, expression: "::1")
            ])
            let bad = try badPlan.buildURLs()
            check("非法 URL 被丢弃", [bad.urls.count, bad.skipped], [0, 1])
        } catch {
            fail("候选 URL 生成异常: \(error)")
        }
    }

    func startServer() throws -> MockServer {
        let tmp = NSTemporaryDirectory() + "scanaddr-selftest-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let portFile = tmp + "/port.txt"
        let logFile = tmp + "/requests.log"
        let script = root + "/tests/mock_server.py"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script, "--port-file", portFile, "--log-file", logFile]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        var port: Int?
        for _ in 0..<120 {
            if let text = try? String(contentsOfFile: portFile, encoding: .utf8),
               let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 {
                port = value
                break
            }
            if !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard let port else {
            process.terminate()
            throw NSError(domain: "scanaddr", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "mock server 启动失败或超时"])
        }
        return MockServer(process: process, port: port, logFile: logFile)
    }

    func runScan(template: String,
                 variables: [VariableDef],
                 configure: (inout ScanSettings) -> Void = { _ in }) async throws -> (urls: [String], hits: [ScanHit]) {
        var settings = ScanSettings()
        settings.timeout = 2.0
        settings.concurrency = 8
        configure(&settings)
        let built = try ScanPlan(template: template, variables: variables).buildURLs()
        let collector = HitCollector()
        let engine = ScanEngine(settings: settings)
        await engine.scan(urls: built.urls,
                          onHit: { collector.add($0) },
                          onProgress: { _, _ in })
        return (built.urls, collector.snapshot())
    }

    func networkChecks(port: Int, logFile: String) async {
        print("\n[4] 真实 HTTP 扫描（IPv4 + IPv6 双栈）")
        let v4v6 = [
            VariableDef(name: "A", kind: .mixed, expression: "127.0.0.1,::1"),
            VariableDef(name: "P", kind: .port, expression: "\(port)")
        ]
        do {
            let (urls, hits) = try await runScan(template: "http://{A}:{P}/which", variables: v4v6)
            check("/which 两个地址都可用", hits.count, 2)
            let v4 = hits.filter { $0.url.contains("127.0.0.1") }
            let v6 = hits.filter { $0.url.contains("[::1]") }
            checkTrue("IPv4 请求确实落在 IPv4 监听器", v4.count == 1 && v4[0].preview == "IPV4", "\(hits)")
            checkTrue("IPv6 请求确实落在 IPv6 监听器", v6.count == 1 && v6[0].preview == "IPV6", "\(hits)")
            checkTrue("IPv6 URL 为标准 [::1] 形式",
                      urls.contains("http://[::1]:\(port)/which"), "\(urls)")

            let (_, needleHits) = try await runScan(template: "http://{A}:{P}/needle", variables: v4v6) {
                $0.requireKeyword = "NEEDLE"
            }
            check("必须包含关键字 -> 2 个", needleHits.count, 2)

            let (_, absentHits) = try await runScan(template: "http://{A}:{P}/needle", variables: v4v6) {
                $0.requireKeyword = "NOT_PRESENT"
            }
            check("关键字不匹配 -> 0 个", absentHits.count, 0)

            let (_, excludedHits) = try await runScan(template: "http://{A}:{P}/needle", variables: v4v6) {
                $0.excludeKeyword = "NEEDLE"
            }
            check("排除关键字生效 -> 0 个", excludedHits.count, 0)

            let (_, badHits) = try await runScan(template: "http://{A}:{P}/bad", variables: v4v6)
            check("404 不计为可用", badHits.count, 0)

            let (_, code404Hits) = try await runScan(template: "http://{A}:{P}/bad", variables: v4v6) {
                $0.acceptedStatusMin = 404
                $0.acceptedStatusMax = 404
            }
            check("自定义状态码 404 可识别", code404Hits.count, 2)

            let (_, redirectHits) = try await runScan(template: "http://{A}:{P}/redirect", variables: v4v6) {
                $0.acceptedStatusMin = 200
                $0.acceptedStatusMax = 299
            }
            check("不跟随重定向（302 不算 2xx）", redirectHits.count, 0)

            let (_, slowHits) = try await runScan(template: "http://{A}:{P}/slow", variables: v4v6) {
                $0.timeout = 0.3
            }
            check("超时地址不计为可用", slowHits.count, 0)

            let multi = [
                VariableDef(name: "A", kind: .mixed, expression: "::1"),
                VariableDef(name: "B", kind: .mixed, expression: "127.0.0.1,192.0.2.1"),
                VariableDef(name: "P", kind: .port, expression: "\(port)")
            ]
            let (_, multiHits) = try await runScan(template: "http://{A}:{P}/echo?peer={B}&raw={A:raw}",
                                                   variables: multi)
            check("多变量 + 多位置变量扫描", multiHits.count, 2)
            checkTrue("路径/参数里的 IPv6 为裸地址",
                      multiHits.allSatisfy { $0.url.contains("raw=::1") && $0.url.contains("[::1]:") },
                      "\(multiHits.map(\.url))")
            checkTrue("服务器收到了合法的 query",
                      multiHits.allSatisfy { $0.preview.contains("raw=::1") },
                      "\(multiHits.map(\.preview))")

            let cidr6 = [
                VariableDef(name: "A", kind: .mixed, expression: "::1/128"),
                VariableDef(name: "P", kind: .port, expression: "\(port)")
            ]
            let (_, cidrHits) = try await runScan(template: "http://{A}:{P}/which", variables: cidr6)
            checkTrue("IPv6 CIDR 展开后可扫描",
                      cidrHits.count == 1 && cidrHits[0].preview == "IPV6", "\(cidrHits)")

            let ports = [
                VariableDef(name: "A", kind: .mixed, expression: "127.0.0.1"),
                VariableDef(name: "P", kind: .port, expression: "\(port)+2")
            ]
            let (portURLs, portHits) = try await runScan(template: "http://{A}:{P}/ok", variables: ports) {
                $0.timeout = 1.0
            }
            check("端口变量展开 2 个、命中 1 个", [portURLs.count, portHits.count], [2, 1])

            let log = (try? String(contentsOfFile: logFile, encoding: .utf8)) ?? ""
            checkTrue("服务器日志同时含 IPV4 与 IPV6 连接",
                      log.contains("IPV4 ") && log.contains("IPV6 "), String(log.prefix(300)))
        } catch {
            fail("真实扫描异常: \(error)")
        }
    }

    func finish() -> Never {
        print("\n结果: \(passed) 通过, \(failed) 失败")
        exit(failed == 0 ? 0 : 1)
    }
}

@main
struct SelfTestMain {
    static func main() async {
        let runner = Runner()
        print("scanaddr Swift 自检 (ScanCore)")
        runner.fixtureChecks()
        runner.numberChecks()

        var server: MockServer?
        do {
            server = try runner.startServer()
            print("\n  mock server 已启动，双栈端口 \(server!.port)")
            runner.planChecks(port: server!.port)
            await runner.networkChecks(port: server!.port, logFile: server!.logFile)
        } catch {
            runner.fail("自检中断: \(error)")
        }
        server?.process.terminate()
        runner.finish()
    }
}
