#!/usr/bin/env python3
"""把独立的手写 HTML 文档转成 VitePress 页面。

为什么转换：这些文档是独立的手写 HTML，有自己的 header、左侧目录、
排版和配色，和站点的 VitePress 主题完全不是一套东西；而且它们只是被
nginx 当静态文件发出去，客户端路由不认识，站内的前进/后退行为也不对。

两种版式，靠正文里有没有 <header class="hero"> 自动识别：

* GraphRAG 版式（html2vp 的老客户）：<header>/<nav class="toc">/<footer>/
  <script> 外壳 + .layout/<main> 网格。
* AgentNovel 版式：.topbar + 可收起 <aside class="sidenav"> + hero 头图 +
  <footer> + 侧栏脚本；hero 里还挂着一份和右侧大纲重复的页内目录。

转换做的事：
  * 去掉自带的外壳 —— 导航栏、侧边栏、右侧大纲由 VitePress 接管；
  * 正文里的 .html 互链改写成 VitePress 路由（AgentNovel 版式）；
  * 其余内容原样保留为内联 HTML，套在 VitePress 的 .vp-doc 排版之下，
    AgentNovel 版式额外包一层 .an-doc，组件样式按它做作用域隔离；
  * 折叠 HTML 块内部的空行。CommonMark 里 HTML 块遇到空行就结束，
    后面会被当成 markdown 再解析一遍，正文里的 * _ [ 就会被误当成语法。

用法: html2vp.py <输入html> <输出md> <标题> <描述> <前言html片段>
"""

import html as html_mod
import re
import sys
from pathlib import Path

GRAPHRAG_DROP_BLOCKS = [
    (re.compile(r"<header\b.*?</header>", re.S | re.I), "header"),
    (re.compile(r"<nav\b[^>]*class=\"toc\"[^>]*>.*?</nav>", re.S | re.I), "nav.toc"),
    (re.compile(r"<nav\b[^>]*id=\"toc\"[^>]*>.*?</nav>", re.S | re.I), "nav.toc(id)"),
    (re.compile(r"<footer\b.*?</footer>", re.S | re.I), "footer"),
    (re.compile(r"<script\b.*?</script>", re.S | re.I), "script"),
]

AGENTNOVEL_DROP_BLOCKS = [
    # topbar 是两层嵌套的 div（.topbar > .inner），要连着收掉两个闭合标签
    (re.compile(r'<div\b[^>]*class="topbar"[^>]*>.*?</div>\s*</div>', re.S | re.I), "topbar"),
    (re.compile(r'<div\b[^>]*class="sb-mask"[^>]*>.*?</div>', re.S | re.I), "sb-mask"),
    (re.compile(r'<aside\b[^>]*class="sidenav"[^>]*>.*?</aside>', re.S | re.I), "sidenav"),
    (re.compile(r"<nav\b[^>]*>.*?</nav>", re.S | re.I), "nav"),
    # hero 里的 .toc 和右侧「本页目录」是同一份内容，去掉
    (re.compile(r'<div\b[^>]*class="toc"[^>]*>.*?</div>', re.S | re.I), "hero toc"),
    (re.compile(r"<footer\b.*?</footer>", re.S | re.I), "footer"),
    (re.compile(r"<script\b.*?</script>", re.S | re.I), "script"),
]

# AgentNovel 七篇文档在博客里的落点：正文互链按这张表改写成站点路由
AGENTNOVEL_ROUTES = {
    "index.html": "/agentnovel/",
    "graph.html": "/agentnovel/graph",
    "rag.html": "/agentnovel/rag",
    "guardrails-report.html": "/agentnovel/guardrails-report",
    "hitl.html": "/agentnovel/hitl",
    "deai.html": "/agentnovel/deai",
    "entity.html": "/agentnovel/entity",
}

HERO_RX = re.compile(r'<header\b[^>]*class="[^"]*\bhero\b', re.I)
HREF_RX = re.compile(r'href="([\w-]+\.html)"', re.I)


def strip_graphrag_chrome(body: str) -> str:
    """去掉 GraphRAG 版式的外壳，只留下正文。"""
    for rx, _name in GRAPHRAG_DROP_BLOCKS:
        body = rx.sub("", body)

    # <div class="layout"> 是 sidebar + main 的网格容器，去掉外壳留 main
    body = re.sub(r'<div\b[^>]*class="layout"[^>]*>\s*', "", body, flags=re.I)
    body = re.sub(r"</div>\s*(?=<footer|</body|$)", "", body, flags=re.I)
    # main 标签本身由 VitePress 的 .vp-doc 取代
    body = re.sub(r"<main\b[^>]*>\s*", "", body, flags=re.I)
    body = re.sub(r"\s*</main>", "", body, flags=re.I)
    return body.strip()


def strip_agentnovel_chrome(body: str) -> str:
    """去掉 AgentNovel 版式的外壳；hero 头图保留。"""
    for rx, _name in AGENTNOVEL_DROP_BLOCKS:
        body = rx.sub("", body)
    return body.strip()


def rewrite_agentnovel_links(body: str) -> str:
    """正文里指向其它文档的 .html 链接改成站点路由，否则这些链接会 404。"""

    def repl(m: re.Match) -> str:
        route = AGENTNOVEL_ROUTES.get(m.group(1).lower())
        return f'href="{route}"' if route else m.group(0)

    return HREF_RX.sub(repl, body)


HEADING_RX = re.compile(r"<(h[1-4])([^>]*)>(.*?)</\1>", re.S | re.I)
ID_RX = re.compile(r"""\bid=["']([^"']+)["']""")
TAG_OPEN_RX = re.compile(r"""<(/?)([a-zA-Z][\w-]*)((?:[^>"']|"[^"]*"|'[^']*')*)>""")


def slugify(text: str) -> str:
    """给没有 id 的标题生成锚点。小写、非字母数字换成连字符，兼容中文。"""
    s = re.sub(r"<[^>]+>", "", text)
    s = re.sub(r"\s+", "-", s.strip())
    s = re.sub(r"[^\w\u4e00-\u9fff-]", "", s)
    return s.strip("-").lower() or "section"


def inject_heading_ids(body: str) -> str:
    """给每个标题注入 id。

    两件事靠它：
    1. 右侧「本页目录」靠锚点跳转，标题没 id 就跳不动；
    2. 原页面自己的目录链接指向 <section id="l1"> 这类锚点，沿用它们可以
       保证老的 #l1 / #s4-1 链接继续有效。

    规则：标题所处的最近一层带 id 的祖先（section/div）优先作为锚点，
    没有就按标题文本生成一个。
    """
    # 先扫一遍，记下每个标题落在哪个祖先 id 下
    ancestors: list[str] = []   # 当前打开且带 id 的元素
    owner: dict[int, str] = {}  # 标题起始位置 -> 锚点
    for m in TAG_OPEN_RX.finditer(body):
        closing, tag, attrs = m.group(1), m.group(2).lower(), m.group(3)
        if closing:
            if ancestors and ancestors[-1][1] == tag:
                ancestors.pop()
            continue
        mid = ID_RX.search(attrs)
        if mid:
            ancestors.append((mid.group(1), tag))
        elif tag in ("h1", "h2", "h3", "h4"):
            owner[m.start()] = ancestors[-1][0] if ancestors else ""

    used: set[str] = set()

    def repl(m: re.Match) -> str:
        tag, attrs, inner = m.group(1).lower(), m.group(2), m.group(3)
        if ID_RX.search(attrs):
            return m.group(0)
        base = owner.get(m.start()) or slugify(inner)
        if base in used:
            base = f"{base}-{len(used)}"
        used.add(base)
        return f'<{tag} id="{base}"{attrs}>{inner}</{tag}>'

    return HEADING_RX.sub(repl, body)


# 用 [^<>]*?（非贪婪）+ 后瞻把闭合引号锚死在「>` 之前。
# 不能用贪婪的 [^<>]*：它会把闭合引号本身也吞进捕获组，转义时给属性末尾
# 又补一个 &quot;，比原来还坏。非贪婪 + 「引号后必须紧跟 >」才能在正文里
# 存在内层引号时定位到真正的属性结尾（内层引号后面跟的一定不是 >）。
ATTR_RX = re.compile(r"""\b(title|alt)="([^<>]*?)"\s*(?=[/>])""")
# 属性后面还跟了别的属性时的兜底
ATTR_RX_FALLBACK = re.compile(r"""\b(title|alt)="([^"<>]*)""")


def escape_quotes_in_attrs(body: str) -> str:
    """把 title/alt 属性值内部的引号转义成 &quot;。

    源文件里有多处 `title="...能"看见"的..."` 这种写法 —— 中文正文里拿双引号
    做强调，但没转义，浏览器会在第一个内层引号处就把属性截断，tooltip 直接
    变成半截。这是源文件本来就有的问题，顺手在转换时修掉。
    """
    body = ATTR_RX.sub(
        lambda m: f'{m.group(1)}="{m.group(2).replace(chr(34), "&quot;")}"', body
    )
    return ATTR_RX_FALLBACK.sub(
        lambda m: f'{m.group(1)}="{m.group(2).replace(chr(34), "&quot;")}"', body
    )


def collapse_blank_lines(text: str) -> str:
    """删掉正文里的所有空行，让整篇成为一整块不间断的 HTML。

    为什么必须这样：CommonMark 的 HTML 块遇到空行就结束，之后的内容会被重新
    当成 markdown 解析。本文��正文里大量出现 * _ [ ` 这些字符，一旦被当成
    markdown，下划线会被吃掉、方括号会变成链接。

    代价是文档里不能混 markdown 块（尤其是代码围栏）——围栏前面必须有空行才能
    被识别，而那个空行会把 HTML 块截断，截断之后 4 空格缩进的正文行会被 markdown
    当成「缩进代码块」整段吞进 <pre>。所以代码块保持原生 <pre><code> 标签。
    """
    text = re.sub(r"[ \t]+\n", "\n", text)
    text = re.sub(r"\n{2,}", "\n", text)
    return text.strip()


def build(title: str, desc: str, lead: str, body: str) -> str:
    fm = [
        "---",
        f"title: {title}",
        f"description: {desc}",
        "outline: [2, 3]",
        "---",
        "",
    ]
    # AgentNovel 的 hero 自带 <h1>，再补一个 markdown 标题会渲染出两个 h1
    if not re.search(r"<h1[\s>]", body, re.I):
        fm += [f"# {title}", ""]
    if lead:
        fm += [lead.strip(), ""]
    return "\n".join(fm) + body.strip() + "\n"


def main() -> int:
    if len(sys.argv) != 6:
        print(__doc__, file=sys.stderr)
        return 2
    src, dst, title, desc, lead = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]

    raw = src.read_text(encoding="utf-8")
    m = re.search(r"<body[^>]*>(.*)</body>", raw, re.S | re.I)
    body = m.group(1) if m else raw

    agentnovel = bool(HERO_RX.search(body))
    if agentnovel:
        body = strip_agentnovel_chrome(body)
        body = rewrite_agentnovel_links(body)
    else:
        body = strip_graphrag_chrome(body)
    body = escape_quotes_in_attrs(body)
    body = inject_heading_ids(body)
    body = collapse_blank_lines(body)
    if agentnovel:
        # 组件样式统一挂在 .vp-doc .an-doc 之下，避免和别的栏目互相污染
        body = f'<div class="an-doc">\n{body}\n</div>'

    dst.write_text(build(title, desc, lead, body), encoding="utf-8")
    print(f"写入 {dst}  ({len(dst.read_text(encoding='utf-8'))} 字节)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())