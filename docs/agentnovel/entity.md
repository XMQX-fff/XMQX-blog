---
title: 实体归一化（角色别名）详细设计
description: 实体归一化（角色别名）详细设计：rag.py 子查询构造与入库前缀、角色模型与前端设定中心，已实现并通过回归测试。
outline: [2, 3]
---
<div class="an-doc">
<header class="hero">
  <div class="wrap">
    <div class="eyebrow">Entity Normalization · Design</div>
    <h1 id="实体归一化角色别名详细设计">实体归一化（角色别名）详细设计</h1>
    <blockquote>
<p>
<strong>项目</strong>：NovelCraft AI — 基于 LangGraph 的智能小说创作助手
<strong>范围</strong>：<code>app/core/rag.py</code> 子查询构造与入库前缀、<code>app/core/state.py</code> 角色模型、前端设定中心
<strong>状态</strong>：<strong>已实现</strong>（后端 + 前端 + 22 条回归，见 §9）
<strong>关联</strong>：<code>docs/html/rag.html</code> §5（前缀富化）、§8（分条召回）、§11（查询全过程）
<strong>文档日期</strong>：2026-10-08</p>
</blockquote>
  </div>
</header>
<article class="md wrap">
<h2 id="0-要解决的问题">0. 要解决的问题</h2><p>
同一角色在正文里叫法多样：<code>林晚</code> / <code>阿晚</code> / <code>林家小姐</code>。当前实现下这会<strong>静默失配</strong>：</p>
<div class="tbl-wrap"><table>
<thead>
<tr>
<th>
位置</th>
<th>
现状</th>
<th>
后果</th>
</tr>
</thead>
<tbody>
<tr>
<td>
入库前缀 <code>_names_in()</code><br><code>rag.py:1443</code></td>
<td>
<code>n in text</code> 精确匹配<strong>规范名</strong></td>
<td>
正文写「阿晚」的块，前缀里<strong>没有</strong>「出场：林晚」</td>
</tr>
<tr>
<td>
子查询 <code>build_story_queries_with_info()</code><br><code>rag.py:735</code></td>
<td>
只用 <code>f&quot;{c['name']} {c.get('role','')}&quot;</code></td>
<td>
查「林晚」召不回只写「阿晚」的块</td>
</tr>
<tr>
<td>
出场判定<br><code>rag.py:765-766</code></td>
<td>
<code>str(c[&quot;name&quot;]) in stage_text</code></td>
<td>
章纲写「阿晚出场」→ 该角色被判为<strong>非出场</strong>，排到 off_stage 末位被截断</td>
</tr>
</tbody>
</table></div>
<p>
三处是<strong>同一个根因</strong>：系统只认规范名，而正文不认。</p>
<p>
<strong>为什么必须在检索层解决</strong>：长篇里&quot;同一人物多种叫法&quot;是叙事必需
（亲昵称呼、尊称、化名），属于正常写作行为。让作者改文风来迁就检索是本末倒置。</p>
<hr />
<h2 id="1-关键决策别名合并进一条子查询">1. 关键决策：别名<strong>合并进一条子查询</strong></h2><p>
原始设想是「查 <code>林晚</code> 自动追加子查询 <code>阿晚</code>」。<strong>实测否掉了这个做法</strong>，改用合并。</p>
<h3 id="11-实测依据">1.1 实测依据</h3><p>
真实语料（3 个真实章节，18,469 字 → 62 块），把正文中 70% 的「素世」替换成外号「世酱」
以模拟别名密集文本，用稀疏检索（与 <code>sparse.encode_text</code> + Qdrant <code>Modifier.IDF</code> 同构）
跑同一子查询，看 top-8 里有几个是「含外号的块」（全库共 51 块）：</p>
<div class="tbl-wrap"><table>
<thead>
<tr>
<th>
子查询形态</th>
<th>
top-8 命中外号块</th>
</tr>
</thead>
<tbody>
<tr>
<td>
① 只用规范名 <code>素世 主角</code></td>
<td>
<strong>7 / 8</strong></td>
</tr>
<tr>
<td>
② <strong>合并一条</strong> <code>素世 世酱 主角</code></td>
<td>
<strong>8 / 8</strong></td>
</tr>
<tr>
<td>
③ 只用外号 <code>世酱 主角</code></td>
<td>
8 / 8</td>
</tr>
</tbody>
</table></div>
<p>
<strong>结论</strong>：合并成一条的效果<strong>等于</strong>单独查外号，比只查规范名更好。</p>
<h3 id="12-为什么合并成一条">1.2 为什么合并成一条</h3><div class="tbl-wrap"><table>
<thead>
<tr>
<th>
</th>
<th>
合并进一条</th>
<th>
各自成独立子查询</th>
</tr>
</thead>
<tbody>
<tr>
<td>
名额消耗</td>
<td>
0 条</td>
<td>
每别名 1 条，<code>MAX_SUBQUERIES=6</code> 立刻被挤爆</td>
</tr>
<tr>
<td>
实际影响</td>
<td>
—</td>
<td>
扣掉章纲 1 + 伏笔 2，只剩 3 个名额；<strong>伏笔与出场角色被别名挤掉</strong></td>
</tr>
<tr>
<td>
轮转合并</td>
<td>
一条子查询贡献自己的第一名</td>
<td>
别名与规范名抢同一个第一名，可能互相顶掉</td>
</tr>
<tr>
<td>
检索账本</td>
<td>
<code>queries</code> 不变</td>
<td>
<code>queries</code> 暴涨，<code>dropped</code> 开始有值，作者看到&quot;漏检&quot;噪声</td>
</tr>
</tbody>
</table></div>
<h3 id="13-为什么合并不会造成质心问题">1.3 为什么合并不会造成「质心」问题</h3><p>
<code>rag.html</code> §8 批评过&quot;把多个实体拼成一条 query 会得到质心&quot;。<strong>别名是那个例外的例外</strong>：</p>
<ul>
<li>
被批评的场景：章纲 + 12 个<strong>互不相关</strong>的角色名 → 向量是它们的平均，<strong>语义发散</strong></li>
<li>
别名场景：<code>林晚</code> / <code>阿晚</code> / <code>林家小姐</code> 指向<strong>同一个实体</strong>，语义<strong>同向</strong></li>
</ul>
<p>
同向词的平均不会破坏方向，只会把「这个人」的语义<strong>加强并覆盖多个写法</strong>。这正是我们要的。</p>
<hr />
<h2 id="2-数据模型aliases-挂在-character-上不建新表">2. 数据模型：<code>aliases</code> 挂在 <code>Character</code> 上，不建新表</h2><pre><code class="language-python"># app/core/state.py · class Character
class Character(TypedDict):
    ...
    aliases: List[str]        # 新增：同一角色的其它叫法（外号/尊称/简称）
</code></pre>
<h3 id="为什么不建独立表-不放-sidecar">为什么不建独立表 / 不放 sidecar</h3><div class="tbl-wrap"><table>
<thead>
<tr>
<th>
方案</th>
<th>
问题</th>
</tr>
</thead>
<tbody>
<tr>
<td>
新建 <code>character_aliases</code> 表</td>
<td>
① 读角色要 join；② <strong>别名不在 checkpoint 里 → 时间旅行回退时角色设定回退了、别名没有</strong>，产生不一致——违反本系统最硬的约束；③ 多一套备份/迁移</td>
</tr>
<tr>
<td>
放 <code>sidecar_events</code></td>
<td>
该表是<strong>追加式事件日志</strong>（<code>log_key, seq, payload</code>）。它不存状态：拿它当权威数据必须在读路径上重放日志，等于凭空多一条读路径 + 一个新失败模式</td>
</tr>
</tbody>
</table></div>
<p>
放 <code>Character.aliases</code> 的理由：</p>
<ol>
<li>
<strong>别名是角色的属性</strong>，天然随角色一起被 <code>apply_ops.upsert</code> 写进 State</li>
<li>
<strong>checkpoint 已有</strong> → 时间旅行、快照回退自动一致（<code>rag.html</code> §8 要求&quot;同输入同结果&quot;）</li>
<li>
<strong>写入路径已存在</strong>：<code>app/api/routers/state.py</code> 的 <code>update_state</code> → <code>apply_ops</code>，无需新接口</li>
<li>
<strong>不引入新表</strong> = 不引入新的备份、迁移、一致性问题</li>
<li>
前端设定中心已有角色编辑表单，加一个标签输入框成本最低</li>
</ol>
<blockquote>
<p>
<strong>前置条件</strong>：跨项目共享的外号词典不在本设计范围。若将来需要，应作为独立的全局词表，
塞进 <code>Character</code> 不合适。</p>
</blockquote>
<hr />
<h2 id="3-逐文件改动清单">3. 逐文件改动清单</h2><h3 id="31-数据模型">3.1 数据模型</h3><p>
<strong><code>app/core/state.py</code> · <code>class Character</code>（第 236 行，<code>aliases</code> 在 244、<code>tier</code> 在 247）</strong></p>
<pre><code class="language-python">class Character(TypedDict):
    id: str
    name: str
    role: str
    aliases: List[str]        # ← 新增
    tier: str                 # ← 顺手补齐（见下）
    gender: str
    ...
</code></pre>
<p>
顺带修一处<strong>已有漂移</strong>：前端 <code>Character</code> 有 <code>tier?: string</code>（角色层级），后端 TypedDict 没有，
导致前端那个字段永远读不到。既然要动这个 TypedDict，一并补上。</p>
<p>
<code>state.py:424</code> 的初始 <code>character_settings=[]</code> 不受影响。</p>
<h3 id="32-归一化的单一入口新增-5-个函数">3.2 归一化的单一入口（新增 1 个常量 + 5 个函数）</h3><p>
<strong><code>app/core/rag.py:135-211</code></strong> — 放在 <code>_rrf_merge</code> 之后、<code>LocalRAG</code> 之前的检索工具区：</p>
<pre><code class="language-python">def _char_entries(state) -&gt; List[Dict[str, Any]]:
    &quot;&quot;&quot;全部角色 + 展开别名。**归一化的唯一入口**——三个消费方都走它，
    避免三处各写一遍展开逻辑而互相漂移。&quot;&quot;&quot;
    out = []
    for c in (state.get(&quot;character_settings&quot;) or []):
        if not isinstance(c, dict):
            continue
        name = str(c.get(&quot;name&quot;) or &quot;&quot;).strip()
        if not name:
            continue
        aliases = [str(a).strip() for a in (c.get(&quot;aliases&quot;) or []) if str(a).strip()]
        out.append({
            &quot;id&quot;: str(c.get(&quot;id&quot;) or &quot;&quot;),
            &quot;name&quot;: name,
            &quot;role&quot;: str(c.get(&quot;role&quot;) or &quot;&quot;),
            &quot;aliases&quot;: [a for a in aliases if a != name and len(a) &gt;= 2],  # 规范名不重复进别名表；单字别名噪声大于收益
            &quot;raw&quot;: c,   # ← 见 §9「与设计稿的偏差」：入库文本还要用 personality / background / appearance 等散文字段
        })
    return out
def _all_names(entry) -&gt; List[str]:
    &quot;&quot;&quot;规范名 + 别名（**有序：规范名在前**），保证输出稳定可复现。&quot;&quot;&quot;
    return [entry[&quot;name&quot;], *entry[&quot;aliases&quot;]]
def _match_in(text: str, entry) -&gt; Optional[str]:
    &quot;&quot;&quot;文本里是否提到该角色（认别名）。命中返回**规范名**。
    为什么必须认别名：正文写「阿晚」而规范名是「林晚」时，`&quot;林晚&quot; in text` 为假，
    入库前缀就不会写「出场：林晚」，该块在角色查询下**永远召不回**——
    这是根问题，比查询侧展开更致命。
    &quot;&quot;&quot;
    for n in _all_names(entry):
        if n and n in text:
            return entry[&quot;name&quot;]
    return None
def _query_text(entry) -&gt; str:
    &quot;&quot;&quot;角色子查询文本 = 规范名 + 全部别名 + 定位。
    别名**合并进同一条**：实测合并的召回等于单独查别名（8/8 vs 7/8），
    而独立成条会挤占 `MAX_SUBQUERIES=6` 的名额，把伏笔和出场角色顶掉
    （`rag.html` §8 实测过的坑）。
    别名之间用空格分隔 —— `sparse.bigrams()` 按空白分字段、不跨窗
    （见 `app/core/sparse.py`），所以不会造出「阿晚林」这类伪 bigram。
    &quot;&quot;&quot;
    return &quot; &quot;.join([*_all_names(entry), entry[&quot;role&quot;]]).strip()
</code></pre>
<blockquote>
<p>
<code>_all_names</code> 必须<strong>规范名在前</strong>：<code>_names_in</code> 按此顺序输出，进前缀的字符串要稳定，
否则同一段文本在两次索引里可能产出不同前缀，破坏幂等覆盖。</p>
</blockquote>
<h3 id="33-写侧入库前缀富化-收益最大的改动">3.3 写侧（入库前缀富化）—— <strong>收益最大的改动</strong></h3><p>
<strong><code>app/core/rag.py</code> · <code>_names_in()</code>（第 1443 行）与 <code>_character_names()</code>（第 1434 行）</strong></p>
<pre><code class="language-python"># 现状：只返回规范名列表，且用 `n in text` 精确匹配
def _character_names(state): return [str(c.get(&quot;name&quot;)).strip() for c in ...]
def _names_in(text, names):  return [n for n in names if n in text][:ENRICH_MAX_NAMES]
# 改为
def _names_in(text: str, entries: List[Dict[str, Any]]) -&gt; List[str]:
    &quot;&quot;&quot;本块里实际出现的角色**规范名**（按设定表顺序，保证确定性）。
    与旧版的区别：① 认别名（正文写「阿晚」也算命中「林晚」）；
    ② 输出**规范名**，不输出命中的那个写法 —— 前缀里必须只有规范名，
    否则引用卡 / `_format_context` 会把同一个角色显示成两三个名字。
    &quot;&quot;&quot;
    hit = []
    for e in entries:
        if _match_in(text, e) and e[&quot;name&quot;] not in hit:
            hit.append(e[&quot;name&quot;])
            if len(hit) &gt;= ENRICH_MAX_NAMES:
                break
    return hit
</code></pre>
<p>
<strong>连带改动（必须一起改，否则别名会漏进索引）</strong>：</p>
<div class="tbl-wrap"><table>
<thead>
<tr>
<th>
位置</th>
<th>
现状</th>
<th>
改为</th>
</tr>
</thead>
<tbody>
<tr>
<td>
<code>rag.py:1434</code> <code>_character_names()</code></td>
<td>
返回 <code>List[str]</code>（规范名）</td>
<td>
改为返回 <code>_char_entries(state)</code>，或直接让调用方改用 <code>_char_entries</code></td>
</tr>
<tr>
<td>
<code>rag.py:1240</code> <code>index_chapter(...)</code> 签名</td>
<td>
<code>character_names: Optional[List[str]]</code></td>
<td>
改收 <code>List[Dict]</code>，内部调 <code>_names_in(piece, entries)</code></td>
</tr>
<tr>
<td>
<code>rag.py:1386</code> <code>reindex_chapter_in_state()</code></td>
<td>
传 <code>_character_names(state)</code></td>
<td>
传 <code>_char_entries(state)</code></td>
</tr>
<tr>
<td>
<code>rag.py:1791</code> <code>_reindex_chapters()</code></td>
<td>
传 <code>_character_names(state)</code></td>
<td>
传 <code>_char_entries(state)</code></td>
</tr>
<tr>
<td>
<code>nodes.py:1508</code> <code>_index_approved_chapter()</code></td>
<td>
传 <code>_character_names(state)</code></td>
<td>
传 <code>_char_entries(state)</code></td>
</tr>
<tr>
<td>
<code>rag.py:1270 <code>index_chapter()</code></code>（章节块前缀拼装）</td>
<td>
<code>names = list(character_names or [])</code> → <code>_names_in(piece, entries)</code></td>
<td>
传入的已是 entries，无需改动（调用方换源即可）</td>
</tr>
<tr>
<td>
<code>rag.py:1466 <code>_setting_prefix()</code></code>（设定块身份前缀 +「相关角色」）</td>
<td>
<code>_names_in(raw, char_entries)</code></td>
<td>
换用 <code>_char_entries</code>（设定块也要认别名）</td>
</tr>
<tr>
<td>
<code>rag.py::index_settings()</code> 角色块文本</td>
<td>
<code>f&quot;角色-{name}({role}): 性格=…, 背景=…, 目标=…&quot;</code></td>
<td>
<strong>把别名写进文本</strong>：追加 <code>，别名={别名1、别名2}</code>，否则设定块本身按别名查不到</td>
</tr>
</tbody>
</table></div>
<blockquote>
<p>
⚠ <strong>前缀预算硬约束</strong>：<code>ENRICH_RESERVE = 120</code>（<code>CHUNK_SIZE=500</code> 的不变量①，见 <code>rag.html</code> §5）。
别名<strong>不要</strong>写进章节块前缀 —— 章节正文里本来就有别名，前缀只需输出<strong>规范名</strong>
（<code>_names_in</code> 已经这么做了）。别名只写进<strong>设定块文本</strong>（那条路径没有 120 预算）。
若确需写入，必须实测 <code>CONTENT_BUDGET</code> 是否还够，不能凭感觉加。</p>
</blockquote>
<h3 id="34-读侧子查询构造-你要的那条">3.4 读侧（子查询构造）—— 你要的那条</h3><p>
<strong><code>app/core/rag.py</code> · <code>build_story_queries_with_info()</code></strong></p>
<pre><code class="language-python"># 改造前的基线（第 679 行）：
items.append(f&quot;{c['name']} {c.get('role', '')}&quot;)
# 改为：
items.append(_query_text(entry))
</code></pre>
<blockquote>
<p>
⚠ <strong>有两处</strong>同样的写法，别漏：</p>
<ul>
<li>
<code>rag.py:735</code> — <code>build_story_queries_with_info</code>（写章保底检索）</li>
<li>
<code>rag.py:786</code> — <code>build_setting_queries</code>（世界观/人设阶段）</li>
</ul>
<p>
两处都要改，否则早期阶段（还没有章纲）仍按规范名检索。</p>
</blockquote>
<p>
<strong>出场判定同样要改</strong>（<code>rag.py:765-766</code>）：</p>
<pre><code class="language-python"># 现状：只认规范名
on_stage  = [c for c in chars if str(c[&quot;name&quot;]) in stage_text]
off_stage = [c for c in chars if str(c[&quot;name&quot;]) not in stage_text]
# 改为：认别名，输出规范名
def _is_on_stage(entry, stage_text) -&gt; bool:
    return any(n and n in stage_text for n in _all_names(entry))
</code></pre>
<blockquote>
<p>
为什么这条最要紧：出场角色<strong>排在子查询最前面</strong>。<code>rag.html</code> §8 记录过一个真实 bug——
按数组顺序截断导致「本章真正出场的人被漏掉」。章纲里用外号称呼一个角色却判成
off_stage，等于把本章<strong>最该检索的人</strong>挤到 <code>MAX_SUBQUERIES</code> 之外，
而账目里只会表现为 <code>dropped &gt; 0</code>，看起来像&quot;角色太多&quot;。</p>
</blockquote>
<h3 id="35-显示层已基本正确只需确认一处">3.5 显示层（已基本正确，只需确认一处）</h3><div class="tbl-wrap"><table>
<thead>
<tr>
<th>
位置</th>
<th>
现状</th>
<th>
要改吗</th>
</tr>
</thead>
<tbody>
<tr>
<td>
<code>rag.py::to_citations()</code> character 分支</td>
<td>
<code>label = meta.get(&quot;name&quot;) or meta.get(&quot;title&quot;)</code></td>
<td>
<strong>不用改</strong> —— 设定块入库时 <code>name</code>/<code>title</code> 存的就是规范名</td>
</tr>
<tr>
<td>
<code>rag.py::_format_context()</code></td>
<td>
章节块取 <code>outline_title</code>；设定块取 <code>name</code></td>
<td>
<strong>不用改</strong></td>
</tr>
<tr>
<td>
章节块 metadata</td>
<td>
只有 <code>chapter_id</code>，<strong>没有 character_id</strong></td>
<td>
不改。<strong>章节块无法在检索后归一</strong> —— 这正是必须在<strong>写侧</strong>（3.3）解决的原因</td>
</tr>
</tbody>
</table></div>
<h3 id="36-llm-生成侧让新角色自带别名">3.6 LLM 生成侧（让新角色自带别名）</h3><p>
<strong><code>app/core/nodes.py</code>（人设阶段角色生成 prompt <code>nodes.py:428-434</code>、章纲提名 schema <code>nodes.py:714</code>）</strong>与
<strong>落盘点 <code>nodes.py:861-902</code> 的 <code>_apply_new_characters</code></strong>：</p>
<p>
在角色生成的 JSON schema / 提示里加一个字段，并要求<strong>别名必须来自已有设定集</strong>：</p>
<pre><code>aliases: 该角色在正文中可能出现的其它叫法（外号/尊称/简称）。
必须来自已有设定集线索，**没有就返回空数组**，不要臆造。
</code></pre>
<p>
别名由 <code>_apply_new_characters</code>（<code>nodes.py:897</code>）落进 <code>character_settings</code>；
两条生成 prompt（人设 <code>nodes.py:434</code>、章纲 <code>nodes.py:714</code>）都已要求「没有就返回空数组，不要臆造」。</p>
<blockquote>
<p>
⚠ 既有角色<strong>不会被 LLM 补全别名</strong> —— 那是一次全量改写，等于重排全书检索结果。
老角色的别名由<strong>作者在设定中心手填</strong>。这是刻意的：别名是作者的判断。</p>
</blockquote>
<h3 id="37-前端-设定中心">3.7 前端 · 设定中心</h3><p>
<strong><code>frontend/src/types/index.ts</code>（第 171 行）</strong></p>
<pre><code class="language-ts">export interface Character {
  id: string
  name: string
  role: string
  /** 同一角色的其它叫法：外号 / 尊称 / 简称。检索时等价于规范名。 */
  aliases?: string[]
  tier?: string          // ← 后端补齐（见 3.1）
  ...
}
</code></pre>
<p>
<strong>角色编辑表单</strong>：</p>
<ul>
<li>
新增「别名」标签输入：回车或逗号分隔成 chip，chip 上带 <code>×</code> 可删</li>
<li>
只读态展示为 <code>林晚</code> 后跟灰色小字 <code>（阿晚、林家小姐）</code>（只取前 2 个）</li>
<li>
上限提示 3 个（与 §6 的预算约束一致）</li>
<li>
随 <code>character_settings</code> 的 upsert 一起提交，无需新接口</li>
</ul>
<hr />
<h2 id="4-兼容与迁移">4. 兼容与迁移</h2><ul>
<li>
<strong>老数据零迁移</strong>：<code>aliases</code> 缺失时按 <code>[]</code> 处理（所有消费方都用 <code>c.get(&quot;aliases&quot;) or []</code>）</li>
<li>
<strong>不需要重建索引</strong>：别名只影响<strong>新写入</strong>的块。老块前缀里没有别名 → 查别名仍召不回老块。
这是可接受的（老块本来也不认识别名），但<strong>必须在文档里写清楚</strong>，
否则作者会误以为&quot;填了别名就立刻全局生效&quot;</li>
<li>
若要让老块也认别名：走 <code>reindex(state, scope=&quot;chapters&quot;)</code>。
注意 <code>scope=&quot;documents&quot;</code> 只计数不重嵌（上传文档原文不留存，删了就是永久丢失作者的设定参考，见 <code>rag.py</code>）</li>
</ul>
<hr />
<h2 id="5-测试清单teststest_entity_aliaspy">5. 测试清单（<code>tests/test_entity_alias.py</code>）</h2><div class="tbl-wrap"><table>
<thead>
<tr>
<th>
#</th>
<th>
用例</th>
<th>
锁住的性质</th>
</tr>
</thead>
<tbody>
<tr>
<td>
1</td>
<td>
<code>_all_names</code> 规范名在前、去重、别名顺序稳定</td>
<td>
前缀可复现（幂等覆盖的前提）</td>
</tr>
<tr>
<td>
2</td>
<td>
<code>_match_in(&quot;…阿晚推开门…&quot;, 林晚条目)</code> → 返回 <code>&quot;林晚&quot;</code></td>
<td>
认别名但<strong>输出规范名</strong></td>
</tr>
<tr>
<td>
3</td>
<td>
<code>_names_in</code> 多别名命中时<strong>只输出一次</strong>规范名</td>
<td>
引用卡不会把一个角色显示成两个名字</td>
</tr>
<tr>
<td>
4</td>
<td>
<code>_names_in</code> 超 <code>ENRICH_MAX_NAMES</code> 时按设定表顺序截断</td>
<td>
确定性</td>
</tr>
<tr>
<td>
5</td>
<td>
章纲写「阿晚」→ 该角色进 <code>on_stage</code> 且排最前</td>
<td>
别名不再导致出场角色被挤掉</td>
</tr>
<tr>
<td>
6</td>
<td>
<code>_query_text</code> 别名合并成<strong>一条</strong>，子查询<strong>总数不增加</strong></td>
<td>
不占 <code>MAX_SUBQUERIES</code> 名额</td>
</tr>
<tr>
<td>
7</td>
<td>
<code>MAX_SUBQUERIES=6</code> 满时，别名<strong>不会</strong>把伏笔挤出去</td>
<td>
回归防线（§8 实测过的坑）</td>
</tr>
<tr>
<td>
8</td>
<td>
无 <code>aliases</code> 字段的旧角色 → 空列表，行为与改造前一致</td>
<td>
向后兼容</td>
</tr>
<tr>
<td>
9</td>
<td>
别名含规范名本身 → 去重，不产生 <code>[&quot;林晚&quot;,&quot;林晚&quot;]</code></td>
<td>
幂等</td>
</tr>
<tr>
<td>
10</td>
<td>
<code>index_settings</code> 生成的设定块文本含 <code>别名=</code></td>
<td>
别名可被检索</td>
</tr>
<tr>
<td>
11</td>
<td>
章节块前缀总长仍 ≤ <code>ENRICH_RESERVE</code></td>
<td>
不变量①（<code>rag.html</code> §5）不被破坏</td>
</tr>
<tr>
<td>
12</td>
<td>
端到端：<code>reindex_chapter</code> → <code>search(别名)</code> 能召回该块</td>
<td>
写侧修复真的生效</td>
</tr>
</tbody>
</table></div>
<hr />
<h2 id="6-风险与边界">6. 风险与边界</h2><div class="tbl-wrap"><table>
<thead>
<tr>
<th>
风险</th>
<th>
说明</th>
<th>
缓解</th>
</tr>
</thead>
<tbody>
<tr>
<td>
<strong>别名歧义</strong></td>
<td>
「小姐」这类泛称可能命中多个角色</td>
<td>
别名应是<strong>具体</strong>叫法；<code>_names_in</code> 逐角色判命中，不互斥也没关系（同一块可标多个出场角色）</td>
</tr>
<tr>
<td>
<strong>子串误判</strong></td>
<td>
别名「林」会被「林晚」「林家」都命中</td>
<td>
别名长度 ≥2；<code>_chapter_stage_text</code> 已有同样问题，本次<strong>不扩大范围</strong></td>
</tr>
<tr>
<td>
<strong>别名前缀撑爆预算</strong></td>
<td>
把别名写进章节块前缀会挤占正文</td>
<td>
明确禁止：章节块前缀<strong>只写规范名</strong>（3.3 末）</td>
</tr>
<tr>
<td>
<strong>子查询变长</strong></td>
<td>
单条子查询文本变长 → embedding 输入变长</td>
<td>
<code>_query_text</code> 里截断（建议 ≤3 个别名）</td>
</tr>
<tr>
<td>
<strong>老块不认别名</strong></td>
<td>
填了别名但老章节召不回</td>
<td>
文档写明 + 提供 <code>reindex(scope=&quot;chapters&quot;)</code> 路径</td>
</tr>
<tr>
<td>
<strong>模型臆造外号</strong></td>
<td>
LLM 编造不存在的叫法</td>
<td>
prompt 明确&quot;没有就返回空数组&quot;；臆造的外号<strong>进不了召回</strong>（库里没有），只是白占索引</td>
</tr>
</tbody>
</table></div>
<hr />
<h2 id="7-改动文件汇总">7. 改动文件汇总</h2><div class="tbl-wrap"><table>
<thead>
<tr>
<th>
文件</th>
<th>
改什么</th>
<th>
量级</th>
</tr>
</thead>
<tbody>
<tr>
<td>
<code>app/core/state.py</code></td>
<td>
<code>Character.aliases</code> + 补 <code>tier</code></td>
<td>
2 行</td>
</tr>
<tr>
<td>
<code>app/core/rag.py</code></td>
<td>
<strong>新增</strong> <code>_char_entries</code> / <code>_all_names</code> / <code>_match_in</code> / <code>_query_text</code>；改 <code>_names_in</code>、<code>_character_names</code>、<code>build_story_queries_with_info</code>（735）、<code>build_setting_queries</code>（786）、on_stage 判定（765-766）、<code>index_settings</code> 角色块文本、<strong>3 处</strong> <code>character_names=</code> 调用点（rag.py:1400 / rag.py:1811 / nodes.py:1538）+ 2 处签名（rag.py:1245 index_chapter、rag.py:1304 reindex_chapter）</td>
<td>
中（约 60 行）</td>
</tr>
<tr>
<td>
<code>app/core/nodes.py</code></td>
<td>
<code>nodes.py:1538</code> 调用点；人设阶段角色生成 prompt 加 <code>aliases</code></td>
<td>
小（约 6 行）</td>
</tr>
<tr>
<td>
<code>frontend/src/types/index.ts</code></td>
<td>
<code>aliases?: string[]</code></td>
<td>
1 行</td>
</tr>
<tr>
<td>
<code>frontend/src/.../设定中心</code></td>
<td>
别名标签输入 + 只读展示</td>
<td>
中</td>
</tr>
<tr>
<td>
<code>tests/test_entity_alias.py</code></td>
<td>
22 条回归</td>
<td>
新文件</td>
</tr>
</tbody>
</table></div>
<p>
<strong>后端总量约 70 行</strong>，无新表、无新依赖、无新配置项。</p>
<hr />
<h2 id="8-不做什么及理由">8. 不做什么（及理由）</h2><div class="tbl-wrap"><table>
<thead>
<tr>
<th>
设想</th>
<th>
不做的理由</th>
</tr>
</thead>
<tbody>
<tr>
<td>
独立的「实体抽取 + ID 归一」LLM 管线</td>
<td>
要额外 LLM 调用（延迟 + 成本），且<strong>引入不确定性</strong> —— 破坏 <code>rag.html</code> §8 的&quot;同输入同结果&quot;。而 <code>metadata.character_id</code> <strong>已经存在</strong>（设定块），检索后归一不需要新管线</td>
</tr>
<tr>
<td>
独立 <code>character_aliases</code> 表 / 存 sidecar</td>
<td>
别名不在 checkpoint → 时间旅行回退时不一致（见 §2）</td>
</tr>
<tr>
<td>
别名各自成独立子查询</td>
<td>
实测占名额、挤掉伏笔（见 §1.2）</td>
</tr>
<tr>
<td>
别名写进章节块前缀</td>
<td>
撑爆 <code>ENRICH_RESERVE</code> → 破坏不变量①（见 §3.3 末）</td>
</tr>
<tr>
<td>
老角色由 LLM 自动补别名</td>
<td>
等于重排全书检索结果；别名由作者判断</td>
</tr>
<tr>
<td>
跨项目共享外号词典</td>
<td>
会把 <code>Character</code> 从&quot;本项目的角色&quot;变成&quot;全局词表&quot;，语义混淆；真需要时另做全局表</td>
</tr>
</tbody>
</table></div>
<hr />
<h2 id="9-实现记录已完成">9. 实现记录（已完成）</h2><h3 id="实际落地的函数appcoreragpy">实际落地的函数（<code>app/core/rag.py</code>）</h3><div class="tbl-wrap"><table>
<thead>
<tr>
<th>
函数</th>
<th>
位置</th>
<th>
说明</th>
</tr>
</thead>
<tbody>
<tr>
<td>
<code>MAX_ALIASES_PER_QUERY = 3</code></td>
<td>
检索工具区</td>
<td>
单条子查询最多带 3 个别名</td>
</tr>
<tr>
<td>
<code>_char_entries(state)</code></td>
<td>
同上</td>
<td>
<strong>归一化唯一入口</strong>：展开别名、剔除单字、去重</td>
</tr>
<tr>
<td>
<code>_all_names(entry)</code></td>
<td>
同上</td>
<td>
规范名 + 别名，<strong>规范名必须在最前</strong></td>
</tr>
<tr>
<td>
<code>_match_in(text, entry)</code></td>
<td>
同上</td>
<td>
认别名，<strong>返回规范名</strong></td>
</tr>
<tr>
<td>
<code>_is_on_stage(entry, stage_text)</code></td>
<td>
同上</td>
<td>
出场判定认别名</td>
</tr>
<tr>
<td>
<code>_query_text(entry)</code></td>
<td>
同上</td>
<td>
子查询文本 = 规范名 + 别名(≤3) + 定位</td>
</tr>
</tbody>
</table></div>
<h3 id="与设计稿的三处偏差">与设计稿的三处偏差</h3><ol>
<li>
<strong><code>_character_names()</code> 保留了名字但改了语义</strong> —— 返回值从 <code>List[str]</code> 变成归一化条目
<code>List[Dict]</code>。理由：<code>nodes.py</code> 也在 import 它，与其为改一串 import，不如让名字跟着语义走，
并在 docstring 里写明「新代码请直接用 <code>_char_entries</code>」。</li>
<li>
<strong><code>test_chunking_enrichment.py</code> 有 2 条既有用例需改签名</strong> —— <code>_names_in</code> 从收
<code>List[str]</code> 改成收 entries。已加 <code>_entries()</code> 辅助函数保持原语义，<strong>断言未放宽</strong>。</li>
<li>
<strong><code>_char_entries</code> 多了 <code>raw</code> 字段</strong> —— 归一化只关心「怎么称呼这个角色」，
但 <code>index_settings</code> 还要用原始的 <code>personality / background / appearance</code> 等散文字段。
不带上它，调用方就只能拿到 id/name/role/aliases，字段值会被写成空串。</li>
</ol>
<h3 id="额外做的两件事设计稿未列但发现后必须做">额外做的两件事（设计稿未列，但发现后必须做）</h3><ol>
<li>
<strong><code>_character_block()</code> 带别名</strong> —— <code>prompts.py:189-195</code>（<code>nodes.py:42</code> 只是 re-export）。作者在设定中心填了别名却看不到它
出现在正文上下文里，会以为&quot;这个字段没生效&quot;。现在渲染为
<code>- 林晚（主角，又称阿晚、林家小姐）：性格=…</code></li>
<li>
<strong>设定中心搜索匹配别名</strong> —— <code>SettingCenter.tsx</code>。作者回忆角色时很可能只记得外号
（「阿晚」），可能想不起规范名（「林晚」），搜索漏了这一条等于白填别名。</li>
</ol>
<h3 id="回归测试teststest_entity_aliaspy22-条">回归测试（<code>tests/test_entity_alias.py</code>，22 条）</h3><p>
覆盖设计稿 §5 的 12 条，另加 10 条：单字别名剔除、别名含规范名自身、
<code>build_setting_queries</code> 也带别名、设定块文本含 <code>别名=</code>、前缀预算不变量①、
<code>_char_entries</code> 保留 raw 字段、角色块文本含真实字段值、设定块不超 CHUNK_SIZE、
子查询别名截断、出场 info 输出规范名、章节前缀对别名文本输出规范名。</p>
<p>
其中最关键的一条是端到端写侧验证：</p>
<pre><code>正文只写「阿晚」-&gt; _names_in 命中 -&gt; 前缀写成「出场：林晚」
</code></pre>
<p>
旧实现在这一步会返回空列表，于是该块在角色查询下<strong>永远召不回</strong>。</p>
<h3 id="未做的事按设计稿-8">未做的事（按设计稿 §8）</h3><ul>
<li>
不做 LLM 实体抽取管线（<code>metadata.character_id</code> 已存在）</li>
<li>
不建独立表 / 不存 sidecar（别名必须随 checkpoint 走）</li>
<li>
别名不写进章节块前缀（<code>ENRICH_RESERVE=120</code> 是不变量①）</li>
<li>
不给老角色自动补别名（等于重排全书检索结果）</li>
</ul>
<h3 id="遗留事项">遗留事项</h3><ul>
<li>
<strong>老章节块不认别名</strong>：别名只影响新写入的块。要让老章节也认，
跑 <code>reindex(state, scope=&quot;chapters&quot;)</code>。<strong>这一条必须写进用户文档</strong>——
否则作者会以为&quot;填了别名就立刻全局生效&quot;。</li>
<li>
前端只改了设定中心；引用卡 / <code>_format_context</code> 经核对<strong>无需改动</strong>
（设定块入库时 <code>name</code> 存的就是规范名）。</li>
</ul>
</article>
</div>
