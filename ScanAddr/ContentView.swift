import SwiftUI
import UIKit

private let decimalFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.maximumFractionDigits = 1
    return f
}()

private let integerFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .none
    f.minimum = 1
    return f
}()

struct ContentView: View {
    @StateObject private var vm = ScanViewModel()

    var body: some View {
        NavigationView {
            Form {
                Section("URL 模板") {
                    TextField("http://{A}:{P}/status", text: $vm.template)
                        .font(.system(.footnote, design: .monospaced))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.never)
                        .onChange(of: vm.template) { _ in vm.syncVariables() }
                    Text("用 {名称} 标记要替换的位置，可出现在主机、路径、文件名、参数的任意位置，也可出现多次（同名变量同值）。把 URL 里要扫的编号换成 {N} 即可。主机位的 IPv6 会自动补 [ ]；{名称:raw} 强制使用裸地址。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack {
                        Button("IPv4 示例") { vm.loadPreset(.ipv4) }
                        Spacer()
                        Button("IPv6 示例") { vm.loadPreset(.ipv6) }
                        Spacer()
                        Button("多变量示例") { vm.loadPreset(.multi) }
                    }
                    .font(.caption)
                }

                Section("变量 (\(vm.variables.count))") {
                    if vm.variables.isEmpty {
                        Text("模板里还没有 {变量}").font(.caption).foregroundColor(.secondary)
                    }
                    ForEach(vm.variables.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("{\(vm.variables[i].name)}")
                                    .font(.system(.body, design: .monospaced))
                                    .bold()
                                Spacer()
                                Picker("类型", selection: $vm.variables[i].kind) {
                                    ForEach(VariableKind.allCases) { kind in
                                        Text(kind.label).tag(kind)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                            }
                            TextField("取值表达式", text: $vm.variables[i].expression)
                                .font(.system(.footnote, design: .monospaced))
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .textInputAutocapitalization(.never)
                            Text(hint(for: vm.variables[i].kind))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section("扫描参数") {
                    Picker("请求方法", selection: $vm.settings.method) {
                        Text("GET").tag("GET")
                        Text("HEAD").tag("HEAD")
                    }
                    Toggle("跟随重定向", isOn: $vm.settings.acceptRedirects)
                    HStack {
                        Text("超时(秒)")
                        Spacer()
                        TextField("2", value: $vm.settings.timeout, formatter: decimalFormatter)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }
                    HStack {
                        Text("并发数")
                        Spacer()
                        TextField("24", value: $vm.settings.concurrency, formatter: integerFormatter)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }
                    HStack {
                        Text("状态码")
                        Spacer()
                        TextField("200", value: $vm.settings.acceptedStatusMin, formatter: integerFormatter)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 60)
                        Text("~")
                        TextField("399", value: $vm.settings.acceptedStatusMax, formatter: integerFormatter)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 60)
                    }
                    TextField("响应必须包含（可空）", text: $vm.settings.requireKeyword)
                        .autocapitalization(.none).disableAutocorrection(true)
                    TextField("响应不得包含（可空）", text: $vm.settings.excludeKeyword)
                        .autocapitalization(.none).disableAutocorrection(true)
                    HStack {
                        Text("组合上限")
                        Spacer()
                        TextField("200000", value: $vm.maxCandidates, formatter: integerFormatter)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 110)
                    }
                }

                Section("运行") {
                    Button {
                        vm.refreshPreview()
                    } label: {
                        Label("计算组合数", systemImage: "number")
                    }
                    Text(vm.previewText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack {
                        if vm.isScanning {
                            Button(role: .destructive) { vm.stop() } label: {
                                Label("停止扫描", systemImage: "stop.fill")
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button { vm.start() } label: {
                                Label("开始扫描", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        Spacer()
                        Button("清空结果") { vm.clearResults() }
                            .disabled(vm.isScanning)
                    }
                    if vm.total > 0 {
                        ProgressView(value: Double(vm.scanned), total: Double(max(vm.total, 1)))
                        Text("已扫 \(vm.scanned)/\(vm.total)，命中 \(vm.hits.count)")
                            .font(.caption)
                    }
                    if !vm.notice.isEmpty {
                        Text(vm.notice).font(.caption).foregroundColor(.orange)
                    }
                }

                Section("结果") {
                    NavigationLink {
                        ResultView(hits: vm.hits)
                    } label: {
                        HStack {
                            Label("可用 URL", systemImage: "checkmark.circle")
                            Spacer()
                            Text("\(vm.hits.count)").foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("scanaddr")
        }
        .navigationViewStyle(.stack)
    }

    private func hint(for kind: VariableKind) -> String {
        switch kind {
        case .mixed:
            return "IPv4/IPv6 均可：1.2.3.4、1.2.3.4/24、1.2.3.4-1.2.3.10、1.2.3.4+20；::1/128、2001:db8::1-2001:db8::ff。逗号/换行分隔多段。"
        case .port:
            return "80,443,8080 / 8000-8100 / 8080+10"
        case .number:
            return "编号区段：直接填起止数值，按你写的数字原样逐个展开，位数不限、不改写数值。0001-9999 / 01-99 / 000001-999999 / 0001+50 / 0001,0003-0005；单变量上限 65536 个。"
        case .text:
            return "逗号或换行分隔的任意字符串"
        }
    }
}

struct ResultView: View {
    let hits: [ScanHit]
    @State private var copied = false

    var body: some View {
        List {
            if hits.isEmpty {
                Text("暂无可用 URL。设置模板与变量后返回上一页开始扫描。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            ForEach(hits) { hit in
                VStack(alignment: .leading, spacing: 6) {
                    Text(hit.url)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                    HStack {
                        Label("HTTP \(hit.status)", systemImage: "checkmark.circle")
                        Text("\(hit.elapsedMs) ms")
                        Text("\(hit.bytes) B")
                        Spacer()
                        Button("复制") {
                            UIPasteboard.general.string = hit.url
                            copied = true
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
        .navigationTitle("可用 URL (\(hits.count))")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("复制全部") {
                    UIPasteboard.general.string = hits.map(\.url).joined(separator: "\n")
                    copied = true
                }
                .disabled(hits.isEmpty)
            }
        }
        .overlay(alignment: .bottom) {
            if copied {
                Text("已复制到剪贴板")
                    .font(.caption)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 16)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }
            }
        }
    }
}
