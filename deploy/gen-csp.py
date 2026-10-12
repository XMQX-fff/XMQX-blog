#!/usr/bin/env python3
"""扫描 dist 里的 HTML，输出 CSP script-src 需要的所有内联脚本哈希。

VitePress 会在每个页面注入三段固定的内联脚本（暗色模式判断、macOS 判断、
路由 hash 表），docs/public 下的手写 HTML 也各自带一段内联脚本。用哈希而不是
'unsafe-inline' 白名单，这样即使将来某段内容被注入恶意代码，浏览器也会拒绝执行。

两个容易踩的坑，这里都处理了：
  1. 哈希必须取 <script> 元素的**逐字节** text content，做任何 strip/换行归一化
     都会和浏览器算出的不一致，结果是脚本被直接拦掉（页面看着正常，功能没了）。
  2. 全程按 bytes 处理，不经过 str 解码，避免 BOM / 非法字节 / 编码猜测影响结果。

用法: gen-csp.py <dist目录>
输出: 'sha256-A' 'sha256-B' ...
"""

import base64
import hashlib
import re
import sys
from pathlib import Path

# 在 bytes 上跑，避免任何解码带来的不确定性
SCRIPT_RE = re.compile(rb"<script([^>]*)>(.*?)</script>", re.S | re.I)
# 带 src= 的外链脚本不需要哈希，script-src 'self' 已经覆盖
HAS_SRC_RE = re.compile(rb"""\bsrc\s*=""", re.I)


def digests(dist: Path) -> list[str]:
    out: set[str] = set()
    for html in sorted(dist.rglob("*.html")):
        blob = html.read_bytes()
        for attrs, body in SCRIPT_RE.findall(blob):
            if HAS_SRC_RE.search(attrs):
                continue
            if not body.strip():
                continue
            raw = hashlib.sha256(body).digest()
            out.add("'sha256-" + base64.b64encode(raw).decode() + "'")
    return sorted(out)


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    dist = Path(sys.argv[1]).resolve()
    if not dist.is_dir():
        print(f"not a directory: {dist}", file=sys.stderr)
        return 2
    hashes = digests(dist)
    if not hashes:
        print("no inline script found", file=sys.stderr)
        return 1
    print(" ".join(hashes))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())