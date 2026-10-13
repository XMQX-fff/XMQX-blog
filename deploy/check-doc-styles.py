#!/usr/bin/env python3
"""检查 GraphRAG 两页用到的 class 是不是都有样式。

为什么需要这个检查：这两页是整块内联 HTML，组件外观全靠
docs/.vitepress/theme/custom.css 里手写的规则撑着。移植样式时漏掉一个
class，页面不会报错、不会崩，只是那个元素变成一坨裸文字 —— 比如曾经漏了
.sec-num，1~12 的章节编号全变成了没有底色的数字，很难一眼看出是样式丢了。

这个脚本在每次构建后跑，漏了直接报出来。

用法: check-doc-styles.py <docs目录>
"""

import re
import sys
from pathlib import Path

DOCS = Path(sys.argv[1] if len(sys.argv) > 1 else "docs")
PAGES = [
    DOCS / "graphrag" / "nano-graphrag-tutorial.md",
    DOCS / "graphrag" / "nano-graphrag-source-analysis.md",
]
STYLE = DOCS / ".vitepress" / "theme" / "custom.css"
# 这些 class 由 VitePress 主题或 shiki 提供，不归 custom.css 管
ALLOWED_ELSEWHERE = {
    "lang", "line", "shiki", "headers", "vp-code",  # shiki 代码块
    "header-anchor", "copy",                         # VitePress 主题
}


def main() -> int:
    if not STYLE.exists():
        print(f"找不到 {STYLE}", file=sys.stderr)
        return 2
    defined = set(re.findall(r"\.([a-zA-Z][\w-]*)", STYLE.read_text(encoding="utf-8")))

    problems: list[str] = []
    for page in PAGES:
        if not page.exists():
            problems.append(f"缺少页面 {page}")
            continue
        used = {
            c
            for attrs in re.findall(r'class="([^"]+)"', page.read_text(encoding="utf-8"))
            for c in attrs.split()
        }
        for cls in sorted(used - defined - ALLOWED_ELSEWHERE):
            n = len(re.findall(r'class="[^"]*\b%s\b' % re.escape(cls), page.read_text(encoding="utf-8")))
            problems.append(f"{page.name}: .{cls} 用了 {n} 次，但没有对应样式")

    if problems:
        print("文档样式检查未通过：", file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        return 1

    print("  文档用到的 class 都有样式")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())