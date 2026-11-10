#!/usr/bin/env python3
"""scanaddr 核心逻辑的 Python 参考实现（仅用于本地自检）。

与 ScanCore/*.swift 共用 tests/fixtures.json，任何行为差异都必须先修正再编译 IPA。
"""
from __future__ import annotations

import ipaddress
import itertools
import re
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass


@dataclass(frozen=True)
class Candidate:
    text: str
    is_ipv6: bool


def make_candidate(raw: str) -> Candidate:
    text = raw.strip()
    is_ipv6 = _parse_ip(text) is not None and _parse_ip(text).version == 6
    if text.startswith("[") and text.endswith("]"):
        text = text[1:-1]
    return Candidate(text, is_ipv6)


def _parse_ip(raw: str):
    s = raw.strip()
    if s.startswith("["):
        s = s[1:]
    if s.endswith("]"):
        s = s[:-1]
    if "%" in s:
        s = s.split("%", 1)[0]
    try:
        return ipaddress.ip_address(s)
    except ValueError:
        return None


def _fmt(addr) -> str:
    return str(addr).lower()


def tokens(expression: str):
    return [p.strip() for p in re.split(r"[,;\s]+", expression.strip()) if p.strip()]


def _range_end(left: str, right: str, version: int):
    if right.isdigit():
        n = int(right)
        if version == 4:
            parts = left.split(".")
            parts[-1] = str(n)
            addr = _parse_ip(".".join(parts))
        else:
            idx = left.rfind(":")
            addr = _parse_ip(left[: idx + 1] + format(n, "x"))
        if addr is None:
            raise ValueError("bad range end: %s-%s" % (left, right))
        return addr
    addr = _parse_ip(right)
    if addr is None or addr.version != version:
        raise ValueError("bad range end: %s-%s" % (left, right))
    return addr


def _expand_ip(token: str, max_count: int):
    if max_count <= 0:
        raise ValueError("too many addresses: %s" % token)
    if "/" in token:
        left, right = token.split("/", 1)
        base = _parse_ip(left)
        if base is None or not right.isdigit():
            raise ValueError("bad cidr: %s" % token)
        prefix = int(right)
        if prefix < 0 or prefix > base.max_prefixlen:
            raise ValueError("bad cidr: %s" % token)
        net = ipaddress.ip_network("%s/%d" % (left, prefix), strict=False)
        return [_fmt(net.network_address + i) for i in range(min(net.num_addresses, max_count))]
    if "+" in token:
        left, right = token.split("+", 1)
        base = _parse_ip(left)
        if base is None or not right.isdigit() or int(right) <= 0:
            raise ValueError("bad plus: %s" % token)
        n = min(int(right), max_count)
        return [_fmt(base + i) for i in range(n)]
    if "-" in token:
        left, right = token.split("-", 1)
        start = _parse_ip(left)
        if start is None:
            raise ValueError("bad range: %s" % token)
        end = _range_end(left, right, start.version)
        if int(end) < int(start):
            raise ValueError("inverted range: %s" % token)
        out = []
        cur = start
        while True:
            out.append(_fmt(cur))
            if cur == end:
                break
            if len(out) >= max_count:
                raise ValueError("too many addresses: %s" % token)
            cur = cur + 1
        return out
    single = _parse_ip(token)
    if single is None:
        raise ValueError("bad ip: %s" % token)
    return [_fmt(single)]


def _expand_port(token: str, max_count: int):
    def num(s):
        if not s.isdigit():
            raise ValueError("bad port: %s" % token)
        v = int(s)
        if v > 65535:
            raise ValueError("bad port: %s" % token)
        return v

    if "-" in token:
        a, b = token.split("-", 1)
        lo, hi = num(a), num(b)
        if hi < lo or hi - lo + 1 > max_count:
            raise ValueError("bad port range: %s" % token)
        return [str(v) for v in range(lo, hi + 1)]
    if "+" in token:
        a, n = token.split("+", 1)
        lo, count = num(a), num(n)
        if count <= 0 or count > max_count:
            raise ValueError("bad port plus: %s" % token)
        return [str(lo + i) for i in range(count)]
    return [str(num(token))]


def expand(kind: str, expression: str, max_count: int = 65536):
    parts = tokens(expression)
    if not parts:
        raise ValueError("empty expression")
    out = []
    for part in parts:
        if kind == "text":
            chunk = [part]
        elif kind == "port":
            chunk = _expand_port(part, max_count - len(out))
        elif kind == "mixed":
            chunk = _expand_ip(part, max_count - len(out))
        else:
            raise ValueError("unknown kind: %s" % kind)
        out.extend(make_candidate(v).text for v in chunk)
        if len(out) > max_count:
            raise ValueError("too many addresses")
    if not out:
        raise ValueError("no values")
    return out


@dataclass
class Slot:
    name: str
    raw: bool
    in_host: bool
    start: int
    end: int
    bracketed: bool


class URLTemplate:
    def __init__(self, source: str):
        if not source.strip():
            raise ValueError("empty template")
        self.source = source
        marker = source.find("://")
        auth_start = marker + 3 if marker >= 0 else 0
        ends = [source.find(ch, auth_start) for ch in "/?#"]
        auth_end = min([i for i in ends if i >= 0] or [len(source)])
        self.slots = []
        cursor = 0
        while cursor < len(source):
            open_at = source.find("{", cursor)
            if open_at < 0:
                break
            close_at = source.find("}", open_at + 1)
            if close_at < 0:
                raise ValueError("unterminated placeholder")
            inner = source[open_at + 1: close_at]
            parts = inner.split(":")
            name = parts[0].strip()
            if not name:
                raise ValueError("empty variable name")
            raw = any(p.strip().lower() == "raw" for p in parts[1:])
            lower, upper = open_at, close_at + 1
            bracketed = False
            if open_at > 0 and upper < len(source) and source[open_at - 1] == "[" and source[upper] == "]":
                lower, upper = open_at - 1, upper + 1
                bracketed = True
            self.slots.append(Slot(name, raw, auth_start <= open_at < auth_end, lower, upper, bracketed))
            cursor = upper

    def names(self):
        seen = []
        for s in self.slots:
            if s.name not in seen:
                seen.append(s.name)
        return seen

    def render(self, row):
        out = []
        cursor = 0
        for slot in self.slots:
            cand = row[slot.name]
            out.append(self.source[cursor:slot.start])
            text = cand.text
            if text.startswith("[") and text.endswith("]"):
                text = text[1:-1]
            if slot.in_host and not slot.raw and cand.is_ipv6:
                text = "[" + text + "]"
            out.append(text)
            cursor = slot.end
        out.append(self.source[cursor:])
        return "".join(out)


def render_all(source: str, values: dict):
    """values: {name: [str]} -> 与 Swift ScanPlan 相同顺序的全部渲染结果。"""
    tpl = URLTemplate(source)
    names = tpl.names()
    columns = [[make_candidate(v) for v in values[n]] for n in names]
    if not columns:
        return [tpl.render({})]
    result = []
    for combo in itertools.product(*columns):
        result.append(tpl.render(dict(zip(names, combo))))
    return result


def build_urls(source: str, variables: list, max_candidates: int = 200000, deduplicate=True):
    """variables: [{name, kind, expression}]"""
    tpl = URLTemplate(source)
    names = tpl.names()
    pool = {v["name"]: [make_candidate(x) for x in expand(v["kind"], v["expression"])] for v in variables}
    columns = [pool[n] for n in names]
    urls, seen, skipped = [], set(), 0
    combos = itertools.product(*columns) if columns else [()]
    for combo in combos:
        candidate = tpl.render(dict(zip(names, combo)))
        parsed = urllib.request.urlparse(candidate)
        if parsed.scheme in ("http", "https") and parsed.hostname:
            if not deduplicate or candidate not in seen:
                seen.add(candidate)
                urls.append(candidate)
        else:
            skipped += 1
    if len(urls) + skipped > max_candidates:
        raise ValueError("too many candidates")
    return urls, skipped


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def probe(url: str, settings: dict):
    opener = urllib.request.build_opener(_NoRedirect)
    req = urllib.request.Request(url, method=settings.get("method", "GET"),
                                 headers={"User-Agent": "scanaddr/1.0", "Connection": "close"})
    try:
        resp = opener.open(req, timeout=settings.get("timeout", 2.0))
        status, data = resp.status, resp.read(settings.get("max_body", 65536) + 1)
    except urllib.error.HTTPError as e:
        status, data = e.code, e.read(settings.get("max_body", 65536) + 1)
    except Exception:
        return None
    lo, hi = settings.get("status_min", 200), settings.get("status_max", 399)
    if not (min(lo, hi) <= status <= max(lo, hi)):
        return None
    body = data[: settings.get("max_body", 65536)].decode("utf-8", "replace")
    need = settings.get("require", "")
    ban = settings.get("exclude", "")
    if need and need not in body:
        return None
    if ban and ban in body:
        return None
    return {"url": url, "status": status, "preview": body[:160]}


def scan(urls, settings):
    hits = []
    with ThreadPoolExecutor(max_workers=max(1, min(settings.get("concurrency", 24), len(urls)))) as pool:
        futures = [pool.submit(probe, u, settings) for u in urls]
        for fut in as_completed(futures):
            hit = fut.result()
            if hit:
                hits.append(hit)
    return sorted(hits, key=lambda h: h["url"])
