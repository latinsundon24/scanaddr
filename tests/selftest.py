#!/usr/bin/env python3
"""本地自检（Windows / macOS 均可跑）：
1) 用共享 fixtures 校验地址展开与 URL 模板渲染；
2) 启动双栈 mock HTTP 服务器，用参考实现真实发起 IPv4 / IPv6 扫描，
   验证「可用 URL 能被扫出来、不可用 URL 不会被误报」。

全部通过返回 0，任一失败返回 1。CI 上另有 Swift 版同等自检作为编译门禁。
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import reference_scan as ref  # noqa: E402

PASSED = 0
FAILED = 0


def check(name, actual, expected):
    global PASSED, FAILED
    if actual == expected:
        PASSED += 1
        print("  PASS  %s" % name)
    else:
        FAILED += 1
        print("  FAIL  %s\n        expect: %r\n        actual: %r" % (name, expected, actual))


def check_true(name, condition, detail=""):
    global PASSED, FAILED
    if condition:
        PASSED += 1
        print("  PASS  %s" % name)
    else:
        FAILED += 1
        print("  FAIL  %s  %s" % (name, detail))


def fixture_checks():
    data = json.loads((HERE / "fixtures.json").read_text(encoding="utf-8"))
    print("\n[1] 地址展开 / 变量语法 (%d cases)" % len(data["expand"]))
    for case in data["expand"]:
        try:
            got = ref.expand(case["kind"], case["expression"])
        except Exception as exc:
            check(case["name"], "EXCEPTION: %s" % exc, case["expect"])
        else:
            check(case["name"], got, case["expect"])

    print("\n[2] 多位置变量 / IPv6 方括号 / 笛卡尔积 (%d cases)" % len(data["render"]))
    for case in data["render"]:
        try:
            got = ref.render_all(case["template"], case["values"])
        except Exception as exc:
            check(case["name"], "EXCEPTION: %s" % exc, case["expect"])
        else:
            check(case["name"], got, case["expect"])


def plan_checks(port):
    print("\n[3] 候选 URL 生成")
    urls, skipped = ref.build_urls(
        "http://{A}:{P}/which",
        [
            {"name": "A", "kind": "mixed", "expression": "127.0.0.1,::1"},
            {"name": "P", "kind": "port", "expression": "%d,%d" % (port, port + 1)},
        ],
    )
    check("2 IP x 2 端口 = 4 URL", len(urls), 4)
    check_true("IPv6 主机位带方括号", any("[::1]" in u for u in urls), str(urls))

    dedup, _ = ref.build_urls(
        "http://{A}/which",
        [{"name": "A", "kind": "mixed", "expression": "127.0.0.1,127.0.0.1"}],
    )
    check("重复取值去重", len(dedup), 1)

    bad, skipped_bad = ref.build_urls(
        "{A}:8080/which",
        [{"name": "A", "kind": "mixed", "expression": "::1"}],
    )
    check("非法 URL 被丢弃", (len(bad), skipped_bad), (0, 1))


def start_server():
    tmp = tempfile.mkdtemp(prefix="scanaddr-selftest-")
    port_file = os.path.join(tmp, "port.txt")
    log_file = os.path.join(tmp, "requests.log")
    proc = subprocess.Popen(
        [sys.executable, str(HERE / "mock_server.py"),
         "--port-file", port_file, "--log-file", log_file],
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
    )
    deadline = time.time() + 12
    while time.time() < deadline:
        if os.path.exists(port_file) and os.path.getsize(port_file) > 0:
            return proc, int(Path(port_file).read_text().strip()), log_file, tmp
        if proc.poll() is not None:
            err = proc.stderr.read().decode("utf-8", "replace")
            raise RuntimeError("mock server 启动失败: " + err)
        time.sleep(0.1)
    proc.kill()
    raise RuntimeError("mock server 启动超时（端口文件未生成）")


def network_checks(port, log_file):
    print("\n[4] 真实 HTTP 扫描（IPv4 + IPv6 双栈）")
    base = {"timeout": 2.0, "concurrency": 8}

    def run(template, variables, **overrides):
        settings = dict(base)
        settings.update(overrides)
        urls, _ = ref.build_urls(template, variables)
        return urls, ref.scan(urls, settings)

    v4v6 = [
        {"name": "A", "kind": "mixed", "expression": "127.0.0.1,::1"},
        {"name": "P", "kind": "port", "expression": str(port)},
    ]

    urls, hits = run("http://{A}:{P}/which", v4v6)
    check("/which 两个地址都可用", len(hits), 2)
    v4 = [h for h in hits if "127.0.0.1" in h["url"]]
    v6 = [h for h in hits if "[::1]" in h["url"]]
    check_true("IPv4 请求确实落在 IPv4 监听器", len(v4) == 1 and v4[0]["preview"] == "IPV4", str(hits))
    check_true("IPv6 请求确实落在 IPv6 监听器", len(v6) == 1 and v6[0]["preview"] == "IPV6", str(hits))
    check_true("IPv6 URL 为标准 [::1] 形式", len(urls) == 2 and "http://[::1]:%d/which" % port in urls, str(urls))

    _, hits = run("http://{A}:{P}/needle", v4v6, require="NEEDLE")
    check("必须包含关键字 -> 2 个", len(hits), 2)
    _, hits = run("http://{A}:{P}/needle", v4v6, require="NOT_PRESENT")
    check("关键字不匹配 -> 0 个", len(hits), 0)
    _, hits = run("http://{A}:{P}/needle", v4v6, exclude="NEEDLE")
    check("排除关键字生效 -> 0 个", len(hits), 0)
    _, hits = run("http://{A}:{P}/bad", v4v6)
    check("404 不计为可用", len(hits), 0)
    _, hits = run("http://{A}:{P}/bad", v4v6, status_min=404, status_max=404)
    check("自定义状态码 404 可识别", len(hits), 2)
    _, hits = run("http://{A}:{P}/redirect", v4v6, status_min=200, status_max=299)
    check("不跟随重定向（302 不算 2xx）", len(hits), 0)
    _, hits = run("http://{A}:{P}/slow", v4v6, timeout=0.3)
    check("超时地址不计为可用", len(hits), 0)

    multi = [
        {"name": "A", "kind": "mixed", "expression": "::1"},
        {"name": "B", "kind": "mixed", "expression": "127.0.0.1,192.0.2.1"},
        {"name": "P", "kind": "port", "expression": str(port)},
    ]
    urls, hits = run("http://{A}:{P}/echo?peer={B}&raw={A:raw}", multi)
    check("多变量 + 多位置变量扫描", len(hits), 2)
    check_true("路径/参数里的 IPv6 为裸地址", all("raw=::1" in h["url"] and "[::1]:" in h["url"] for h in hits), str(hits))
    check_true("服务器收到了合法的 query", all("raw=::1" in h["preview"] for h in hits), str(hits))

    cidr6 = [
        {"name": "A", "kind": "mixed", "expression": "::1/128"},
        {"name": "P", "kind": "port", "expression": str(port)},
    ]
    _, hits = run("http://{A}:{P}/which", cidr6)
    check_true("IPv6 CIDR 展开后可扫描", len(hits) == 1 and hits[0]["preview"] == "IPV6", str(hits))

    ports = [
        {"name": "A", "kind": "mixed", "expression": "127.0.0.1"},
        {"name": "P", "kind": "port", "expression": "%d+2" % port},
    ]
    urls, hits = run("http://{A}:{P}/ok", ports, timeout=1.0)
    check("端口变量展开 2 个、命中 1 个", (len(urls), len(hits)), (2, 1))

    log = Path(log_file).read_text(encoding="utf-8", errors="replace")
    check_true("服务器日志同时含 IPV4 与 IPV6 连接", "IPV4 " in log and "IPV6 " in log, log[:300])


def main():
    print("scanaddr 本地自检 (Python 参考实现)")
    fixture_checks()
    proc = None
    try:
        proc, port, log_file, _ = start_server()
        print("\n  mock server 已启动，双栈端口 %d" % port)
        plan_checks(port)
        try:
            network_checks(port, log_file)
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
    except Exception as exc:
        global FAILED
        FAILED += 1
        print("  FAIL  自检中断: %s" % exc)
        if proc and proc.poll() is None:
            proc.kill()

    print("\n结果: %d 通过, %d 失败" % (PASSED, FAILED))
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
