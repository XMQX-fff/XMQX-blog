#!/usr/bin/env python3
"""独立复核：线上 CSP 是否真的覆盖了产物里每一段内联脚本。

deploy/install.sh 在重载 nginx 之后会调这个脚本。它不信 install.sh 的中间结果，
而是重新从「运行中的站点」取 CSP 头，再和 dist 里的字节重新算一遍哈希：

  线上 CSP 里少一个哈希 → 浏览器会静默拦掉那段脚本
  （页面照常渲染，暗色模式/目录高亮/搜索之类的功能却是坏的，极难排查）

顺带检查 CSP 里有没有被误写成 'unsafe-inline' / 'unsafe-eval'。

用法: verify-csp.py <base_url> <dist目录>
"""

import base64
import hashlib
import os
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlparse

SCRIPT_RE = re.compile(rb"<script([^>]*)>(.*?)</script>", re.S | re.I)
HAS_SRC_RE = re.compile(rb"""\bsrc\s*=""", re.I)
TYPE_RE = re.compile(rb"""\btype\s*=\s*["']?([A-Za-z0-9._+-]+)""", re.I)
JS_TYPES = {
    b"module",
    b"text/javascript",
    b"application/javascript",
    b"text/ecmascript",
    b"application/ecmascript",
    b"text/jscript",
    b"text/livescript",
    b"text/x-javascript",
    b"text/x-ecmascript",
}
# 标签上的外链地址：src / href
URL_ATTR_RE = re.compile(rb"""(?:src|href)\s*=\s*["']([^"']+)["']""", re.I)
TAG_RE = re.compile(rb"""<(?:script|link|img|iframe)\b[^>]*>""", re.I)


def is_executable(attrs: bytes) -> bool:
    """这段 <script> 会不会被浏览器执行（因而需要 CSP 哈希）。"""
    m = TYPE_RE.search(attrs)
    if not m:
        return True
    return m.group(1).lower() in JS_TYPES


def host_of(url: str) -> str:
    if url.startswith("//"):
        url = "https:" + url
    return (urlparse(url).hostname or "").lower()


def is_offsite(url: str, site_host: str) -> bool:
    """地址是不是指向站外。站内绝对地址（canonical、og:image）放行。"""
    if not url:
        return False
    if url.startswith(("http://", "https://", "//")):
        return host_of(url) != site_host
    return False


def live_csp(base: str) -> str:
    cmd = ["curl", "-s", "-D", "-", "-o", "/dev/null", "--max-time", "10"]
    # 站点按域名提供，测试时把域名钉到 127.0.0.1，免得依赖公网端口是否放行
    resolve = os.environ.get("XMQX_CURL_RESOLVE", "")
    if resolve:
        cmd += ["--resolve", resolve]
    cmd.append(base + "/")
    out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
    for line in out.splitlines():
        name, _, value = line.partition(":")
        if name.strip().lower() == "content-security-policy":
            return value.strip()
    return ""


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    base, dist = sys.argv[1].rstrip("/"), Path(sys.argv[2])

    csp = live_csp(base)
    if not csp:
        print("站点没有返回 Content-Security-Policy 响应头", file=sys.stderr)
        return 1

    directive = next(
        (d.strip() for d in csp.split(";") if d.strip().lower().startswith("script-src")), ""
    )
    allowed = set(re.findall(r"'sha256-[A-Za-z0-9+/=]+'", directive))
    failures: list[str] = []

    for bad in ("'unsafe-inline'", "'unsafe-eval'"):
        if bad in directive:
            failures.append(f"script-src 里出现了不该有的 {bad}")

    needed: set[str] = set()
    site_host = host_of(base)
    for html in sorted(dist.rglob("*.html")):
        blob = html.read_bytes()
        for attrs, body in SCRIPT_RE.findall(blob):
            if HAS_SRC_RE.search(attrs) or not body.strip():
                continue
            if not is_executable(attrs):
                continue
            raw = base64.b64encode(hashlib.sha256(body).digest()).decode()
            needed.add("'sha256-" + raw + "'")
        for tag in TAG_RE.findall(blob):
            for url in URL_ATTR_RE.findall(tag):
                url = url.decode("utf-8", "replace")
                if is_offsite(url, site_host):
                    failures.append(f"{html}: 引用了站外资源，CSP script-src 'self' 会拦下来：{tag[:120]!r}")

    for h in sorted(needed - allowed):
        failures.append(f"CSP 缺少内联脚本哈希 {h}，该脚本会被浏览器执行拦截")

    print(f"  {'ok  ' if not failures else 'FAIL'} CSP script-src 覆盖检查："
          f"产物需要 {len(needed)} 个哈希，线上允许 {len(allowed)} 个")
    for f in failures:
        print(f"       - {f}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())