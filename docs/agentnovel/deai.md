---
title: 去 AI 味提示词工程 · 详细设计
description: 去 AI 味提示词工程详细设计：规则库 deai_rules、prompt 组装 deai_prompts、确定性检测 deai_lint 与机械兜底 apply_mechanical_fixes。
outline: [2, 3]
---
<div class="an-doc">
<header class="hero">
  <div class="wrap">
    <div class="eyebrow">De-AI Prompt Engineering · Design</div>
    <h1 id="去-ai-味提示词工程-详细设计">去 AI 味提示词工程 · 详细设计</h1>
    <blockquote>
<p>
状态：已实现（v1.5 · 增量）
相关代码：<code>novelcraft/app/core/deai_rules.py</code>、<code>deai_prompts.py</code>、<code>deai_lint.py</code>
相关测试：<code>tests/test_deai_rules.py</code>、<code>test_deai_lint.py</code>、<code>test_deai_prompts.py</code>、<code>test_deai_wiring.py</code>
上游参考：<code>OUBIGFA/De-AI-Prompt-Enhancer-Writer-Booster-SKILL</code>（去 AI 味提示词-作家增强）
本项目上一版「成稿清洗」（去重 + 剥元叙述）见 <code>nodes.clean_chapter_body</code>，本文档只讲新增部分。</p>
</blockquote>
  </div>
</header>
<article class="md wrap">
<h2 id="1-问题">1. 问题</h2><p>
第一章成稿实测下来，模型产出的中文有两个层次的缺陷：</p>
<ul>
<li>
<strong>表层</strong>：模型爱写 <code>### 未完待续</code>、<code>这是本章的转折</code>、正文里混 <code>**加粗**</code>、<code>作为AI</code> 泄漏。
这类缺陷<strong>确定、可枚举</strong>，上一版 <code>clean_chapter_body</code> 已经处理了一部分。</li>
<li>
<strong>深层</strong>：主题被叙述者说破、因果链一条线到底、每段首句连读就是一份干净摘要、
段落等厚、结尾靠主角「想通了」收束、关键词成簇（<code>不是A而是B</code>、<code>值得注意的是</code>）。</li>
</ul>
<p>
关键结论来自上游 SKILL 的实测：<strong>AI 小说的识别准确率约 93% 来自叙事结构特征，
把词汇句式全部改掉之后识别率几乎不降</strong>。也就是说，一篇小说如果主题被说破、
因果链太整齐、结尾靠想通了收束，改多少词都还是 AI 味。</p>
<p>
这个结论直接否掉了「写一条更好的 prompt」这条路：</p>
<ul>
<li>
prompt 里塞 40 条规则，模型只会照做其中最容易的 5 条（删词比改结构容易得多）；</li>
<li>
结构缺陷事后补最贵，模型不会自查；</li>
<li>
效果不可复现、不可回归、不可解释。</li>
</ul>
<p>
所以本设计做成了<strong>三道防线 + 一份可被程序消费的规则库</strong>。</p>
<hr />
<h2 id="2-总体结构">2. 总体结构</h2><pre><code>                    ┌─────────────────────────────────────────┐
   ①  prompt 引导   │ app/core/deai_prompts.deai_core_block    │  → 写作/润色/修订/段落重写
                    │  核心块，字符预算内塞入最高收益规则      │
                    └────────────────────┬────────────────────┘
                                         │ 生成正文
                                         ▼
                     ┌─────────────────────────────────────────┐
    ②  机械兜底      │ app/core/deai_lint.apply_mechanical_fixes│  → 落库前
                     │  只做纯删除/直接替换，先过密度闸门       │
                     └────────────────────┬────────────────────┘
                                          │
                                          ▼
                     ┌─────────────────────────────────────────┐
    ③  确定性验收    │ app/core/deai_lint.lint_text            │  → 日志 + 审核线索
                     │  正则（词面）+ 结构指标（版面）          │
                     └────────────────────┬────────────────────┘
                                         │ format_digest 回灌
                                         ▼
                    ┌─────────────────────────────────────────┐
                    │ reviewing_node → deai_review_block       │  → ReviewIssue(kind=&quot;style&quot;)
                    └─────────────────────────────────────────┘
   规则库（数据）：app/core/deai_rules.RULES —— 五层 72 条，被上面三处同时消费
</code></pre>
<p>
防线顺序有讲究：<strong>引导降低发生概率 → 兜底兜住必然出错的部分 → 验收量化残余，
并把残余喂回审核</strong>。只有第 ① 道是「模型发挥」，第 ②③ 道完全确定、可进 CI。</p>
<hr />
<h2 id="3-规则库deai_rulespy">3. 规则库：<code>deai_rules.py</code></h2><h3 id="31-五层结构">3.1 五层结构</h3><p>
修补顺序固定为 <strong>叙事 → 篇章 → 句式 → 词表 → 网文</strong>，深层先修。
浅层改多少都盖不住深层，这是上游的核心实测结论。</p>
<div class="tbl-wrap"><table>
<thead>
<tr>
<th>
层</th>
<th>
代号</th>
<th>
条数</th>
<th>
抓什么</th>
<th>
能否正则检测</th>
</tr>
</thead>
<tbody>
<tr>
<td>
叙事层</td>
<td>
N1–N10</td>
<td>
9</td>
<td>
主题被说破、因果链太整齐、靠「想通了」收尾、外貌出场、建立镜头开头</td>
<td>
✗ 结构指标</td>
</tr>
<tr>
<td>
篇章层</td>
<td>
D1–D10</td>
<td>
10</td>
<td>
大纲测试、线性问题序列、中段塌陷、位置指纹/等厚、段尾收束、三项列举、指示性定位壳、正文残留 markdown</td>
<td>
部分</td>
</tr>
<tr>
<td>
句式层</td>
<td>
S1–S28</td>
<td>
28</td>
<td>
二分对照壳、步骤承接、关联词对堆叠、戏剧化揭露、极值判断、拟人化否定、破折号机械使用</td>
<td>
✓</td>
</tr>
<tr>
<td>
词表层</td>
<td>
V1–V17</td>
<td>
17</td>
<td>
填充过渡短语、伪学术腔、伪口语化引导语、AI 身份泄漏、标点不统一、<strong>该放回来的人类语域</strong></td>
<td>
✓</td>
</tr>
<tr>
<td>
网文层</td>
<td>
F1–F8</td>
<td>
8</td>
<td>
对白空转、系统播报、章节末预告、排比成瘾、说教段、感官锚点缺失</td>
<td>
部分</td>
</tr>
</tbody>
</table></div>
<p>
相对上游通用版的裁剪与增量：</p>
<ul>
<li>
<strong>删掉</strong>翻译护栏与评论/科普/说明文专条目（那些层在小说里不产出正文）。</li>
<li>
<strong>降级</strong>政论/媒体研究术语（V8）与「摆数据」类条目：它们对应的是模型切回
议论文腔的时刻，在小说里表现为说理段/吐槽段漏进来，是<strong>低频高损</strong>，按密度判。</li>
<li>
<strong>新增 F 层</strong>：上游是面向「中文文本」的通用版，没有覆盖网文读者最敏感的几处 ——
系统机械播报、章节末预告与总结、对白只剩信息不剩人、排比成瘾、金句化、感官锚点缺失。
这一层是本项目自己的增量。</li>
<li>
<strong>保留 V17（该放回来的人类语域）</strong>：去 AI 味需要双向操作，删词之外还要补回人类语域。对齐训练系统性压低了
一批人类日常表达，删光黑名单词后中文仍然读起来「太干净、太书面、太均匀」——
那是另一种指纹。</li>
</ul>
<h3 id="32-阈值语义per_kilo">3.2 阈值语义：<code>per_kilo</code></h3><p>
每条规则有一个 <code>per_kilo</code>：<strong>每千字的免费次数</strong>。</p>
<pre><code class="language-python">allowed = max(per_kilo * len(text) / 1000, 1.0)   # 免费额度下限 1 次
命中数 &gt; allowed  →  算问题
excess = 命中数 - allowed  →  参与扣分
</code></pre>
<p>
那个 <code>max(..., 1.0)</code> 是有意加的：<strong>保证「单次出现且读感自然的不算问题」对任意长度的文本都成立</strong>。
否则 30 字段落里出现一次「总的来说」也会被判成成簇（额度只有 0.03）。</p>
<p>
<code>per_kilo = 0.0</code> 表示「出现即问题」（泄漏、加粗、emoji、鸡汤收尾）。</p>
<p>
这是把上游「<strong>阈值是识别强度，不是删除配额</strong>」落成代码。推论很直接：
偶尔一个路标词是人类的，每段开头都有一个才是模板。把所有痕迹都反着来
（零路标、零第二人称、每段长短都不同）本身是另一种指纹。</p>
<h3 id="33-误判白名单">3.3 误判白名单</h3><p>
<code>quote_aware=True</code> 的规则会跳过引号内的内容（<code>mask_quotes</code>）。原因：
「她说『本质上这是个闭环』」里，AI 腔是<strong>人物在装腔</strong>，是人类写法；
同样的词出现在叙述层才是痕迹。这类规则共 8 条（S13/S15/V1/V5/V6/V8/F2/F6）。</p>
<hr />
<h2 id="4-prompt-组装deai_promptspy">4. prompt 组装：<code>deai_prompts.py</code></h2><h3 id="41-为什么必须分块">4.1 为什么必须分块</h3><p>
上游 SKILL 有 1100+ 行、约 40KB。全量注入有两个后果：</p>
<ol>
<li>
<strong>上下文预算被吃光</strong>。本项目已经吃过这个亏：世界观单字段注入 700 字
（<code>MAX_WORLD_FIELD_CHARS</code>）就曾把章纲和前情挤出去。</li>
<li>
<strong>规则一多，模型只照做最容易的几条</strong>，剩下 40 条形同没写。</li>
</ol>
<p>
所以这里等价实现上游自己的「读取策略」（默认只读主文件，参考文件按层读）：</p>
<div class="tbl-wrap"><table>
<thead>
<tr>
<th>
块</th>
<th>
用在哪</th>
<th>
形态</th>
</tr>
</thead>
<tbody>
<tr>
<td>
<code>deai_core_block</code></td>
<td>
写作 / 润色 / 正文修订 / 段落重写</td>
<td>
规则行，<strong>有预算</strong></td>
</tr>
<tr>
<td>
<code>deai_outline_block</code></td>
<td>
卷纲 / 章纲</td>
<td>
梗概写法约束</td>
</tr>
<tr>
<td>
<code>deai_polish_block</code></td>
<td>
润色目标清单</td>
<td>
追加为第 5 条</td>
</tr>
<tr>
<td>
<code>deai_review_block</code></td>
<td>
审核阶段</td>
<td>
五层检查清单 + <code>kind=&quot;style&quot;</code></td>
</tr>
<tr>
<td>
<code>deai_rewrite_block</code></td>
<td>
作者直接要求「去 AI 味」的入口（<b>待接</b>）</td>
<td>
两阶段精修指令 —— 已实现，但<b>当前没有任何调用点</b>，只在 <code>deai_prompts.py</code> 与其测试里出现</td>
</tr>
<tr>
<td>
<code>PROSE_OUTPUT_CONTRACT</code></td>
<td>
所有输出正文的 prompt</td>
<td>
输出契约</td>
</tr>
</tbody>
</table></div>
<p>
完整规则库仍然全部可达：核心块只放 <code>core=True</code> 的 16 条，其余通过
<code>deai_review_block</code> 交给审核模型逐层过，再通过 <code>lint_text</code> 确定性验收。</p>
<h3 id="42-核心块的预算与截断">4.2 核心块的预算与截断</h3><p>
<code>settings.deai_prompt_chars</code>（默认 1400）。标题头与校准段是<strong>必发</strong>的 ——
校准段（「阈值是人类区间不是配额」）管着所有规则，砍掉它等于让模型把每条禁令都执行过头。</p>
<p>
规则行按 <code>severity</code> → <code>层序</code> 排序后逐行塞入，放不下的记入 <code>dropped</code>，
并在块尾<strong>显式列出</strong>：</p>
<blockquote>
<p>
（本块受字符预算所限，以下规则本次不展开，但仍然有效：S5 戏剧化揭露、S4 关联句式堆叠、V10 填充短语与空转过渡。审核与精修阶段会逐条检查。）</p>
</blockquote>
<p>
静默截断会让模型以为规则就这么多，反而<strong>安全地少做几件事</strong>；显式告知至少让它知道
还有未展开的约束。深层规则排在前面，所以截断丢的是浅层规则 —— 而浅层正是
上游实测「改了也不影响识别率」的那部分。</p>
<h3 id="43-题材定向">4.3 题材定向</h3><p>
不同体裁的 AI 味长在不同地方。<code>FOCUS_RULES</code> 从 <code>genre</code> / <code>theme</code> / <code>style</code> 扫关键词，
命中就给一条定向提示（可同时命中多条，按命中顺序去重）。例如：</p>
<ul>
<li>
悬疑/惊悚 → 「线索要让读者自己连，不要在段尾替读者总结『这说明凶手是 X』」</li>
<li>
无限流/科幻 → 「世界观术语必须落在一件具体物上，不要用伪学术腔包装」</li>
<li>
热血爽文 → 「不要让旁白提前播报『这一战他将如何如何』；先给结果，再让读者自己算账」</li>
</ul>
<p>
定向提示<strong>不进预算统计之外</strong>（它计入预算，低预算时会挤掉规则行），但它只出现一段。</p>
<h3 id="44-注入位置">4.4 注入位置</h3><div class="tbl-wrap"><table>
<thead>
<tr>
<th>
prompt</th>
<th>
注入位置</th>
<th>
理由</th>
</tr>
</thead>
<tbody>
<tr>
<td>
<code>writing_node</code></td>
<td>
SystemMessage 末尾</td>
<td>
系统级约束；放在末尾是因为 recency 效应最强</td>
</tr>
<tr>
<td>
<code>build_chapter_revise_messages</code></td>
<td>
硬要求<strong>之后</strong></td>
<td>
先给保真约束再给风格目标。反过来模型会为迎合风格去改不该动的段落</td>
</tr>
<tr>
<td>
<code>polishing_node</code></td>
<td>
目标清单第 5 条</td>
<td>
追加到末尾，不做插入，保持 1–4 条的语义</td>
</tr>
<tr>
<td>
<code>rewrite_paragraph</code></td>
<td>
SystemMessage</td>
<td>
单段重写是最容易把整章文风带偏的入口：一段被写成「更文学」的样本会被相邻段落续写模仿</td>
</tr>
<tr>
<td>
<code>reviewing_node</code></td>
<td>
HumanMessage 末尾</td>
<td>
审核指令与被审正文在同一轮里，注意力更集中</td>
</tr>
</tbody>
</table></div>
<p>
核心块一律经 <code>nodes._deai_block(state)</code> 生成，<strong>不并入 <code>_project_context</code></strong>。
<code>_project_context</code> 那一行是「文风要求」，而本模块只做<strong>约束</strong>，不引入新文风；
混进去会被模型当成「作者要求更文学」，正好是反效果。</p>
<hr />
<h2 id="5-确定性检测deai_lintlint_text">5. 确定性检测：<code>deai_lint.lint_text</code></h2><h3 id="51-词法层">5.1 词法层</h3><p>
按规则逐条正则计数，超过 <code>per_kilo × 千字</code> 才算命中。<code>quote_aware</code> 规则跑在
掩码文本上。证据片段（≤ 20 字）直接从命中处裁剪，保证「没有引文的不算」。</p>
<h3 id="52-结构层去-ai-味的主战场">5.2 结构层（去 AI 味的主战场）</h3><p>
这层是本项目增量最大、也最难用 prompt 解决的部分 —— 模型自己也算不准
「这一章的段落是否等厚」「中段是不是塌了」。</p>
<div class="tbl-wrap"><table>
<thead>
<tr>
<th>
检查</th>
<th>
指标</th>
<th>
判定</th>
</tr>
</thead>
<tbody>
<tr>
<td>
D4 等厚</td>
<td>
段落长度 <code>pstdev / mean</code></td>
<td>
<code>&lt; 0.35</code> 且段数 ≥ 8</td>
</tr>
<tr>
<td>
D5 碎段</td>
<td>
短段（≤28 字）占比 + 短段长度离散度</td>
<td>
段数 ≥ 10 <strong>且</strong> 占比 ≥ 0.45 <strong>且</strong> 短段 ≥ 5 <strong>且</strong> 短段 CV <code>&lt; 0.35</code></td>
</tr>
<tr>
<td>
D5 段尾收束</td>
<td>
以抽象名词（一切/命运/答案/未来/真相…）收尾的段落占比</td>
<td>
≥ 0.40</td>
</tr>
<tr>
<td>
D1 大纲测试</td>
<td>
首句即论点的段落占比（<code>这/那/它…是/意味着/就是</code>）</td>
<td>
≥ 0.55</td>
</tr>
<tr>
<td>
D3 中段塌陷</td>
<td>
(a) 最长段落在全文首/尾 <strong>15%</strong>，且它 ≥ 平均段长 × 1.3；(b) 全章 CV ≥ 0.10 <strong>且</strong> 中段长度 CV &lt; 全章 CV × 0.35</td>
<td>
任一成立</td>
</tr>
<tr>
<td>
N6 结尾抒情</td>
<td>
末尾 <code>max(80 字, 1/7 正文)</code> 的窗口内出现「想通了/释然/和解」</td>
<td>
命中即算</td>
</tr>
<tr>
<td>
N8 建立镜头</td>
<td>
前 140 字里时间标记与地点标记<strong>相隔 ≤ 8 字</strong>（并排陈述才算建立镜头；相距更远是叙述）</td>
<td>
命中即算</td>
</tr>
<tr>
<td>
N7 外貌开场</td>
<td>
前两段外貌/衣着词 ≥ 2</td>
<td>
命中即算</td>
</tr>
<tr>
<td>
F1 对白空转</td>
<td>
应答式对白（「好」「嗯」「我明白了」）占对白行比</td>
<td>
≥ 0.35 且对白 ≥ 5 行</td>
</tr>
<tr>
<td>
F5 排比成瘾</td>
<td>
句内 ≥3 个长度相近（max/min ≤ 1.6）的逗号分句的句子占比</td>
<td>
≥ 3 句且 ≥ 8%</td>
</tr>
<tr>
<td>
V9 同义循环</td>
<td>
提升/增强/优化/改善… 家族中出现 ≥ 4 个不同成员</td>
<td>
命中即算</td>
</tr>
<tr>
<td>
F7 感官锚点</td>
<td>
触感/声音/气味标记密度（多字词全权、单字半权）</td>
<td>
<code>&lt; 8 / 千字</code></td>
</tr>
</tbody>
</table></div>
<p>
三个判定值得单独说明，它们都是被误报逼出来的：</p>
<ul>
<li>
<strong>D5 碎段必须加「长度整齐」这一半</strong>。网文本来就有大量一句成段的移动端节奏
（<code>&quot;一。&quot;</code>、<code>&quot;他没进去。&quot;</code>），只看占比会把正常节奏判成碎段。真正的碎段是
<strong>又碎又整齐</strong> —— 观点句被机器切成同样大小的薄片。</li>
<li>
<strong>D3 的信号 (b) 需要 <code>whole_cv ≥ 0.10</code></strong>。全章本来就等厚时 <code>mid_cv ≈ 0</code> 是必然结果，
那种情况该归 D4，两条规则不该重复扣同一件事的分。</li>
<li>
<strong>F5 不能用正则</strong>。<code>A，B，C。</code> 在正常中文里俯拾皆是（&quot;灯没点，只有后厨那口锅
还冒着白气，噗噗地响&quot;），正则版 F5 一定误报。真正要量的是<strong>三个分句的长度比</strong>。</li>
</ul>
<h3 id="53-评分">5.3 评分</h3><pre><code>ratio   = 命中数 / max(允许额度, 1.0)
penalty = 严重度权重 × 2.5 × min(ratio, 6)      # 单条封顶
score   = clamp(100 - Σ penalty, 0, 100)
</code></pre>
<p>
之所以按<strong>密度倍数</strong>算，是因为短文本必须和长文本一样被严格判：
125 字的样章出现 3 处「终于明白」是每千字 24 处，按条数算只扣 3 分，按密度算直接封顶。</p>
<p>
实测标定：</p>
<div class="tbl-wrap"><table>
<thead>
<tr>
<th>
样章</th>
<th>
得分</th>
<th>
等级</th>
</tr>
</thead>
<tbody>
<tr>
<td>
刻意 AI 腔（等厚 + 路标词成簇 + 结尾抒情，234 字）</td>
<td>
66</td>
<td>
轻度<br><small>命中 S15 / N1 / N6 / D1 / F7</small></td>
</tr>
<tr>
<td>
刻意人写腔（长短参差 + 对白潜台词 + 具体感官）</td>
<td>
100</td>
<td>
自然</td>
</tr>
<tr>
<td>
125 字 AI 腔短样章</td>
<td>
67</td>
<td>
轻度</td>
</tr>
</tbody>
</table></div>
<p>
等级分档：<code>≥80 自然</code> / <code>≥60 轻度</code> / <code>≥40 中度</code> / <code>&lt;40 重度</code>。</p>
<h3 id="54-报告用途">5.4 报告用途</h3><ul>
<li>
<strong>日志</strong>：低于 <code>deai_warn_score_below</code>（默认 60）打 WARN。去 AI 味是渐进的，
一次生成不干净很正常，连续多章都很脏才说明上游 prompt 或模型出了问题。</li>
<li>
<strong>审核线索</strong>：<code>format_digest</code> 只给编号 + 计数 + 一处引文，<strong>不给修法</strong>。
让审核模型自己判断，免得它照抄修法表变成机械替换 —— 那正是「换词逃逸」的来源。</li>
<li>
<strong>不改正文</strong>：需要改结构的只有 LLM 能改，而且会伤到内容。</li>
</ul>
<hr />
<h2 id="6-机械兜底apply_mechanical_fixes">6. 机械兜底：<code>apply_mechanical_fixes</code></h2><h3 id="61-硬约束">6.1 硬约束</h3><p>
<strong>只做纯删除或可直接替换的修补</strong>。任何需要改写语序的都不在这里做 ——
改错一句就是毁掉一段正文，收益不抵风险。那是 LLM 的活（S15「不是A而是B」
必须改语序，机械层只负责把它标出来）。</p>
<h3 id="62-密度闸门">6.2 密度闸门</h3><p>
每条修复带 <code>min_per_kilo</code>：</p>
<ul>
<li>
<code>0.0</code>（出现就是错）：AI 身份泄漏、<code>以下是正文</code> 类引导语、markdown 加粗与竖排条目、
emoji、标点统一、章节末预告。</li>
<li>
<code>0.5–1.0</code>（成簇才算）：填充过渡短语、句尾虚假深度补语、空挂程度副词。</li>
</ul>
<p>
密度闸门是「只删成簇的」这件事唯一可靠的实现方式。</p>
<h3 id="63-已知的刻意不修">6.3 已知的刻意不修</h3><ul>
<li>
<strong>不剥 markdown 小标题</strong>（<code>### 一、旧站</code>）：本项目的章节正文支持分节小标题，
那是作者主动分节的设备（见 <code>test_chapter_body_clean.py::test_keeps_normal_section_headings</code>），
与模型泄漏无关。要剥的是模型爱加的<strong>强调</strong>与竖排条目。</li>
<li>
<strong>不动对白内容</strong>：<code>quote_aware</code> 的修复跑在掩码上。</li>
<li>
<strong>回填不按位 zip</strong>：早期实现用逐字符 zip 把掩码结果贴回原文，
而 <code>sub</code> 会缩短字符串 —— 尾部会被整段吞掉。现在按匹配区间重建，
<code>tests/test_deai_lint.py::test_does_not_truncate_the_tail</code> 守着这条。</li>
</ul>
<hr />
<h2 id="7-与既有清洗的分工">7. 与既有清洗的分工</h2><div class="tbl-wrap"><table>
<thead>
<tr>
<th>
</th>
<th>
<code>clean_chapter_body</code></th>
<th>
<code>deai_polish_body</code></th>
</tr>
</thead>
<tbody>
<tr>
<td>
判据</td>
<td>
完全确定（元叙述标题、整段逐字重复）</td>
<td>
含风格判断，阈值随规则库演化</td>
</tr>
<tr>
<td>
改动</td>
<td>
删除</td>
<td>
纯删除 / 直接替换</td>
</tr>
<tr>
<td>
输出</td>
<td>
清洗后文本 + 说明</td>
<td>
修复后文本 + 说明（含评分）</td>
</tr>
<tr>
<td>
测试</td>
<td>
逐字断言</td>
<td>
性质断言</td>
</tr>
</tbody>
</table></div>
<p>
<strong>必须分开</strong>。混在一起会让 <code>clean_chapter_body</code> 的逐字回归断言随规则库漂移 ——
作者改一条正则，就可能打红一个与风格无关的测试。</p>
<p>
调用点（三处，全部落库前）：</p>
<div class="tbl-wrap"><table>
<thead>
<tr>
<th>
调用点</th>
<th>
位置</th>
</tr>
</thead>
<tbody>
<tr>
<td>
<code>writing_node</code></td>
<td>
<code>nodes.py</code> 正文生成后</td>
</tr>
<tr>
<td>
<code>polishing_node</code></td>
<td>
润色候选后</td>
</tr>
<tr>
<td>
<code>POST /revise-chapter</code></td>
<td>
<code>routers/creation.py</code> 修订稿后</td>
</tr>
<tr>
<td>
<code>POST /chapters/{chapter_id}/paragraph/{i}/rewrite</code></td>
<td>
<code>routers/chapters.py</code> 单段重写后（跨段结构指标需要看全章）</td>
</tr>
</tbody>
</table></div>
<hr />
<h2 id="8-配置">8. 配置</h2><pre><code class="language-dotenv">DEAI_ENABLED=true              # 总闸；关掉后模型完全不知道有这回事
DEAI_PROMPT_CHARS=1400         # 核心块字符预算
DEAI_MECHANICAL_FIX=true       # 落库前机械兜底
DEAI_LINT_REVIEW=true          # 审核阶段带检测线索
DEAI_LINT_MIN_SEVERITY=low     # 检测报告最低严重度
DEAI_WARN_SCORE_BELOW=60       # 低于此分打 WARN
</code></pre>
<p>
<code>DEAI_ENABLED=false</code> 时：prompt 无注入、机械修复与检测都不跑、评分退化为 100
（所有 <code>deai_*</code> 块返回空串，post-processing 直接返回原值）。
这是完整的降级路径，不留半开半关的状态——那种状态最难排查。</p>
<hr />
<h2 id="9-已知限制">9. 已知限制</h2><ol>
<li>
<strong>结构缺陷必须靠模型改，程序只能算出来</strong>。<code>lint_text</code> 报 D3/D4 时，
要真修得让 LLM 重写受影响的那一段（<code>deai_rewrite_block</code> 已备好，但当前 wiring 还没接上）。
现在只把线索送到审核，人工决定是否采用。</li>
<li>
<strong>F7 感官锚点阈值是单章标定</strong>。短章（&lt; 500 字）的密度波动大，
可能偏松；长篇连载的单章之间不可比。</li>
<li>
<strong>D1 大纲测试用的是「首句即论点」代理指标</strong>，不等于上游定义的大纲测试
（把首句连读看是否成一份干净摘要）。代理指标会漏掉「首句是事实、
但连读仍平顺」的情况。</li>
<li>
<strong>检测器不认识项目自己的设定术语</strong>。若书名/专有名词恰好落在某条规则的
正则里（<code>per_kilo=0</code> 的条目尤其危险），会误报。当前靠 <code>quote_aware</code> 与
密度闸门缓解，没有做项目级词典 —— 那是下一步（见 §10）。</li>
<li>
<strong><code>deai_prompt_chars</code> 默认 1400 是按 DeepSeek-V3.2 标定的</strong>。
换模型时需要重标：规则越长，模型对长 system prompt 的服从度越低。</li>
</ol>
<hr />
<h2 id="10-后续可做">10. 后续可做</h2><ul>
<li>
<strong>项目级术语白名单</strong>：把 <code>world_setting</code> / 角色名喂进检测器，避免专有名词误报。</li>
<li>
<strong>跨章一致性检测</strong>：同一角色/物件在多章里的描写用词是否开始模板化
（「他从X到Y」重复出现），这是单章检测看不到的。</li>
<li>
<strong>检测结论回流生成</strong>：把上一章的 <code>lint_text</code> 结果写进下一章的 prompt，
形成「生成 → 检测 → 定向修正」的闭环，单轮修补是不够的。</li>
<li>
<strong>规则库版本化</strong>：规则集改动需要人工评测（同一批样章跑新旧两版对比），
目前没有回归语料。建议维护一组 10–20 段「已知 AI 腔 / 已知人写」的固定样章，
作为规则库改动的守门基准。</li>
</ul>
</article>
</div>
