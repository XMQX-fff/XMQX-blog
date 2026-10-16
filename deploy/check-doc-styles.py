#!/usr/bin/env python3
"""检查整块内联 HTML 的页面用到的 class 是不是都有样式。

为什么需要这个检查：这些页面是整块内联 HTML，组件外观全靠
docs/.vitepress/theme/ 下 custom.css、agentnovel.css 里手写的规则撑着。
移植样式时漏掉一个 class，页面不会报错、不会崩，只是那个元素变成一坨
裸文字 —— 比如曾经漏了 .sec-num，1~12 的章节编号全变成了没有底色的
数字，很难一眼看出是样式丢了。

覆盖两批页面：
  * GraphRAG 两篇（custom.css）
  * AgentNovel 八篇（agentnovel.css，作用域 .vp-doc .an-doc）

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
    DOCS / "agentnovel" / "index.md",
    DOCS / "agentnovel" / "graph.md",
    DOCS / "agentnovel" / "rag.md",
    DOCS / "agentnovel" / "guardrails.md",
    DOCS / "agentnovel" / "guardrails-report.md",
    DOCS / "agentnovel" / "hitl.md",
    DOCS / "agentnovel" / "deai.md",
    DOCS / "agentnovel" / "entity.md",
]
STYLES = [
    DOCS / ".vitepress" / "theme" / "custom.css",
    DOCS / ".vitepress" / "theme" / "agentnovel.css",
]
# 这些 class 由 VitePress 主题或 shiki 提供，不归我们的样式文件管
ALLOWED_ELSEWHERE = {
    "lang", "line", "shiki", "headers", "vp-code",  # shiki 代码块
    "header-anchor", "copy",                         # VitePress 主题
    "router", "hitl",                                # 只有语义、没有样式：graph 页流程图节点标记
    "md",                                            # article 上的原文件标记，正文排版交给 .vp-doc
}
# shiki 风格的代码块语言标注（<code class="language-python">），同样不归我们管
ALLOWED_PREFIXES = ("language-",)


def main() -> int:
    for style in STYLES:
        if not style.exists():
            print(f"找不到 {style}", file=sys.stderr)
            return 2
    defined = set()
    for style in STYLES:
        defined |= set(re.findall(r"\.([a-zA-Z][\w-]*)", style.read_text(encoding="utf-8")))

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
        unknown = {
            c
            for c in used - defined - ALLOWED_ELSEWHERE
            if not c.startswith(ALLOWED_PREFIXES)
        }
        for cls in sorted(unknown):
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
