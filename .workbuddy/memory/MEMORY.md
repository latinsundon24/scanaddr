# scanaddr 项目长期笔记

## 项目定位
GitHub `latinsundon24/scanaddr`，本地 `F:/scanaddr`。iOS 应用：按 URL 模板中的多个 IP 位置变量，扫描真实可用的 URL，IPv4 / IPv6 都要能扫。交付形式为 GitHub Actions 编译的未签名 IPA。

## 工程约定
- `ScanCore/`：纯 Swift 核心（IP 展开、模板渲染、候选生成、并发 HTTP 探测），不依赖 UIKit，可被 macOS `swiftc` 直接编译用于自检。
- `ScanAddr/`：SwiftUI 界面 + 手写 `Info.plist`（`INFOPLIST_FILE` 引用，ATS 开启 `NSAllowsArbitraryLoads` 以支持 http:// 明文 IP）。
- `project.yml`：XcodeGen，无 CocoaPods / SPM 依赖；`CODE_SIGNING_ALLOWED=NO` 产出未签名包。
- `tests/`：共享 fixtures、双栈 mock_server.py、Python 参考实现、Swift 自检入口。

## 硬性规则
- **自检不过不编译**：`build-ipa.yml` 拆为 `selftest` 与 `build` 两个 job，`needs: selftest`。两侧都跑同一份 fixtures，并启动 127.0.0.1 / ::1 同端口双栈 server 做真实 HTTP 扫描验证。
- **runner 必须用 `macos-15`**：`macos-14` 在该账户下不受支持（`macos-14-arm64-us-default` 配置错误），会导致 run 在调度前被取消。`macos-latest` / `macos-15-intel` 亦可用。
- IPv4 数值存放在 `IPNumber.lo` 的低 32 位，IPv6 用 hi:lo 128 位；任何掩码/位运算都要区分 bits==32 与 128。
- 改核心逻辑后先本地 `python tests/selftest.py`，再 push 让 CI Swift 自检验证，通过后才出 IPA。
