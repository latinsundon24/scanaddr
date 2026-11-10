# scanaddr

iOS 上的「可用 URL 扫描器」。把一个带 IP 占位符的 URL 模板展开成大量候选地址，逐个真实发起 HTTP 请求，只列出真正能访问、且符合判定规则的 URL。**IPv4 与 IPv6 都支持**，无第三方依赖（SwiftUI + Foundation/URLSession）。

## 能做什么

- **多位置变量**：模板里可以有任意多个变量，每个变量可以在 URL 的任意位置出现多次。
  `http://{A}:{P}/check?peer={B}&raw={A:raw}`
  同名变量（上例两个 `{A}`）始终使用同一个值；不同变量按笛卡尔积组合。
- **IPv6 自动处理**：主机位的 IPv6 会自动写成标准 `[addr]`；模板里写 `[{A}]` 时，若实际取值是 IPv4 会自动去掉方括号。路径/参数位置一律插入裸地址。`{A:raw}` 可强制不加括号。
- **变量类型**
  - `IP (v4/v6)`：单个地址、`CIDR`、起止范围、起始+N，可用逗号/空格/换行混写多段。
    `192.168.1.1-192.168.1.254`、`10.0.0.0/24`、`::1/128`、`2001:db8::1-2001:db8::ff`、`2001:db8::1+32`、`[::1]`
  - `端口`：`80,443,8080`、`8000-8100`、`8080+10`
  - `文本`：任意字符串列表
  - IPv4 范围的纯数字简写按十进制（`1.2.3.8-10`），IPv6 末段简写按十六进制；`+N` 一律为十进制数量。
- **可用判定**：HTTP 状态码范围（默认 200–399）、响应体必须包含 / 不得包含的关键字、超时、并发数、是否跟随重定向。结果记录状态码、耗时、响应大小，可单条或全部复制。
- **安全限制**：单个变量最多展开 65536 个取值，默认组合上限 200000，防止 `/8`、`/64` 之类把设备打爆；非法 URL 会被跳过。

## 使用方法

1. 填入 URL 模板，例如 `http://{A}:{P}/status`。
2. 变量表会自动列出模板中的 `{A}`、`{P}`，为每个变量选类型并填取值表达式。
3. 按需设置超时、并发、状态码与关键字；点「计算组合数」确认扫描规模。
4. 点「开始扫描」，在「可用 URL」页查看、复制结果。

内置三个预设：IPv4 段扫描、IPv6 段扫描、多变量/多位置扫描。

> 请只扫描自己拥有或已获授权的目标，遵守所在网络与法律的规定。

## 自检（编译前必须全部通过）

`tests/fixtures.json` 是 Swift 实现与 Python 参考实现共用的用例集：

```bash
python3 tests/selftest.py     # 本地：地址展开、模板渲染 + 真实双栈 HTTP 扫描
```

CI 上另有等价的 Swift 自检，直接编译 `ScanCore/*.swift` 后运行：

```bash
swiftc -O -parse-as-library -o scanaddr-selftest ScanCore/*.swift tests/SelfTestMain.swift
./scanaddr-selftest
```

自检会启动 `tests/mock_server.py`（同一端口分别监听 `127.0.0.1` 与 `::1`），并用真实 HTTP 请求验证：IPv4/IPv6 都能扫到、`/which` 返回的 `IPV4`/`IPV6` 标记与连接协议一致、关键字过滤、404 与超时不误报、多变量多位置 URL 合法、IPv6 CIDR 与端口变量可扫描。

`.github/workflows/build-ipa.yml` 拆成两个 job：`selftest` 全部通过，`build` 才会启动（GitHub Actions 的 `needs:` 保证），因此**自检失败不会产出 IPA**。

## 编译 IPA

推送到 `main` 或手动触发 workflow 即可。构建 job 用 XcodeGen 生成工程，`xcodebuild` 以 Release 编译未签名的 iOS device app，再打包成 `scanaddr-<版本>-unsigned.ipa`，附 SHA-256，作为 Actions artifact 上传。版本号为 `1.0.<run_number>`。

未签名 IPA 适用于越狱设备、TrollStore 或自行重签名安装，不能用 Apple ID 直接普通安装。

## 目录

```
ScanCore/       纯 Swift 核心（IP 展开、模板、候选生成、并发 HTTP 探测），无 UI 依赖
ScanAddr/       SwiftUI 界面与 Info.plist
tests/          共享 fixtures、双栈 mock server、Python 参考实现、Swift 自检入口
project.yml     XcodeGen 工程定义
```
