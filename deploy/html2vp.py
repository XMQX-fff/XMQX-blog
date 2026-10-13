#!/usr/bin/env python3
"""把 docs/public/ 下的手写 HTML 文档转成 VitePress 页面。

为什么转换：这两份文档是独立的手写 HTML，有自己的 header、左侧目录、
排版和配色，和站点的 VitePress 主题完全不是一套东西；而且它们只是被
nginx 当静态文件发出去，客户端路由不认识，站内的前进/后退行为也不对。

转换做的事：
  * 去掉自带的 header / 左侧 nav / footer / TOC 滚动高亮脚本 —— 这些由
    VitePress 的导航栏、侧边栏、右侧大纲接管；
  * <pre> 代码块转成围栏代码块，语言标注交给 Shiki（原来那几个是手写 span
    标的颜色，只能配深色底，跟主题的浅色代码块对不上）；
  * 其余内容原样保留为内联 HTML，套在 VitePress 的 .vp-doc 排版之下；
  * 折叠 HTML 块内部的空行。CommonMark 里 HTML 块遇到空行就结束，
    后面会被当成 markdown 再解析一遍，正文里的 * _ [ 就会被误当成语法。

用法: html2vp.py <输入html> <输出md> <标题> <描述> <前言html片段>
"""

import html as html_mod
import re
import sys
from pathlib import Path

DROP_BLOCKS = [
    (re.compile(r"<header\b.*?</header>", re.S | re.I), "header"),
    (re.compile(r"<nav\b[^>]*class=\"toc\"[^>]*>.*?</nav>", re.S | re.I), "nav.toc"),
    (re.compile(r"<nav\b[^>]*id=\"toc\"[^>]*>.*?</nav>", re.S | re.I), "nav.toc(id)"),
    (re.compile(r"<footer\b.*?</footer>", re.S | re.I), "footer"),
    (re.compile(r"<script\b.*?</script>", re.S | re.I), "script"),
]


def strip_chrome(body: str) -> str:
    """去掉自带的外壳，只留下正文。"""
    for rx, _name in DROP_BLOCKS:
        body = rx.sub("", body)

    # <div class="layout"> 是 sidebar + main 的网格容器，去掉外壳留 main
    body = re.sub(r'<div\b[^>]*class="layout"[^>]*>\s*', "", body, flags=re.I)
    body = re.sub(r"</div>\s*(?=<footer|</body|$)", "", body, flags=re.I)
    # main 标签本身由 VitePress 的 .vp-doc 取代
    body = re.sub(r"<main\b[^>]*>\s*", "", body, flags=re.I)
    body = re.sub(r"\s*</main>", "", body, flags=re.I)
    return body.strip()


def classify_pre(chunk: str, lang_hint: str) -> str:
    """判断代码块该标什么语言。

    原来这些块是手写 span 上色的，没有语言信息。含 Python 关键字的按 python
    处理，剩下的是 ASCII 示意图，用 text 免得被高亮成一片彩色。
    """
    text = html_mod.unescape(re.sub(r"<[^>]+>", "", chunk))
    if lang_hint:
        return lang_hint
    py = len(re.findall(r"\b(?:def |class |import |from |return |self|None|True|False|async |await |for |if )\b", text))
    return "python" if py >= 3 else "text"


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


def convert_pres(body: str) -> str:
    """<pre>...</pre> → 围栏代码块。

    转换后再折叠空行才安全：围栏里的空行是代码内容，不能动。
    """

    def repl(m: re.Match) -> str:
        chunk = m.group(1)
        # 抽出真实文本内容（去掉手写的 span 上色）
        text = html_mod.unescape(re.sub(r"<[^>]+>", "", chunk))
        text = text.strip("\n")
        # 围栏内容里出现 ``` 会提前闭合
        if "```" in text:
            fence = "~~~~"
            if text.count("~~~"):
                fence = "`````"
        else:
            fence = "```"
        lang = classify_pre(chunk, m.group(2) or "")
        # 示意图不标语言：标了 text 会在代码块右上角挂一个 "text" 标签，纯噪音。
        # 不标则 VitePress 不做高亮，只套 .vp-code 的样式，浅色深色都协调。
        if lang == "text":
            lang = ""
        return f"\n\n{fence}{lang}\n{text}\n{fence}\n\n"

    rx = re.compile(r"<pre\b[^>]*data-lang=\"([^\"]*)\"[^>]*>(.*?)</pre>", re.S | re.I)
    rx2 = re.compile(r"<pre\b[^>]*>(.*?)</pre>", re.S | re.I)
    body = rx.sub(lambda m: repl(_named(m, m.group(2), m.group(1))), body)
    body = rx2.sub(lambda m: repl(_named(m, m.group(1), "")), body)
    return body


def _named(m: re.Match, chunk: str, lang: str) -> re.Match:
    class _P:
        pass

    p = _P()
    p.group = lambda i: {1: chunk, 2: lang}[i]
    return p


def collapse_blank_lines(text: str) -> str:
    """删掉 HTML 区里的所有空行（围栏代码块内的空行要保留）。

    CommonMark 的 HTML 块（第 6 类）遇到空行就结束，之后的内容会被重新交给
    markdown 解析。本文档正文里大量出现 * _ [ ` 这些字符，一旦被当成 markdown，
    下划线会被吃掉、方括号会变成链接。所以正文必须是一整块不间断的 HTML。

    围栏代码块是另一回事：里面的空行是代码内容，必须原样保留，而且围栏前后
    各留一个空行才能被识别成独立的块。
    """
    out: list[str] = []
    in_fence = False
    fence_marker = ""

    for line in text.split("\n"):
        stripped = line.strip()
        is_fence = (stripped.startswith("```") or stripped.startswith("~~~")) and not in_fence

        if in_fence:
            out.append(line)
            if stripped.startswith(fence_marker):
                in_fence = False
            continue

        if is_fence:
            # 围栏前保证恰好一个空行
            while out and out[-1] == "":
                out.pop()
            out.append("")
            fence_marker = stripped[:3]
            in_fence = True
            out.append(line)
            continue

        if not stripped:
            continue  # 正文区的空行一律删掉
        out.append(line)

    while out and out[-1] == "":
        out.pop()
    return "\n".join(out)


def build(title: str, desc: str, lead: str, body: str) -> str:
    fm = [
        "---",
        f"title: {title}",
        f"description: {desc}",
        "outline: [2, 3]",
        "---",
        "",
        f"# {title}",
        "",
    ]
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

    body = strip_chrome(body)
    body = escape_quotes_in_attrs(body)
    body = convert_pres(body)
    body = collapse_blank_lines(body)

    dst.write_text(build(title, desc, lead, body), encoding="utf-8")
    print(f"写入 {dst}  ({len(dst.read_text(encoding='utf-8'))} 字节)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())