---
title: 人在回路（Human-in-the-Loop）详细设计
description: 人在回路（HITL）详细设计 v1.5：后端创作流程与前端工作台的挂起、审批与恢复机制（阶段确认门禁）。
outline: [2, 3]
---
<div class="an-doc">
<header class="hero">
  <div class="wrap">
    <div class="eyebrow">Human-in-the-Loop · Design</div>
    <h1 id="人在回路human-in-the-loop详细设计">人在回路（Human-in-the-Loop）详细设计</h1>
    <blockquote>
<p>
<strong>适用范围</strong>：<code>novelcraft/</code> 后端创作流程 + <code>frontend/</code> 工作台交互
<strong>版本</strong>：v1.5（阶段确认门禁）
<strong>配套</strong>：<code>docs/小说Agent需求文档_v1.4.md</code>、<code>docs/变更记录/</code></p>
</blockquote>
  </div>
</header>
<article class="md wrap">
<h2 id="目录">目录</h2><ul>
<li>
<a href="#1-%E8%AE%BE%E8%AE%A1%E7%9B%AE%E6%A0%87">1. 设计目标</a></li>
<li>
<a href="#2-%E5%BA%95%E5%B1%82%E6%9C%BA%E5%88%B6">2. 底层机制</a></li>
<li>
<a href="#3-%E4%B8%89%E4%B8%AA%E6%8C%82%E8%B5%B7%E7%82%B9">3. 三个挂起点</a></li>
<li>
<a href="#4-%E7%8A%B6%E6%80%81%E6%9C%BA%E4%B8%8E%E8%B7%AF%E7%94%B1">4. 状态机与路由</a></li>
<li>
<a href="#5-%E5%AE%8C%E6%95%B4%E6%97%B6%E5%BA%8F">5. 完整时序</a></li>
<li>
<a href="#6-%E4%BA%A4%E4%BA%92%E5%A5%91%E7%BA%A6">6. 交互契约</a></li>
<li>
<a href="#7-%E6%97%81%E8%B7%AF%E8%AE%A8%E8%AE%BA%E9%97%A8%E7%A6%81%E7%9A%84%E5%A4%9A%E8%BD%AE%E5%AF%B9%E8%AF%9D">7. 旁路讨论</a></li>
<li>
<a href="#8-%E4%BD%8E%E6%88%90%E6%9C%AC%E4%BF%AE%E6%94%B9%E9%80%9A%E9%81%93">8. 低成本修改通道</a></li>
<li>
<a href="#9-%E6%8C%81%E4%B9%85%E5%8C%96%E5%B9%B6%E5%8F%91%E4%B8%8E%E9%94%99%E8%AF%AF%E6%81%A2%E5%A4%8D">9. 持久化并发与错误恢复</a></li>
<li>
<a href="#10-%E5%85%B3%E9%94%AE%E8%AE%BE%E8%AE%A1%E5%86%B3%E7%AD%96%E8%AE%B0%E5%BD%95">10. 关键设计决策记录</a></li>
<li>
<a href="#11-%E5%B7%B2%E7%9F%A5%E8%BE%B9%E7%95%8C">11. 已知边界</a></li>
</ul>
<hr />
<h2 id="1-设计目标">1. 设计目标</h2><p>
把「AI 生成 → 作者被动接受」改成「AI 生成 → 作者决定是否放行」。具体目标：</p>
<div class="tbl-wrap"><table>
<thead>
<tr>
<th>
目标</th>
<th>
手段</th>
</tr>
</thead>
<tbody>
<tr>
<td>
生成前先对齐，避免生成后再推翻</td>
<td>
阶段确认门禁（<code>kind=confirm</code>）</td>
</tr>
<tr>
<td>
每个阶段产出都能被否决</td>
<td>
人工审核（<code>kind=review</code>）</td>
</tr>
<tr>
<td>
生成中能追问</td>
<td>
提问 interrupt（<code>kind=question</code>）</td>
</tr>
<tr>
<td>
讨论不污染创作上下文</td>
<td>
旁路 sidecar（不写 checkpoint、不进 State）</td>
</tr>
<tr>
<td>
挂起时长不受限（分钟 ~ 数天）</td>
<td>
checkpoint 落 TiDB</td>
</tr>
<tr>
<td>
每个挂起点可回溯</td>
<td>
每次 interrupt 都是一个 checkpoint</td>
</tr>
</tbody>
</table></div>
<hr />
<h2 id="2-底层机制">2. 底层机制</h2><h3 id="21-interrupt-commandresume-语义">2.1 <code>interrupt()</code> / <code>Command(resume=...)</code> 语义</h3><p>
<strong>挂起</strong>：节点内调用 <code>interrupt(payload)</code>，抛 LangGraph 内部异常 → 图在当前步骤前保存 checkpoint 到 TiDB → 停止。此时 <code>state.next == [&quot;gate&quot;]</code> 或 <code>[&quot;human_review&quot;]</code>。</p>
<p>
<strong>恢复</strong>：API 用 <code>Command(resume=decision)</code> 重新驱动图。</p>
<blockquote>
<p>
<strong>核心语义（最易误解的一点）</strong>：恢复时节点函数<strong>从头重新执行一遍</strong>，直到再次运行到 <code>interrupt()</code> 那一行——第二次调用直接返回注入的 <code>decision</code>，不再抛异常。</p>
</blockquote>
<div class="srcline">novelcraft/app/core/nodes.py:1911-1917</div><pre><code>    decision = interrupt({
        &quot;kind&quot;: &quot;confirm&quot;,
        &quot;stage&quot;: stage,
        &quot;round&quot;: round_no,
        &quot;discussion_id&quot;: discussion_id,
        &quot;brief&quot;: brief,
    })
</code></pre>
<p>
第一次执行：读 State → 重建 brief → 抛异常挂起，<strong>局部变量全部丢失</strong>。
resume 后：重新读 State → 重新从 sidecar 拉讨论日志 → 重建 brief → 这一行直接返回决策。</p>
<h3 id="22-重放语义带来的约束">2.2 重放语义带来的约束</h3><p>
因为节点是重放的，<strong>跨轮状态只能存在两个地方</strong>：State 字段，或 resume 回传的数据。</p>
<div class="srcline">novelcraft/app/core/nodes.py:1900-1927</div><pre><code>    round_no = int(gate.get(&quot;round&quot;, 0)) + 1          # 轮次只能从 State 推算
    discussion_id = gate.get(&quot;discussion_id&quot;) or sidecar.new_discussion_id()
    ...
    echoed = decision.get(&quot;discussion_id&quot;)            # discussion_id 由前端原样回传
    if echoed and str(echoed) != str(discussion_id):
        discussion_id = str(echoed)
        gate = {**gate, &quot;discussion_id&quot;: discussion_id}
</code></pre>
<p>
同样地，<code>brief</code> 每次重放都会用最新的 State + 最新的讨论日志重建，因此作者讨论出来的内容能反映到新一轮门禁卡上。</p>
<h3 id="23-命名约束">2.3 命名约束</h3><p>
节点名 <code>gate</code> 与 State 字段 <code>stage_gate</code> 不同名，是因为 <strong>LangGraph 限制节点名不能与 State 键同名</strong>：</p>
<div class="srcline">novelcraft/app/core/nodes.py:1993-1996</div><pre><code>NODES = {
    &quot;router&quot;: router_node,
    # 注意：节点名不能与 State 键同名（LangGraph 限制），故节点叫 gate，State 字段叫 stage_gate
    &quot;gate&quot;: stage_gate_node,
</code></pre>
<hr />
<h2 id="3-三个挂起点">3. 三个挂起点</h2><h3 id="31-总览">3.1 总览</h3><div class="tbl-wrap"><table>
<thead>
<tr>
<th>
kind</th>
<th>
节点</th>
<th>
时机</th>
<th>
恢复 API</th>
<th>
恢复入口校验</th>
</tr>
</thead>
<tbody>
<tr>
<td>
<code>confirm</code></td>
<td>
<code>stage_gate_node</code></td>
<td>
进入 worldbuilding / character / outline / <strong>writing</strong> 前</td>
<td>
<code>POST /projects/{id}/resume</code></td>
<td>
<code>{&quot;human_review&quot;,&quot;gate&quot;} &amp; state.next</code></td>
</tr>
<tr>
<td>
<code>review</code></td>
<td>
<code>human_review_node</code></td>
<td>
每个阶段产出后</td>
<td>
<code>POST /projects/{id}/review</code></td>
<td>
<code>&quot;human_review&quot; in state.next</code></td>
</tr>
<tr>
<td>
<code>question</code></td>
<td colspan="3"><small>保留兼容代码：事件构造函数（<code>interrupt_question_event</code>）与 <code>/resume</code> 的 <code>action=answer</code> 分支都还在，但 <b>没有任何节点发出 <code>kind=question</code></b>——当前图只有 <code>confirm</code> 与 <code>review</code> 两个挂起点。</small></td>
<td>
同上</td>
</tr>
</tbody>
</table></div>
<div class="srcline">novelcraft/app/core/nodes.py:1847-1848 · novelcraft/app/core/prompts.py:322-323</div><pre><code># nodes.py:1848 —— 需要「先对齐再创作」的阶段；reviewing / polishing 是对产物的加工，不设门禁
STAGE_GATES = {&quot;worldbuilding&quot;, &quot;character&quot;, &quot;outline&quot;, &quot;writing&quot;}
# prompts.py:323 —— 门禁轮次软上限：超过后仍要求确认，只在 tips 中提示可直接确认
GATE_MAX_ROUNDS = 5
</code></pre>
<h3 id="32-kindconfirm阶段确认门禁">3.2 <code>kind=confirm</code>：阶段确认门禁</h3><p>
<strong>触发</strong>：<code>router</code> 判定当前阶段在 <code>STAGE_GATES</code> 内且门禁未对当前作用域放行。</p>
<div class="srcline">novelcraft/app/core/graph.py:54-64</div><pre><code>    gate = state.get(&quot;stage_gate&quot;) or {}
    # 已放行且仍适用于当前章/卷（v1.5 J2）：写作按章、大纲按卷确认，避免每章重复询问
    if NODES.gate_applies_to_current_scope(gate, stage, state):
        return _node_for(stage)                    # 已放行（§9.5.6）
    if stage in STAGE_GATES:
        # J18：写作前先定章纲——当前章章纲未生成时先走「章纲生成」节点，
        # 随后进门禁由作者就章纲探讨确认，确认后才撰写正文
        if stage == &quot;writing&quot; and state.get(&quot;outline&quot;) and not NODES.has_chapter_outline(state):
            return &quot;chapter_outline&quot;
        return &quot;gate&quot;                              # 先与作者对齐，再创作
</code></pre>
<p>
<strong>payload（下发前端）</strong>：</p>
<pre><code class="language-json">{
  &quot;kind&quot;: &quot;confirm&quot;,
  &quot;stage&quot;: &quot;writing&quot;,
  &quot;round&quot;: 1,
  &quot;discussion_id&quot;: &quot;d_xxxxxxxxxx&quot;,
  &quot;brief&quot;: {
    &quot;title&quot;: &quot;第 5 章《玉佩》&quot;,
    &quot;goal&quot;: &quot;请先确认本章章纲……（已按章纲预取 3 条写作资料）&quot;,
    &quot;questions&quot;: [{&quot;id&quot;: &quot;pov&quot;, &quot;label&quot;: &quot;本章视角 / 时态&quot;, &quot;placeholder&quot;: &quot;第三人称限知 · 过去时&quot;, &quot;required&quot;: false}],
    &quot;checklist&quot;: [&quot;已确认结局走向&quot;],
    &quot;tips&quot;: [&quot;本章要回收 / 埋下哪些伏笔，现在说最有效&quot;],
    &quot;chapter_outline&quot;: {&quot;title&quot;: &quot;...&quot;, &quot;summary&quot;: &quot;...&quot;, &quot;target_word_count&quot;: 3000},
    &quot;foreshadow_plan&quot;: {&quot;plant&quot;: [&quot;...&quot;], &quot;payoff&quot;: [&quot;...&quot;]},
    &quot;new_characters&quot;: [{&quot;name&quot;: &quot;...&quot;}]
  }
}
</code></pre>
<p>
<code>brief</code> 由 <code>build_gate_brief()</code> 构造，<strong>只读 State 与 sidecar，不产出正文</strong>。问题模板在 <code>STAGE_GATE_TEMPLATE</code>（<code>nodes.py:1874-1915</code>）。</p>
<p>
<strong>decision（前端回传）</strong>：</p>
<div class="tbl-wrap"><table>
<thead>
<tr>
<th>
字段</th>
<th>
说明</th>
</tr>
</thead>
<tbody>
<tr>
<td>
<code>action</code></td>
<td>
<code>confirm</code>（放行）/ <code>revise</code>（自环，round+1 重新下发卡片）</td>
</tr>
<tr>
<td>
<code>feedback</code> / <code>notes</code></td>
<td>
作者意见；<code>notes</code> 为 dict 时落盘（J37）</td>
</tr>
<tr>
<td>
<code>discussion_id</code></td>
<td>
原样回传，保持同一轮对话连续性</td>
</tr>
<tr>
<td>
<code>foreshadow</code></td>
<td>
<code>{plant:[], payoff:[]}</code> 勾选的伏笔（J21）</td>
</tr>
<tr>
<td>
<code>characters</code></td>
<td>
勾选的新角色名列表（J22）</td>
</tr>
</tbody>
</table></div>
<p>
<strong>恢复后的行为</strong>：</p>
<div class="srcline">novelcraft/app/core/nodes.py:1941-1953</div><pre><code>    updates: Dict[str, Any] = {
        &quot;stage_gate&quot;: {
            **gate, &quot;stage&quot;: stage, &quot;round&quot;: round_no,
            &quot;confirmed&quot;: confirmed, &quot;brief&quot;: brief,
            &quot;notes&quot;: decision.get(&quot;notes&quot;) if isinstance(decision.get(&quot;notes&quot;), dict) else {},
        },
        &quot;human_decision_pending&quot;: not confirmed,
    }
</code></pre>
<p>
确认时按勾选结果登记伏笔与新角色，并清空临时计划字段：</p>
<div class="srcline">novelcraft/app/core/nodes.py:1966-1988</div><pre><code>            updates[&quot;foreshadow&quot;] = _apply_foreshadow_plan(state, eff, co, cur_idx)
        updates[&quot;chapter_foreshadow_plan&quot;] = {}
        ...
            updates[&quot;character_settings&quot;] = _apply_new_characters(state, eff_nc, cur_idx)
        updates[&quot;chapter_new_characters&quot;] = []
</code></pre>
<p>
未回传 <code>foreshadow</code> / <code>characters</code>（旧客户端）时<strong>视为全选</strong>，保持兼容。</p>
<h3 id="33-kindreview人工审核">3.3 <code>kind=review</code>：人工审核</h3><p>
<strong>payload</strong>：</p>
<div class="srcline">novelcraft/app/core/nodes.py:1567-1576</div><pre><code>    payload = {
        &quot;kind&quot;: &quot;review&quot;,
        &quot;stage&quot;: stage,
        &quot;project_id&quot;: state[&quot;project_id&quot;],
        &quot;chapter_id&quot;: chapter_id,
        &quot;chapter_index&quot;: idx,
        &quot;issues&quot;: findings,
        # 单独下发，按&quot;你上一轮提的要求&quot;的口径展示
        &quot;rejected_feedback&quot;: rejected_feedback,
    }
</code></pre>
<p>
<code>issues</code> 是 <code>ReviewIssue{kind: ooc|foreshadow|conflict|logic, severity, description, chapter_id, paragraph_index, suggestion}</code>。<strong>已剔除 <code>rejected=True</code> 的条目</strong>（见 §10.4）。</p>
<p>
<strong>decision 与三种动作</strong>：</p>
<div class="tbl-wrap"><table>
<thead>
<tr>
<th>
action</th>
<th>
行为</th>
</tr>
</thead>
<tbody>
<tr>
<td>
<code>approve</code></td>
<td>
推进 <code>current_stage</code>、清空 <code>review_issues</code>、同步章节 status；<b>仅 <code>reviewing</code> / <code>polishing</code> 阶段通过才定稿入库</b>（<code>writing</code> 阶段只是确认草稿，不索引）</td>
</tr>
<tr>
<td>
<code>modify</code></td>
<td>
只写白名单字段（<code>world_setting</code>/<code>character_settings</code>/<code>outline</code>/<code>chapters</code>/<code>foreshadow</code>/<code>project_meta</code>/<code>llm_config</code>），同样推进阶段</td>
</tr>
<tr>
<td>
<code>reject</code></td>
<td>
写入一条 <code>rejected=True</code> 的 ReviewIssue，<code>route_after_human_review</code> 直连当前阶段节点重跑</td>
</tr>
</tbody>
</table></div>
<div class="srcline">novelcraft/app/core/nodes.py:1626-1634</div><pre><code>        # v1.5（J2）：通过时推进 current_stage，交回 router 统一分发（含阶段门禁）
        nxt = STAGE_FLOW.get(stage)
        # J16：润色是**可选工序** —— 审核通过时未明确要求润色（decision.polish）就跳过
        if stage == &quot;reviewing&quot; and not decision.get(&quot;polish&quot;):
            nxt = STAGE_FLOW.get(&quot;polishing&quot;)      # 跳过润色 → &quot;_next_chapter&quot;
        if nxt:
            updates[&quot;current_stage&quot;] = nxt
</code></pre>
<p>
<strong>状态推进与定稿入库</strong>：</p>
<div class="srcline">novelcraft/app/core/nodes.py:1651-1663</div><pre><code>        if stage in (&quot;writing&quot;, &quot;reviewing&quot;, &quot;polishing&quot;) and chapter_id and idx &lt; len(chapters) and not polish_applied:
            new_status = {&quot;writing&quot;: &quot;draft&quot;, &quot;reviewing&quot;: &quot;reviewed&quot;, &quot;polishing&quot;: &quot;reviewed&quot;}[stage]
            ...
        if stage in (&quot;reviewing&quot;, &quot;polishing&quot;):
            _index_approved_chapter(state, polished_chapter)
</code></pre>
<p>
<strong>润色候选（J15）</strong>：polishing 阶段只产出候选，不改正文。作者在「左原文 / 右润色」对比视图确认后才落盘；<code>discard_polish=true</code> 则保留原文。</p>
<h3 id="34-kindquestion生成中追问">3.4 <code>kind=question</code>：生成中追问（<b>当前无调用点</b>）</h3><p>
事件构造函数 <code>interrupt_question_event()</code> 与恢复走 <code>/resume</code> 的 <code>action=answer</code> 分支都还在，
但 <code>nodes.py</code> 全文只有两处 <code>interrupt()</code>（<code>kind=review</code> 与 <code>kind=confirm</code>），没有任何节点发出 <code>kind=question</code>：</p>
<div class="srcline">novelcraft/app/api/routers/creation.py:414-417</div><pre><code>    action = request.action or (&quot;answer&quot; if request.answer is not None else &quot;confirm&quot;)
    if action == &quot;answer&quot;:
        # kind=question 的 interrupt 恢复需返回 {&quot;data&quot;: ...}
        resume_data: Dict[str, Any] = {&quot;data&quot;: request.answer or &quot;&quot;}
</code></pre>
<hr />
<h2 id="4-状态机与路由">4. 状态机与路由</h2><h3 id="41-阶段流转">4.1 阶段流转</h3><div class="srcline">novelcraft/app/core/nodes.py:1838-1845</div><pre><code>STAGE_FLOW = {
    &quot;worldbuilding&quot;: &quot;character&quot;,
    &quot;character&quot;: &quot;outline&quot;,
    &quot;outline&quot;: &quot;writing&quot;,
    &quot;writing&quot;: &quot;reviewing&quot;,
    &quot;reviewing&quot;: &quot;polishing&quot;,
    &quot;polishing&quot;: &quot;_next_chapter&quot;,
}
</code></pre>
<h3 id="42-router-是唯一分发点">4.2 <code>router</code> 是唯一分发点</h3><p>
覆盖四条路径：首次进入 / 阶段推进 / 下一章 / 完成态恢复。这样门禁才能无遗漏地覆盖每个创作阶段（J2）。<code>human_review</code> 与 <code>next_chapter</code> 都改为设好 <code>current_stage</code> 后回 <code>router</code>，不再直连阶段节点。</p>
<p>
图接线见 <code>novelcraft/app/core/graph.py:89-143</code>。</p>
<h3 id="43-门禁作用域按章-按卷">4.3 门禁作用域：按章 / 按卷</h3><div class="srcline">novelcraft/app/core/nodes.py:1854-1867</div><pre><code>def _gate_scope_changed(gate, stage, state) -&gt; bool:
    &quot;&quot;&quot;写作按章、大纲按卷确认：章/卷推进后，已确认的门禁不再适用（需重新确认）。&quot;&quot;&quot;
    if stage == &quot;writing&quot;:
        return gate.get(&quot;chapter_index&quot;) != state.get(&quot;current_chapter_index&quot;, 0)
    if stage == &quot;outline&quot;:
        return gate.get(&quot;volume_index&quot;) != len(state.get(&quot;outline&quot;, []) or [])
    return False
def gate_applies_to_current_scope(gate, stage, state) -&gt; bool:
    if not gate or gate.get(&quot;stage&quot;) != stage or not gate.get(&quot;confirmed&quot;):
        return False
    return not _gate_scope_changed(gate, stage, state)
</code></pre>
<p>
第 5 章确认过不影响第 6 章重新确认；同一章内反复「继续」不再被拦。</p>
<h3 id="44-驳回不重复门禁">4.4 驳回不重复门禁</h3><div class="srcline">novelcraft/app/core/graph.py:78-86</div><pre><code>    if any(i.get(&quot;rejected&quot;) for i in review_issues):
        return _node_for(current_stage)      # 直连阶段节点重跑（不重复门禁）
    if current_stage == &quot;_next_chapter&quot;:
        return &quot;next_chapter&quot;
    return &quot;router&quot;
</code></pre>
<p>
已对齐过的事不该再问一遍。</p>
<hr />
<h2 id="5-完整时序">5. 完整时序</h2><p>
以「撰写第 N 章」为例：</p>
<pre><code> 1. 前端 POST /projects/{id}/run
 2. router ── writing 有门禁 ──→ gate
 3. router 发现无章纲 → chapter_outline（生成章纲 + 预取资料）→ 回 gate
 4. gate: interrupt(brief) 挂起 ── 下发 interrupt/confirm 卡
 5. 作者：右栏会话多轮讨论（POST /discuss，旁路，不写 checkpoint）
 6. 作者点「确认」→ POST /resume {action:&quot;confirm&quot;, discussion_id, foreshadow, characters, notes}
 7. gate 重放 → 按勾选登记伏笔/新角色 → stage_gate.confirmed=True
 8. route_after_gate ──→ writing
      ├─ retrieved 事件：引用卡（章纲 + 未回收伏笔 + 角色名，k=8）
      └─ delta 事件：正文 token 流式进中间栏编辑器
 9. human_review: interrupt(review 卡) 挂起
10. 作者 approve → POST /review
      ├─ current_stage: writing → reviewing
      ├─ 章节 status: draft（注意：此时**不**入库）
      └─ 回到 router
11. reviewing（AI 审核，产出 issues）→ human_review 再次挂起
12. 作者 approve 且 polish=true → polishing（产出候选，不改正文）
      → human_review 下发「左原文 / 右润色」对比 → 采用才落盘
13. 定稿（reviewing 通过）→ 正文写进向量库
14. next_chapter → router → 下一章门禁
</code></pre>
<p>
若审核通过时 <code>polish=false</code>，直接跳到 <code>_next_chapter</code>（润色不强制，可随时用 <code>/polish/start</code> 补做）。</p>
<hr />
<h2 id="6-交互契约">6. 交互契约</h2><h3 id="61-事件帧ndjson">6.1 事件帧（NDJSON）</h3><p>
<code>Content-Type: application/x-ndjson</code>，每帧一行。定义见 <code>novelcraft/app/api/stream_events.py</code>。</p>
<div class="tbl-wrap"><table>
<thead>
<tr>
<th>
type</th>
<th>
用途</th>
</tr>
</thead>
<tbody>
<tr>
<td>
<code>stage</code></td>
<td>
阶段切换</td>
</tr>
<tr>
<td>
<code>delta</code></td>
<td>
LLM token 增量，<code>target</code> 决定落在哪个面板：<code>editor</code> / <code>review</code> / <code>polish</code> / <code>artifact</code> / <code>chat</code></td>
</tr>
<tr>
<td>
<code>retrieved</code></td>
<td>
引用卡（<code>hits</code> 为结构化 <code>{type,id,label,snippet,score}</code>）</td>
</tr>
<tr>
<td>
<code>interrupt</code></td>
<td>
挂起卡，<code>kind</code> = <code>confirm</code> / <code>review</code>（<code>question</code> 的构造函数存在但无调用点，见 §3.4）</td>
</tr>
<tr>
<td>
<code>revised</code> / <code>applied</code></td>
<td>
低成本修改通道（<code>/revise-field</code>、<code>/revise-chapter</code>）的产出 / 写回确认，见 §8</td>
</tr>
<tr>
<td>
<code>sources</code> / <code>suggestion</code> / <code>discuss</code></td>
<td>
旁路讨论（<code>/discuss</code>）的引用卡、建议卡与会话帧</td>
</tr>
<tr>
<td>
<code>done</code> / <code>metrics</code> / <code>error</code></td>
<td>
收尾 / 统计 / 错误</td>
</tr>
</tbody>
</table></div>
<p>
<strong>interrupt 帧</strong>：</p>
<pre><code class="language-json">{&quot;type&quot;:&quot;interrupt&quot;,&quot;kind&quot;:&quot;confirm&quot;,&quot;payload&quot;:{&quot;stage&quot;:&quot;writing&quot;,&quot;round&quot;:1,&quot;discussion_id&quot;:&quot;d_x&quot;,&quot;brief&quot;:{...}}}
{&quot;type&quot;:&quot;interrupt&quot;,&quot;kind&quot;:&quot;review&quot;,&quot;payload&quot;:{&quot;stage&quot;:&quot;reviewing&quot;,&quot;chapter_id&quot;:&quot;ch_0004&quot;,&quot;issues&quot;:[...],&quot;content&quot;:{...},&quot;polish_candidate&quot;:{...}}}
</code></pre>
<h3 id="62-payload-必须从-interrupt-任务里取">6.2 payload 必须从 interrupt 任务里取</h3><p>
首轮 interrupt 的 payload <strong>不落 checkpoint</strong>，所以不能只读 <code>state.values</code>：</p>
<div class="srcline">novelcraft/app/api/routers/creation.py:220-233</div><pre><code>            intr_payload: Dict[str, Any] = {}
            for t in (getattr(state, &quot;tasks&quot;, None) or []):
                for i in (getattr(t, &quot;interrupts&quot;, None) or []):
                    if isinstance(getattr(i, &quot;value&quot;, None), dict):
                        intr_payload = i.value
                        break
            ...
            yield se.interrupt_confirm_event(
                intr_payload.get(&quot;stage&quot;) or gate.get(&quot;stage&quot;) or values.get(&quot;current_stage&quot;, &quot;&quot;),
                intr_payload.get(&quot;round&quot;) or gate.get(&quot;round&quot;, 1),
                intr_payload.get(&quot;discussion_id&quot;) or gate.get(&quot;discussion_id&quot;, &quot;&quot;),
                intr_payload.get(&quot;brief&quot;) or gate.get(&quot;brief&quot;) or {},
            )
</code></pre>
<h3 id="63-api-入口">6.3 API 入口</h3><div class="tbl-wrap"><table>
<thead>
<tr>
<th>
接口</th>
<th>
请求</th>
<th>
说明</th>
</tr>
</thead>
<tbody>
<tr>
<td>
<code>POST /run</code></td>
<td>
<code>{input?, llm_config?, force?}</code></td>
<td>
启动/继续创作</td>
</tr>
<tr>
<td>
<code>POST /resume</code></td>
<td>
<code>{action?, answer?, feedback?, notes?, discussion_id?, foreshadow?, characters?}</code></td>
<td>
门禁决策 / 回答问题</td>
</tr>
<tr>
<td>
<code>POST /review</code></td>
<td>
<code>{action, reason?, modifications?, discard_polish?, polish?}</code></td>
<td>
人审决策</td>
</tr>
<tr>
<td>
<code>POST /discuss</code></td>
<td>
<code>{message, scope?, target_id?, refs?, discussion_id?, checkpoint_id?, command?}</code></td>
<td>
旁路讨论（不写 checkpoint）</td>
</tr>
<tr>
<td>
<code>POST /revise-field</code></td>
<td>
<code>{field, instruction, target_ids?, discussion_id?, apply?}</code></td>
<td>
局部改字段</td>
</tr>
<tr>
<td>
<code>POST /revise-chapter</code></td>
<td>
<code>{instruction, chapter_id?}</code></td>
<td>
按意见修订正文</td>
</tr>
</tbody>
</table></div>
<p>
<code>force=true</code>（J27）用于「重新生成本章」，只对本次 run 的首次写作有效，走进程内信号，不落 State。</p>
<hr />
<h2 id="7-旁路讨论门禁的多轮对话">7. 旁路讨论：门禁的多轮对话</h2><p>
作者在门禁卡上可以来回讨论 N 轮，但<strong>这些对话不进图</strong>。</p>
<div class="srcline">novelcraft/app/core/sidecar.py:1-7</div><pre><code>讨论是图**之外**的独立服务（§9.4.2「图挂起 ≠ 对话挂起」）：
- **不推进图、不写 checkpoint**：可来回 N 轮，图上毫无痕迹。
- **会话历史只落 sidecar，绝不进 State**：避免重蹈 P0-5（State 膨胀）/ H7。
- **复用 H4 检索器**：RAG 能力从生成流程内扩展到旁路，回答附 `sources`。
- **AI 给「建议」不直接改稿**：落地走既有 PUT /state 或 POST /review{modify}，不开后门。
</code></pre>
<p>
存储：TiDB <code>sidecar_events</code> 表，append-only。</p>
<div class="tbl-wrap"><table>
<thead>
<tr>
<th>
log_key</th>
<th>
用途</th>
</tr>
</thead>
<tbody>
<tr>
<td>
<code>{project_id}</code></td>
<td>
统一会话流（run + discuss 事件），用于回放</td>
</tr>
<tr>
<td>
<code>{project_id}::{discussion_id}</code></td>
<td>
单轮讨论明细</td>
</tr>
</tbody>
</table></div>
<p>
<strong>为什么要旁路</strong>：每次 interrupt 都是一个 checkpoint，若多轮讨论也走 interrupt，checkpoint 会随讨论轮次堆积；且讨论内容进入创作 State 会污染后续生成。旁路后，门禁只承载「最终确认」这一个动作。</p>
<p>
<strong>门禁如何读到讨论内容</strong>：<code>stage_gate_node</code> 重放时从 sidecar 拉最近 20 条重建 brief：</p>
<div class="srcline">novelcraft/app/core/nodes.py:1903-1909</div><pre><code>    recent: List[Dict[str, Any]] = []
    try:
        recent = sidecar.discussion_log(pid, discussion_id).read(limit=20)
    except Exception:
        recent = []
    brief = build_gate_brief(stage, state, recent)
</code></pre>
<hr />
<h2 id="8-低成本修改通道">8. 低成本修改通道</h2><p>
驳回 = 一次完整阶段重跑（整章重写），成本高。真正低成本的修改路径不经过 interrupt：</p>
<div class="tbl-wrap"><table>
<thead>
<tr>
<th>
接口</th>
<th>
行为</th>
</tr>
</thead>
<tbody>
<tr>
<td>
<code>POST /revise-field</code></td>
<td>
局部改世界观 / 人设 / 大纲。提示词强约束「未提及部分逐字保留」，产出完整字段值草稿。<code>apply=false</code> 只出草稿；<code>apply=true</code> 按产出节点归属写回 State，<strong>不推进图、不触发重生成</strong></td>
</tr>
<tr>
<td>
<code>POST /revise-chapter</code></td>
<td>
按意见整章修订，流式输出到中间栏编辑器</td>
</tr>
<tr>
<td>
<code>PUT /chapters/{id}/paragraph/{i}</code></td>
<td>
段落级直接编辑</td>
</tr>
</tbody>
</table></div>
<p>
<code>apply=true</code> 时挂起在门禁的节点归属处理：</p>
<div class="srcline">novelcraft/app/api/routers/creation.py:508-513</div><pre><code>            at_gate = &quot;gate&quot; in next_nodes
            writer = N.FIELD_WRITER_NODE.get(request.field, &quot;router&quot;)
            # 挂起在门禁时以 router 身份写：router 仍会返回 gate，门禁不丢
            as_node = &quot;router&quot; if at_gate else writer
            await graph.aupdate_state(config, {request.field: merged}, as_node=as_node)
</code></pre>
<hr />
<h2 id="9-持久化并发与错误恢复">9. 持久化、并发与错误恢复</h2><h3 id="91-每次-interrupt-都是一个-checkpoint">9.1 每次 interrupt 都是一个 checkpoint</h3><p>
checkpoint 落 TiDB（自研 <code>TiDBSaver</code>，因为官方 mysql saver 依赖 <code>JSON_TABLE()</code>，TiDB 不支持）。因此：</p>
<ul>
<li>
挂起时长不受限，进程重启后可恢复</li>
<li>
每个挂起点天然可回溯（见 <code>retention.py</code>：里程碑永久保留 + 最近 20 步级，取值来自 <code>settings.checkpoint_keep_recent</code>）</li>
</ul>
<h3 id="92-并发纪律">9.2 并发纪律</h3><div class="srcline">novelcraft/app/api/in_flight.py:1-5</div><pre><code>核心：只有「/run 流式响应正在进行」才算&quot;图运行中&quot;。
图停在 human_review 中断（流已结束、前端已收到 interrupt）属于静止态，允许裸 PUT /state。
</code></pre>
<ul>
<li>
<code>track_run</code> 在流式响应期间标记 thread 为运行中</li>
<li>
重复触发返回 409</li>
<li>
<strong>挂起态不算运行中</strong>，因此作者在审核卡上可以直接改 State</li>
</ul>
<h3 id="93-停在未知节点-异常">9.3 停在未知节点 = 异常</h3><p>
停在既非 <code>gate</code> 也非 <code>human_review</code> 的节点（最常见：LLM 连接失败导致节点抛错、图原地等待重试）没有任何卡片可操作：</p>
<div class="srcline">novelcraft/app/api/routers/creation.py:251-262</div><pre><code>        else:
            # J30：停在**其他**节点既没有人审/门禁卡片可操作，也不是正常结束。
            # 最常见的是节点执行失败后图原地暂停（例如 LLM 连接错误 APIConnectionError：
            # 节点抛错 → 图停在那个节点等待重试）。此前这里什么都不发，前端 phase 会
            # **永久停在 generating** —— 按钮显示「停止」，再点等于停止，观感就是
            # 「点击生成没有反应，也没有任何正文输出」。必须补发错误帧让前端能恢复。
</code></pre>
<p>
必须补发 <code>NODE_STALLED</code> 错误帧，否则前端 UI 永久卡死。</p>
<hr />
<h2 id="10-关键设计决策记录">10. 关键设计决策记录</h2><h3 id="101-j1-门禁从先生成后审核到先对齐后生成">10.1 J1 门禁：从「先生成后审核」到「先对齐后生成」</h3><p>
<strong>问题</strong>：<code>POST /run</code> 经 router 直接进阶段节点，先生成、后审核。作者在世界观/人设/大纲/撰写前收不到任何提示，不满意只能驳回重跑——每轮都是一次完整生成，成本高且不一定命中意图。</p>
<p>
<strong>处理</strong>：新增 <code>stage_gate</code> 节点，进入四个创作阶段前先挂起对齐。</p>
<h3 id="102-j2-router-唯一分发点">10.2 J2 router 唯一分发点</h3><p>
<strong>问题</strong>：<code>human_review</code> 与 <code>next_chapter</code> 的条件边直连阶段节点，绕过 router，门禁无处插入；<code>STAGE_FLOW</code> 判定逻辑散落在各路由函数。</p>
<p>
<strong>处理</strong>：两条路径都改为「设好 <code>current_stage</code> 后回 router」。</p>
<h3 id="103-j18-写作前先出章纲">10.3 J18 写作前先出章纲</h3><p>
<strong>问题</strong>：章纲与正文同时生成，作者没有单独审视章纲的机会。</p>
<p>
<strong>处理</strong>：<code>chapter_outline</code> 节点前置，章纲生成后<strong>先进门禁</strong>由作者确认，确认后才撰写正文。</p>
<h3 id="104-cr-59-作者的驳回理由-ai-审核结论">10.4 CR-59 作者的驳回理由 ≠ AI 审核结论</h3><p>
<strong>问题</strong>：驳回时写入的 ReviewIssue 会混进下一轮下发的 <code>issues</code>，前端把作者自己的话回显成「AI 发现的严重问题」，作者看到「1 个问题：角色数量不变…」以为根本没改。</p>
<p>
<strong>处理</strong>：</p>
<div class="srcline">novelcraft/app/core/nodes.py:1562-1565</div><pre><code>    findings = [
        i for i in all_issues if not (isinstance(i, dict) and i.get(&quot;rejected&quot;))
    ]
    rejected_feedback = _rejected_feedbacks(state)
</code></pre>
<p>
<code>rejected=True</code> 的条目留在 State 里供重跑时读取，但单独以 <code>rejected_feedback</code> 字段下发。</p>
<h3 id="105-j37-门禁卡上的答案必须能进-prompt">10.5 J37 门禁卡上的答案必须能进 prompt</h3><p>
<strong>问题</strong>：作者填的「本卷计划章数」只写进了讨论日志，阶段节点读不到，卷纲仍按 prompt 示例输出（每卷都是 10 章）。</p>
<p>
<strong>处理</strong>：<code>stage_gate.notes</code> 落盘，节点从 State 读取。这是典型的&quot;回路断线&quot;——UI 有输入、数据也存了，但节点读不到。<strong>读得到才算闭环</strong>。</p>
<h3 id="106-cr-64-定稿才入库">10.6 CR-64 定稿才入库</h3><p>
<strong>问题</strong>：正文写完就进向量库，作者还没「通过」就已被检索到。</p>
<p>
<strong>处理</strong>：只有 <code>reviewing</code> / <code>polishing</code> 通过才 <code>_index_approved_chapter</code>。</p>
<h3 id="107-j15j16-润色是可选工序且只产候选">10.7 J15/J16 润色是可选工序且只产候选</h3><p>
润色节点不直接改正文，产出候选版本供左右对比；审核通过时未明确要求润色则跳过。</p>
<h3 id="108-j25-完成态恢复">10.8 J25 完成态恢复</h3><p>
<code>current_stage == &quot;completed&quot;</code> 时，判定「还能继续写」的逻辑是纯函数，改不了 State，必须经 <code>recover</code> 节点把目标阶段写回，否则门禁与后续路由全部错位（表现为「继续创作」毫无反应）。</p>
<hr />
<h2 id="11-已知边界">11. 已知边界</h2><div class="tbl-wrap"><table>
<thead>
<tr>
<th>
边界</th>
<th>
说明</th>
</tr>
</thead>
<tbody>
<tr>
<td>
<strong>并发标记是进程内的</strong></td>
<td>
<code>in_flight</code> 用进程内 Set，多副本部署会失效，需换成分布式锁</td>
</tr>
<tr>
<td>
<strong>一致性是软检测</strong></td>
<td>
<code>reviewing</code> 的 issues 是 LLM 自查产物，没有规则引擎 / NLI 硬校验。回路只保证「作者有机会看到并否决」，不保证问题被找全</td>
</tr>
<tr>
<td>
<strong>AI 看不到讨论过程</strong></td>
<td>
多轮讨论只以 <code>notes</code> 和最终 brief 的形式进入生成，中间推理链不传给阶段节点</td>
</tr>
<tr>
<td>
<strong>reject 成本高</strong></td>
<td>
一次驳回 = 一次完整阶段重跑。低成本修改应走 <code>/revise-field</code>、<code>/revise-chapter</code></td>
</tr>
<tr>
<td>
<strong>GATE_MAX_ROUNDS 是软上限</strong></td>
<td>
超过 5 轮仍要求确认，只在 <code>tips</code> 里提示可直接确认</td>
</tr>
<tr>
<td>
<strong><code>kind=question</code> 无调用点</strong></td>
<td>
事件构造函数与 <code>/resume</code> 的 <code>action=answer</code> 分支都还在，但没有任何节点发出 <code>kind=question</code>——挂起点实际只有 <code>confirm</code> 与 <code>review</code></td>
</tr>
</tbody>
</table></div>
</article>
</div>
