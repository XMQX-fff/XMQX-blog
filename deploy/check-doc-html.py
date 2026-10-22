#!/usr/bin/env python3
"""检查内联 HTML 里的属性名是否合法。

为什么需要这个检查：这批页面是整块内联 HTML，属性写坏了有两个出口。

服务端返回的 HTML 由浏览器解析器处理，遇到非法属性名它会直接丢掉这个
属性，页面看着好好的；等客户端路由接管、Vue 拿同一份属性重新渲染时，
非法属性名会原样交给 setAttribute，浏览器抛 InvalidCharacterError，
整页正文渲染不出来（Firefox 上表现为白屏）。

真实踩过的坑：手写 HTML 里 title="……文字"" 多写了一个引号。浏览器把
多出来的那个引号当成一个名叫 " 的属性，Vue setAttribute('"') 直接抛异常，
GraphRAG 教程页在 Firefox 140 上整页空白，Chrome 却看不出来。

所以这里按 HTML 语法把标签里的属性切出来：属性名含引号、空格等非法
字符就报错，属性值后面多跟一个引号同样报错。

用法: check-doc-html.py <docs目录>
"""

import re
import sys
from pathlib import Path

DOCS = Path(sys.argv[1] if len(sys.argv) > 1 else "docs")
# 标签名必须是普通名字。像 <https://…> 这种自动链接、<!DOCTYPE> 之类跳过
TAG_NAME_RX = re.compile(r"[a-zA-Z][a-zA-Z0-9-]*")
# 属性名里出现这些字符就是非法名：浏览器解析时丢弃，Vue setAttribute 时抛异常
BAD_NAME_CHARS = set('"\'>/=')
# 扫标签前先去掉这几块：里面的 <> 是示例代码，不是真标签
SKIP_BLOCK_RX = re.compile(
    r"```.*?```"          # 围栏代码块
    r"|~~~.*?~~~"         # 波浪号围栏
    r"|<pre\b.*?</pre>"   # 原生 pre 块
    r"|`[^`\n]*`",        # 行内代码
    re.S | re.I,
)


def blank_out(text: str) -> str:
    """把代码块内容抹掉，但保留行数，好让报错的行号对得上原文。"""
    def repl(m: re.Match) -> str:
        return "\n" * m.group(0).count("\n")
    return SKIP_BLOCK_RX.sub(repl, text)


def iter_tags(text: str):
    """产出 (行号, 标签原文)。只认真正的标签，注释和自动链接跳过。"""
    i = 0
    n = len(text)
    while i < n:
        lt = text.find("<", i)
        if lt < 0:
            return
        if text.startswith("<!--", lt):
            end = text.find("-->", lt)
            i = n if end < 0 else end + 3
            continue
        m = TAG_NAME_RX.match(text, lt + 1)
        if not m or text[m.end():m.end() + 1] not in " \t\n\r/>":
            i = lt + 1
            continue
        # 找标签结尾的 '>'，引号里的 '>' 不算
        j = m.end()
        quote = None
        while j < n:
            c = text[j]
            if quote:
                if c == quote:
                    quote = None
            elif c in "\"'":
                quote = c
            elif c == ">":
                break
            j += 1
        yield text.count("\n", 0, lt) + 1, text[lt:j + 1]
        i = j + 1


def check_tag(tag: str, line: int, path: Path, problems: list[str]) -> None:
    m = TAG_NAME_RX.match(tag, 1)
    body = tag[m.end():-1]  # 去掉标签名和结尾的 '>'
    i = 0
    n = len(body)
    while i < n:
        c = body[i]
        if c.isspace() or c == "/":
            i += 1
            continue
        start = i
        while i < n and not body[i].isspace() and body[i] not in "=/>":
            i += 1
        name = body[start:i]
        if not name:
            i += 1
            continue
        if any(ch in BAD_NAME_CHARS for ch in name) or name[0] in "\"'":
            problems.append(f"{path}:{line}: 属性名非法 {name!r}（浏览器会丢弃它，Vue 重新渲染时会抛异常）")
            return
        j = i
        while j < n and body[j].isspace():
            j += 1
        if j >= n or body[j] != "=":
            continue  # 无值属性
        j += 1
        while j < n and body[j].isspace():
            j += 1
        if j < n and body[j] in "\"'":
            close = body.find(body[j], j + 1)
            j = n if close < 0 else close + 1
        else:
            while j < n and not body[j].isspace():
                j += 1
        i = j
        if i < n and body[i] in "\"'":
            problems.append(f"{path}:{line}: 属性 {name}=… 后面多了一个引号（{body[i]}）")
            return


def main() -> int:
    if not DOCS.is_dir():
        print(f"找不到 {DOCS}", file=sys.stderr)
        return 2

    problems: list[str] = []
    pages = sorted(p for p in DOCS.rglob("*.md") if ".vitepress" not in p.parts)
    for page in pages:
        text = blank_out(page.read_text(encoding="utf-8"))
        for line, tag in iter_tags(text):
            check_tag(tag, line, page.relative_to(DOCS), problems)

    if problems:
        print("内联 HTML 属性检查未通过：", file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        return 1

    print(f"  {len(pages)} 个页面的内联 HTML 属性名都合法")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
