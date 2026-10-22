---
title: LangGraph 设计详解
description: NovelCraft AI 的 LangGraph 设计笔记：为什么所有入口都要经过 router、阶段门禁与人审两种挂起的区别、正文挪出 State 的原因，以及踩过的坑。
outline: [2, 3]
---
<div class="an-doc">
<header class="hero">
  <div class="wrap">
    <div class="eyebrow">State Machine · HITL · Time Travel</div>
    <h1 id="langgraph-在本系统里的设计">LangGraph 在本系统里的设计</h1>
    <p class="lead">
      这篇文档讲的是<strong>NovelCraft AI 为什么这样接线</strong>：
      为什么所有入口都要经过一个 <code>router</code>、为什么阶段门禁和人审是两种不同的挂起、
      为什么正文要挪出 State、哪些坑是 LangGraph 自身的限制逼出来的。
      每节都按「遇到什么问题 → 现在怎么做 → 不这么做会怎样」展开。
    </p>
    <div class="badges">
      <span class="badge">LangGraph 0.3.x</span>
      <span class="badge">StateGraph</span>
      <span class="badge">自研 TiDB checkpointer</span>
      <span class="badge">interrupt × 2</span>
      <span class="badge">步级快照</span>
      <span class="badge">单进程 uvicorn</span>
    </div>
    <div class="stats">
      <div class="stat"><b>12</b><small>图节点</small></div>
      <div class="stat"><b>1</b><small>分发点（router）</small></div>
      <div class="stat"><b>2</b><small>interrupt 类型</small></div>
      <div class="stat"><b>6</b><small>创作阶段</small></div>
      <div class="stat"><b>20</b><small>步级快照保留</small></div>
      <div class="stat"><b>1</b><small>唯一状态源（TiDB）</small></div>
    </div>
  </div>
</header>
<!-- ===================== 01 为什么 ===================== -->
<section id="why">
  <div class="wrap">
    <div class="eyebrow">01 · Motivation</div>
    <h2 id="why">为什么用 LangGraph：一个"写小说"的流程图</h2>
    <p class="lead">
      这类系统的难点在于<b>控制流</b>：什么时候该等人、等人回来之后从哪继续、
      上一章写的东西怎么留给下一章、以及怎么在写坏之后退回上一步。这些正好是状态机擅长的事。
    </p>
    <h3 id="why-2">如果不用状态机会是什么样</h3>
    <div class="vs">
      <div class="card warn">
        <h4 id="why-3">一个大 if-else 链</h4>
        <p>阶段、判断、人审、回退全塞在一个函数里。<br>
        后果：<b>回退逻辑藏在 17 个分支里</b>，改一处就要通读全函数；
        "现在处于哪个阶段"这件事只能靠变量猜；写坏之后无法精确退回。</p>
      </div>
      <div class="mid">VS</div>
      <div class="card ok">
        <h4 id="why-4">LangGraph 状态机</h4>
        <p>节点 = 阶段，边 = 流转条件，State = 全部进度。<br>
        后果：<b>控制流可视</b>、<b>进度可持久化</b>、<b>每步可回退</b>。</p>
      </div>
    </div>
    <h3 id="why-5">这个系统对 LangGraph 提出了三个额外要求</h3>
    <div class="steps">
      <li><b>挂起必须是"真挂起"</b><span>图跑到一半要把控制权交回 HTTP 请求，作者可能几分钟后才点确认。
      进程不能因为这次等待而占着。</span></li>
      <li><b>恢复必须精确</b><span>作者驳回"这一章"时，要回到<b>这一章</b>的写作节点，
      世界观与人设不必重跑。</span></li>
      <li><b>状态不能太大</b><span>一整章正文 6000+ 字 × N 章，全量进 State 会让每个 checkpoint
      都变成一份全文快照。</span></li>
    </div>
    <p>后面 13 节讲的就是这三个要求各自怎么被满足，以及为此付出了什么代价。</p>
    <div class="note i"><b>💡 一句话概括</b><div>
      LangGraph 在这里的作用是<b>让"人在回路"变成图上的一等公民</b>——
      挂起、恢复、回退都由状态机原生支持，业务代码里不用手搓流程控制。
    </div></div>
  </div>
</section>
<!-- ===================== 02 全图形状 ===================== -->
<section id="shape">
  <div class="wrap">
    <div class="eyebrow">02 · Graph Shape</div>
    <h2 id="shape">全图形状：12 个节点，6 个阶段，1 个分发点</h2>
    <div class="diagram">
      <div class="flow" style="padding-top:22px">
        <div class="node plain">START</div>
        <span class="arw"></span>
        <div class="node router">router<small>唯一分发点</small></div>
      </div>
      <div class="link"><em>按 current_stage +门禁状态分发</em><i></i></div>
      <div class="flow">
        <div class="node gate">gate<small>阶段门禁 · interrupt</small></div>
        <span class="arw faint"></span>
        <div class="node">worldbuilding</div>
        <span class="arw faint"></span>
        <div class="node">character_gen</div>
        <span class="arw faint"></span>
        <div class="node">outline_gen</div>
        <span class="arw faint"></span>
        <div class="node">chapter_outline<small>J18 写作前置</small></div>
        <span class="arw faint"></span>
        <div class="node">writing</div>
        <span class="arw faint"></span>
        <div class="node">reviewing</div>
        <span class="arw faint"></span>
        <div class="node">polishing</div>
        <span class="arw faint"></span>
        <div class="node hitl">human_review<small>interrupt</small></div>
        <span class="arw faint"></span>
        <div class="node plain">next_chapter</div>
      </div>
      <div class="cap">图 1 · 主干：六个创作阶段串行，每个阶段后面都跟一个人审节点</div>
    </div>
    <h3 id="shape-7">两类节点，三种边</h3>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>类别</th><th>成员</th><th>边</th></tr></thead>
        <tbody>
          <tr>
            <td><b>阶段节点</b></td>
            <td><code>worldbuilding</code> <code>character_gen</code> <code>outline_gen</code>
                <code>writing</code> <code>reviewing</code> <code>polishing</code></td>
            <td>无条件边 → <code>human_review</code></td>
          </tr>
          <tr>
            <td><b>控制节点</b></td>
            <td><code>router</code> <code>gate</code> <code>chapter_outline</code>
                <code>human_review</code> <code>next_chapter</code> <code>recover</code></td>
            <td>条件边（router / gate / human_review / next_chapter）<br><small>+ 无条件边：recover→router、chapter_outline→gate</small></td>
          </tr>
        </tbody>
      </table>
    </div>
    <p>
      阶段节点<b>无条件</b>连到 <code>human_review</code>（<code>graph.py:115-116</code>）：
      任何阶段产物都必须经人审才能往下走，这是本系统的硬约束，由图的接线保证，无需每个节点自觉。
    </p>
    <h3 id="shape-8">阶段流转表唯一定义在 nodes.py</h3>
    <pre><span class="c"># app/core/nodes.py:1838（STAGE_GATES 在 :1848）</span>
STAGE_FLOW = {
    <span class="s">"worldbuilding"</span>: <span class="s">"character"</span>,
    <span class="s">"character"</span>:     <span class="s">"outline"</span>,
    <span class="s">"outline"</span>:       <span class="s">"writing"</span>,
    <span class="s">"writing"</span>:       <span class="s">"reviewing"</span>,
    <span class="s">"reviewing"</span>:     <span class="s">"polishing"</span>,
    <span class="s">"polishing"</span>:     <span class="s">"_next_chapter"</span>,
}
<span class="c"># 需要「先对齐再创作」的阶段；reviewing/polishing 是对产物的加工，不设门禁</span>
STAGE_GATES = {<span class="s">"worldbuilding"</span>, <span class="s">"character"</span>, <span class="s">"outline"</span>, <span class="s">"writing"</span>}</pre>
    <div class="note w"><b>⚠ 流转表为什么放在 nodes.py</b><div>
      <code>graph.py</code> 需要引用 <code>STAGE_FLOW</code>，而 <code>nodes.py</code> 又要引用图的节点名——
      放<em>哪边都会形成循环导入</em>。最终统一放<code>nodes.py</code>，由 <code>graph.py</code> 单向 import。
      同理 J25 的分卷推进判定也放 nodes.py，避免"图里一份、节点里一份"口径漂移。
    </div></div>
    <h3 id="shape-9">阶段名 ≠ 节点名</h3>
    <pre><span class="c"># graph.py:18-26（节选，其余三阶段同名）</span>
STAGE_TO_NODE = {
    <span class="s">"worldbuilding"</span>: <span class="s">"worldbuilding"</span>,
    <span class="s">"writing"</span>:       <span class="s">"writing"</span>,        <span class="c"># 同名</span>
    <span class="s">"reviewing"</span>:     <span class="s">"reviewing"</span>,      <span class="c"># 同名</span>
    <span class="s">"polishing"</span>:     <span class="s">"polishing"</span>,      <span class="c"># 同名</span>
    <span class="s">"character"</span>:     <span class="s">"character_gen"</span>,   <span class="c"># ← 不一样</span>
    <span class="s">"outline"</span>:       <span class="s">"outline_gen"</span>,<span class="c">#     不一样</span>
    <span class="s">"completed"</span>:     <span class="s">"_completed"</span>,      <span class="c"># ← 伪节点，router 特殊处理</span>
}
NODE_TO_STAGE = {v: k for k, v in STAGE_TO_NODE.items()}   <span class="c"># 反向</span></pre>
    <p>
      双向映射意味着<b>阶段名可以自由演进</b>，节点名跟随调整即可，不必反过来改State 里的历史值。
    </p>
  </div>
</section>
<!-- ===================== 03 router ===================== -->
<section id="router">
  <div class="wrap">
    <div class="eyebrow">03 · The Single Dispatcher</div>
    <h2 id="router">router：整个系统只有一个分发点</h2>
    <p class="lead">
      这是本系统<b>最重要的一条接线约定</b>：任何"该去哪个阶段"的判断都收敛到 <code>router</code>，
      其它节点一律不自己决定下一站。
    </p>
    <h3 id="router-11">为什么必须唯一</h3>
    <p>
      创作流程有<b>四条</b>路径都会"从某处继续"，此前每条各自判断一次阶段流向：
    </p>
    <ul class="clean">
      <li>首次进入（<code>START</code>）</li>
      <li>人审通过后推进阶段</li>
      <li>写完一章进入下一章</li>
      <li>完成态恢复（<code>completed</code> → 其实还能继续写）</li>
    </ul>
    <p>
      分头判断的直接后果是 <b>阶段门禁被绕过</b>：某些路径不检查门禁状态就能进下一个阶段，
      于是"先对齐再创作"的约束在部分路径上失效——表现为<b>门禁卡偶尔不出现</b>，
      而且极难定位（同一阶段，有时问有时不问）。
    </p>
    <h3 id="router-12">router 的四段判定</h3>
    <pre><span class="c"># app/core/graph.py:42</span>
<span class="k">def</span> <span class="n">router</span>(state: NovelState) -&gt; str:
    stage = state.get(<span class="s">"current_stage"</span>, <span class="s">"worldbuilding"</span>)
    <span class="c"># ① 完成态恢复：判定是纯函数，改不了 state，必须经 recover 节点写回</span>
    <span class="k">if</span> stage == <span class="s">"completed"</span>:
        <span class="k">if not</span> next_stage_from_completed(state):
            <span class="k">return</span> END
        <span class="k">return</span> <span class="s">"recover"</span>
    gate = state.get(<span class="s">"stage_gate"</span>) or {}
    <span class="c"># ② 已放行且仍适用于当前章/卷 -&gt; 直接进阶段节点</span>
    <span class="k">if</span> NODES.gate_applies_to_current_scope(gate, stage, state):
        <span class="k">return</span> _node_for(stage)
    <span class="c"># ③ 需要门禁的阶段 -&gt; 先去门禁</span>
    <span class="k">if</span> stage <span class="k">in</span> STAGE_GATES:
        <span class="c"># J18：当前章章纲未生成时，先走章纲生成，再进门禁</span>
        <span class="k">if</span> stage == <span class="s">"writing"</span> <span class="k">and</span> state.get(<span class="s">"outline"</span>) <span class="k">and</span> <span class="k">not</span> NODES.has_chapter_outline(state):
            <span class="k">return</span> <span class="s">"chapter_outline"</span>
        <span class="k">return</span> <span class="s">"gate"</span>
    <span class="c"># ④ 其余阶段直接执行</span>
    <span class="k">return</span> _node_for(stage)</pre>
    <h3 id="router-13">②「仍适用于当前章/卷」是关键细节</h3>
    <p>
      门禁通过一次之后<b>不能永久有效</b>：写作按<b>章</b>确认，大纲按<b>卷</b>确认。
      否则第 1 章的门禁确认会让第 30 章直接开写，作者再也拦不住。
    </p>
    <div class="note g"><b>✓ gate_applies_to_current_scope()</b><div>
      门禁记录 <code>{stage, chapter_index}</code> 或 <code>{stage, volume_index}</code>；
      只有它与当前 <code>current_chapter_index</code> / <code>len(outline)</code> 一致时才算放行。
      这样"写第 1 章确认一次世界观"和"每章都要确认章纲"能共存，而不会互相干扰。
    </div></div>
    <h3 id="router-14">① 为什么完成态需要单独的 recover 节点</h3>
    <div class="note d"><b>✗ 一个真实的「毫无反应」故障</b><div>
      原本 router 只想判断"完成态下还能不能继续写"，判完直接 <code>return</code> 目标阶段。
      但<b>router 是纯函数</b>——它不能写 State。于是 <code>current_stage</code> 仍是 <code>completed</code>，
      下一个节点读到的还是 <code>completed</code>，门禁与后续路由<b>全部错位</b>。
      表现就是<b>点「继续创作」毫无反应</b>，且日志里看不到任何错误。<br><br>
      修法就是 J25 引入的 <code>recover</code> 节点：它是<b>真节点</b>，可以把
      <code>current_stage</code> 写回 State，然后 <code>add_edge("recover", "router")</code> 再重新分发。
    </div></div>
    <div class="note i"><b>💡 这条经验的可推广部分</b><div>
      在 LangGraph 里，<b>条件路由函数不能有副作用</b>。需要"根据判断结果修改 State"时，
      必须借一个节点来写。<b>「判断」与「改状态」不能放在同一个函数里</b>——
      这是状态机编程里最容易踩、也最难查的一类坑。
    </div></div>
  </div>
</section>
<!-- ===================== 04 门禁 ===================== -->
<section id="gate">
  <div class="wrap">
    <div class="eyebrow">04 · Stage Gates</div>
    <h2 id="gate">阶段门禁：把"先对齐再创作"做成图的结构</h2>
    <p class="lead">
      <code>STAGE_GATES</code> 圈定了四个需要<b>先与作者对齐</b>的阶段。
      它们被实现为<b>图上的一类节点</b>。
    </p>
    <h3 id="gate-16">门禁节点的行为</h3>
    <pre><span class="c"># graph.py:67 · 门禁放行 → 真实生成；未确认 → 自环</span>
<span class="k">def</span> <span class="n">route_after_gate</span>(state) -&gt; str:
    gate = state.get(<span class="s">"stage_gate"</span>) or {}
    <span class="k">if</span> gate.get(<span class="s">"confirmed"</span>):
        <span class="k">return</span> _node_for(gate.get(<span class="s">"stage"</span>) <span class="k">or</span> state.get(<span class="s">"current_stage"</span>))
    <span class="k">return</span> <span class="s">"gate"</span>          <span class="c"># ← 自环：每轮 resume 都是新 checkpoint</span></pre>
    <div class="note i"><b>💡 自环为什么天然支持多轮讨论</b><div>
      图在 <code>gate</code> 自环看似会死循环，实际上<b>每轮 resume 都是一次新的图执行</b>，
      会写出一个新的 checkpoint。作者可以反复回答门禁问题，
      直到 <code>stage_gate.confirmed</code> 为真才放行。<code>GATE_MAX_ROUNDS = 5</code> 只是软提示，
      超过后仍在 tips 里说"可直接确认"，<b>不强制</b>。
    </div></div>
    <h3 id="gate-17">门禁只覆盖"从零创作"，不覆盖"加工产物"</h3>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>阶段</th><th>有门禁</th><th>为什么</th></tr></thead>
        <tbody>
          <tr><td><code>worldbuilding</code> 世界观</td><td style="color:var(--ok)">✓</td><td>全书一致性的地基，值得先对齐</td></tr>
          <tr><td><code>character</code> 人设</td><td style="color:var(--ok)">✓</td><td>同上，且角色设定会被直塞进每章 prompt</td></tr>
          <tr><td><code>outline</code> 大纲</td><td style="color:var(--ok)">✓</td><td>按<b>卷</b>确认，一个卷问一次</td></tr>
          <tr><td><code>writing</code> 正文</td><td style="color:var(--ok)">✓</td><td>按<b>章</b>确认（就章纲探讨）</td></tr>
          <tr><td><code>reviewing</code> 审核</td><td style="color:var(--danger)">✗</td><td>它是对<b>已有产物</b>的检查，门禁在这里没有对象</td></tr>
          <tr><td><code>polishing</code> 润色</td><td style="color:var(--danger)">✗</td><td>同上；而且它是<b>可选工序</b>（见下）</td></tr>
        </tbody>
      </table>
    </div>
    <p>
      换句话说：<b>门禁管"开始写之前"，人审管"写完之后"</b>。两者不重叠，也不互相替代。
    </p>
    <h3 id="gate-18">J18：写作前先定章纲</h3>
    <p>
      <code>router</code> 判定 ③ 里有这么一段：写作阶段若当前章章纲尚未生成，<b>先走
      <code>chapter_outline</code> 节点</b>，它结束后 <code>add_edge("chapter_outline", "gate")</code>
      再进门禁。于是顺序变成：
    </p>
    <pre>router → chapter_outline（生成第 N 章章纲）→ gate（就章纲与作者对齐）→ writing</pre>
    <p>
      不这样做的后果：门禁问的是"这一章你要写什么"，而此刻章纲还不存在，
      作者只能对着一个空章节回答"确认"——门禁就退化成一个<b>无意义的确认按钮</b>。
    </p>
    <h3 id="gate-19">润色是可选工序</h3>
    <pre><span class="c"># nodes.py · human_review 的 approve 分支</span>
<span class="k">if</span> stage == <span class="s">"reviewing"</span> <span class="k">and not</span> decision.get(<span class="s">"polish"</span>):
    nxt = STAGE_FLOW.get(<span class="s">"polishing"</span>)      <span class="c"># 跳过润色 → "_next_chapter"</span>
    updates[<span class="s">"messages"</span>] = [HumanMessage(content=<span class="s">"已跳过润色，本章直接定稿"</span>)]</pre>
    <p>
      跳过后正文 <code>status</code> 保持 <code>reviewed</code>，随时可以用「润色本章」补做。
      <b>强制每章都润色</b>会让一部 50 章的小说多出 50 次不必要的 LLM 调用与等待。
    </p>
  </div>
</section>
<!-- ===================== 05 interrupt ===================== -->
<section id="hitl">
  <div class="wrap">
    <div class="eyebrow">05 · Human-in-the-Loop</div>
    <h2 id="hitl">两类 interrupt：语义不同，机制相同</h2>
    <p class="lead">
      整个系统只有<b>两处</b>调用 <code>interrupt()</code>，它们对应两种完全不同的人工介入语义。
      搞清楚这个区别，就不会把"门禁确认"和"审核放行"混为一谈。
    </p>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th></th><th>阶段门禁 <code>kind="confirm"</code></th><th>人审 <code>kind="review"</code></th></tr></thead>
        <tbody>
          <tr><td><b>何时挂起</b></td><td>进入一个创作阶段<b>之前</b></td><td>每个阶段产物生成<b>之后</b></td></tr>
          <tr><td><b>作者看到什么</b></td><td>门禁卡：模板问题 + brief + 讨论历史</td><td>产物 + 审核问题 + 修改建议</td></tr>
          <tr><td><b>回答后</b></td><td><code>confirmed=True</code> → 放行进入阶段节点</td>
              <td><code>approve</code> / <code>modify</code> 推进阶段 / <code>reject</code> <b>直连本阶段节点重跑</b></td></tr>
          <tr><td><b>会不会重跑</b></td><td>不会（只是问，然后开始写）</td><td><b>会</b>——驳回即重跑本阶段</td></tr>
          <tr><td><b>确认要重新问吗</b></td><td><b>要</b>：按章/卷作用域，下一章会再问</td><td>不需要</td></tr>
        </tbody>
      </table>
    </div>
    <h3 id="hitl-21">① 阶段门禁的 interrupt</h3>
    <pre><span class="c"># nodes.py:1870 · stage_gate_node</span>
decision = interrupt({
    <span class="s">"kind"</span>: <span class="s">"confirm"</span>,
    <span class="s">"stage"</span>: stage,
    <span class="s">"round"</span>: round_no,
    <span class="s">"discussion_id"</span>: discussion_id,
    <span class="s">"brief"</span>: brief,
})</pre>
    <div class="note w"><b>⚠ 首轮 interrupt 不写 checkpoint，resume 必须回传 discussion_id</b><div>
      LangGraph 的 <code>interrupt()</code> 在<b>第一次</b>抛出时不会把状态落盘。
      所以 API 侧必须把 <code>discussion_id</code> 一起返回给前端，resume 时再带回来，
      否则门禁讨论会<b>断成两次无关的会话</b>，作者看到的历史凭空消失。
    </div></div>
    <h3 id="hitl-22">② 人审的 interrupt</h3>
    <pre><span class="c"># nodes.py:1544 · human_review_node</span>
decision = interrupt(payload)      <span class="c"># payload 含 content / issues / rejected_feedback / polish_candidate</span>
action = decision.get(<span class="s">"action"</span>, <span class="s">"approve"</span>)
modifications = decision.get(<span class="s">"modifications"</span>, {})</pre>
    <p>人审节点负责把<b>三种决策</b>翻译成State 更新：</p>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>action</th><th>效果</th></tr></thead>
        <tbody>
          <tr><td><code>approve</code></td><td>推进 <code>current_stage</code>（reviewing 未要求润色则跳过，直达下一章），交回 <code>router</code> 统一分发</td></tr>
          <tr><td><code>modify</code></td><td>把 <code>modifications</code> 里白名单字段（world_setting / character_settings / outline / chapters / foreshadow / project_meta / llm_config）过滤后写入，<b>并同样推进阶段</b>，不会驳回重跑</td></tr>
          <tr><td><code>reject</code></td><td>写 <code>review_issues[].rejected=True</code> + 修改理由，<b>直连本阶段节点重跑</b></td></tr>
          <tr><td><code>discard_polish</code></td><td>润色阶段：丢弃候选、保留原文（布尔字段，不单独占 action）</td></tr>
        </tbody>
      </table>
    </div>
    <h3 id="hitl-23">驳回为什么"直连本阶段"</h3>
    <pre><span class="c"># graph.py:75</span>
<span class="k">def</span> <span class="n">route_after_human_review</span>(state) -&gt; str:
    <span class="k">if</span> any(i.get(<span class="s">"rejected"</span>) <span class="k">for</span> i in state.get(<span class="s">"review_issues"</span>, [])):
        <span class="k">return</span> _node_for(current_stage)      <span class="c"># ← 直连，**不重复门禁**</span>
    <span class="k">if</span> current_stage == <span class="s">"_next_chapter"</span>:
        <span class="k">return</span> <span class="s">"next_chapter"</span>
    <span class="k">return</span> <span class="s">"router"</span></pre>
    <div class="note i"><b>💡 为什么驳回不重复门禁</b><div>
      门禁问的是"这一章要写什么"，<b>已经确认过了</b>。驳回的理由是"写出来不对"，
      该做的是<b>重写</b>，方向不用重新对齐。让作者在每次驳回后都被重新问一遍
      方向，是把"修改"和"重做"混为一谈。
    </div></div>
    <h3 id="hitl-24">修改要求怎么传到下一轮生成</h3>
    <pre><span class="c"># prompts.py:41 · _revision_feedback()（nodes.py:38 仅 import）</span>
<span class="k">return</span> (<span class="s">"【作者对上一版的修改要求——重新生成时必须逐条落实】\n"</span>
        + <span class="s">"\n"</span>.join(<span class="s">f"- {f}"</span> <span class="k">for</span> f <span class="k">in</span> feedbacks) + <span class="s">"\n\n"</span>)</pre>
    <p>
      没有这一段，驳回就<b>只是重跑一遍</b>——模型不知道作者不满什么，会生成一个几乎一样的版本。
      这段把"作者说了什么"变成下一轮 prompt 的一部分，闭环才成立。
    </p>
    <div class="note d"><b>✗ 一个真实的自我矛盾事故</b><div>
      设定参考区块声明"一律以此为准、不得改名"，而作者驳回理由是「月之森等学校没做国内适配」。
      <b>第 1 版</b>把高中改成「明心中学」、日元改成人民币；<b>第 2 版反而全部退回日文原名</b>。<br>
      原因是<b>两条指令冲突</b>，而模型选了<b>措辞更硬的一方</b>（"一律""不得"）。<br>
      修法见<a href="/agentnovel/rag">rag.html</a>：本轮存在作者修改要求时，把设定集<b>降级为参考</b>。
    </div></div>
  </div>
</section>
<!-- ===================== 06 流式 ===================== -->
<section id="streaming">
  <div class="wrap">
    <div class="eyebrow">06 · Streaming</div>
    <h2 id="streaming">流式输出：为什么要 <code>stream_mode=["updates","messages"]</code></h2>
    <div class="diagram">
      <div class="stack w-lg">
        <div class="box blue"><b>POST /run · /resume</b><small>graph.astream(Command(resume=…), config, stream_mode=[…])</small></div>
        <div class="link"><em>逐帧 NDJSON 写回 HTTP 响应</em><i></i></div>
        <div class="box"><b>messages 帧</b><small>LLM 增量 token → 右栏气泡逐字渲染</small></div>
        <div class="box"><b>updates 帧</b><small>哪个节点完成了 → 左栏状态推进 + 阶段提示</small></div>
        <div class="box ok"><b>前端合并</b><small>更新 state 并展示产出（正文/设定/章纲）</small></div>
      </div>
      <div class="cap">图 2 · 一次 run 的流式帧去向：两个 stream_mode 各管一件事</div>
    </div>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>stream_mode</th><th>产出什么</th><th>前端拿它做什么</th></tr></thead>
        <tbody>
          <tr><td><code>messages</code></td><td>LLM 的增量 token</td><td>右栏对话气泡<b>逐字</b>渲染，让人看到"正在写"</td></tr>
          <tr><td><code>updates</code></td><td>每个节点返回的 State 增量</td><td>推进阶段指示器、把新产物写进左栏</td></tr>
        </tbody>
      </table>
    </div>
    <h3 id="streaming-26">为什么不用 WebSocket</h3>
    <div class="note i"><b>💡 一个被约束逼出来的选择</b><div>
      <code>deploy/novelcraft-backend.service</code> 明确<b>禁止 <code>--workers &gt; 1</code></b>：
      日志序号缓存与防重写守卫都假定"同一日志仅本进程写入"。单进程下<b>一次性 HTTP 响应 + NDJSON 分块推送</b>
      （<code>application/x-ndjson</code>，<code>proxy_buffering off</code>）完全够用，
      而 WebSocket 会引入连接状态管理却换不来收益。<br>
      <b>推论</b>：任何"每个连接一份内存状态"的设计在本系统里都是不可行的——连接数上去就撑不住。
    </div></div>
    <h3 id="streaming-27">流式的一个已知坑</h3>
    <p>
      <code>_iter_ndjson</code> 取 <code>messages[-1]</code> 判断"已生成"，所以<b>提示消息必须放在
      "已生成"那条<b>之前</b></b>——否则提示会把收尾帧顶掉，前端就认为还在生成中。
    </p>
    <pre><span class="c"># nodes.py · writing_node 收尾</span>
<span class="k">if</span> word_count &gt; max_words:
    msgs.append(HumanMessage(content=<span class="s">f"注意：本章 {word_count} 字，超出目标…"</span>))   <span class="c"># ← 先</span>
msgs.append(HumanMessage(content=<span class="s">f"第 {current_idx+1} 章《{title}》已生成，{word_count} 字"</span>))  <span class="c"># ← 后</span></pre>
    <p>
      另外提示必须<b>明说可做什么</b>（"如篇幅不合适，可驳回重跑，或在设置→作品中调整单章目标字数"），
      否则只有一句"怎么写了这么多字"的困惑，没有可行的下一步。
    </p>
  </div>
</section>
<!-- ===================== 07 checkpoint ===================== -->
<section id="checkpoint">
  <div class="wrap">
    <div class="eyebrow">07 · Checkpoint</div>
    <h2 id="checkpoint">步级快照与自研 TiDB checkpointer</h2>
    <p class="lead">
      LangGraph 会在<b>每个节点结束后</b>自动存一份 State 快照。这件事在本系统里既是能力也是负担——
      它让时间旅行成为可能，代价是<b>存储与 GC 策略必须自己设计</b>。
    </p>
    <h3 id="checkpoint-29">为什么不能用官方 mysql checkpointer</h3>
    <div class="note d"><b>✗ TiDB 8.5 不支持它依赖的语法</b><div>
      <code>langgraph-checkpoint-mysql</code> 的 SELECT 依赖 MySQL 的 <code>JSON_TABLE()</code>，
      TiDB <b>直接报 1064</b>，整条读路径走不通；upsert 还用了
      <code>INSERT ... AS new</code> 别名语法，TiDB 同样不支持。<br>
      所以按 <code>langgraph.checkpoint.sqlite.SqliteSaver</code> 的语义<b>移植了一份</b>
      （<span class="path">app/storage/checkpointer.py</span>），SQL 全部换成 TiDB 支持的写法：
      <ul class="clean" style="font-size:14px;margin:8px 0 0">
        <li><code>INSERT OR REPLACE</code> → <code>REPLACE INTO</code></li>
        <li><code>INSERT OR IGNORE</code> → <code>INSERT IGNORE INTO</code></li>
        <li>metadata 过滤放<b>Python 侧</b>，避免依赖 <code>JSON_EXTRACT(BLOB, …)</code> 的隐式转换</li>
      </ul>
    </div></div>
    <div class="note i"><b>💡 checkpoint_id 的排序技巧</b><div>
      沿用 <code>ORDER BY checkpoint_id DESC</code>——LangGraph 的 checkpoint_id 是<b>时间序 UUID</b>，
      <b>字典序即时间序</b>，不需要额外的自增列。
    </div></div>
    <h3 id="checkpoint-30">保留策略：最近 20 个步级快照</h3>
    <div class="diagram">
      <div class="retain">
        <div class="z del"><b>删除</b>步级（非里程碑）<br>仅保留最近 20 个</div>
        <div class="z keep"><b>保留</b>里程碑快照<br>项目/分支起点 · 阶段切换 · 章节定稿<br>进入人审 · 全书完成 · 链头最新</div>
      </div>
      <div class="cap">图 3 · <span class="path">app/core/retention.py</span>：按 checkpoint 的<b>快照内容</b>（State values）分类——不依赖 metadata，对历史数据同样成立</div>
    </div>
    <p>
      不分里程碑地只留 20 个的话，一部 50 章小说早就把有意义的版本挤掉了；
      而<b>全都留着</b>又会让 checkpoint 表无限膨胀（实测单条 checkpoint 平均 14.4KB）。
      <b>按快照内容确定性推导</b>是唯一可行的折中——不写入时注入 metadata，因此对存量数据同样有效。<br>
      另外注意：门禁确认本身<b>不是</b>独立的里程碑类型；分支线程只有「起点」是里程碑，
      其余按普通步级处理，否则分支一续写就再也不会被清理。
    </p>
    <h3 id="checkpoint-31">同步 / 异步共用一份实现</h3>
    <pre><span class="c"># checkpointer.py 模块 docstring</span>
同步与异步共用一份实现：异步方法用 <span class="k">asyncio.to_thread</span> 转调同步实现，
连接由 <span class="n">app.storage.tidb</span> 的连接池统一供给。</pre>
    <p>
      图本身只有一份（<code>build_graph()</code>），<code>build_async_graph()</code> 只是为了贴合
      FastAPI <code>lifespan</code> 的调用方式留了个 <code>await</code> 形式。
      <b>不写两份实现</b>是这里的关键——否则同步路径（例如 CLI / 测试）就成了没人跑的分支。
    </p>
  </div>
</section>
<!-- ===================== 08 时间旅行 ===================== -->
<section id="timetravel">
  <div class="wrap">
    <div class="eyebrow">08 · Time Travel</div>
    <h2 id="timetravel">时间旅行：状态能退，但<b>向量库不会跟着退</b></h2>
    <p class="lead">
      这是全系统<b>最重要的一条已知裂缝</b>。State 能回到任意历史快照，但检索侧索引不在 State 里，
      于是回退之后"看到的正文"和"能搜到的正文"会不一致。
    </p>
    <h3 id="timetravel-33">能退到什么粒度</h3>
    <ul class="clean">
      <li><b>步级</b>：每个节点结束都有快照 → 可以退到"上一章写完但还没审核"这种中间态</li>
      <li><b>里程碑</b>：项目/分支起点、阶段切换、章节定稿（reviewed·polished）、进入人审等待、全书完成、链头最新，被长期保留</li>
    </ul>
    <h3 id="timetravel-34">回退时State 里到底变了什么</h3>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>数据</th><th>在 State 里？</th><th>回退后</th></tr></thead>
        <tbody>
          <tr><td>角色 / 世界观 / 伏笔设定</td><td style="color:var(--ok)">✓</td><td><b>一起退回</b>——版本化的价值所在</td></tr>
          <tr><td>章纲（两级结构）</td><td style="color:var(--ok)">✓</td><td>一起退回</td></tr>
          <tr><td>章节列表与状态</td><td style="color:var(--ok)">✓</td><td>一起退回</td></tr>
          <tr><td><b>章节正文</b></td><td style="color:var(--ok)">✓（<code>content_ref</code> 指针）</td>
              <td>指针退回，<b>正文版本也一起退</b>（H8 版本化）</td></tr>
          <tr><td><b>向量库索引</b></td><td style="color:var(--danger)">✗ 在 Qdrant</td>
              <td style="color:var(--danger)"><b>不跟着退</b></td></tr>
        </tbody>
      </table>
    </div>
    <h3 id="timetravel-35">为什么正文外置让这件事变可行</h3>
    <p>
      如果正文<b>直接存 State</b>，回退时LangGraph 会把整份 State（包括所有正文）写回快照，
      存储与写放大都不可接受。改成"State 只存 <code>content_ref</code> 指针、正文在 body store
      按 (chapter_id, version) 追加"之后，回退只需要改指针，<b>正文按版本天然对齐</b>：
    </p>
    <pre><span class="c"># app/storage/body_store.py</span>
<span class="c"># H8：正文按 (chapter_id, version) **追加**保存，历史版本保留，</span>
<span class="c">#     支持快照回退时正文随 content_ref 一并回滚</span>
<span class="c"># content_ref 格式："ch_0003@v7"</span></pre>
    <div class="note g"><b>✓ GC 也因此变得安全</b><div>
      <code>gc_versions()</code> 收集<b>所有现存快照 + 当前 State</b>里引用到的
      <code>content_ref</code> 并集，只删没被任何版本引用的行。
      也就是说<b>只要快照还在，对应版本的正文就一定在</b>。
    </div></div>
    <div class="note w"><b>⚠ 尚未闭合：向量库不参与回退</b><div>
      时间旅行只操作 checkpoint。<b>Qdrant 里的向量与 TiDB 的正文版本不在同一套回退机制里</b>，
      会出现"回退后 State 显示旧版正文，但检索仍能召回新版章节的块"。<br>
      检索侧另有<b>时偏置</b>缓解：<code>_bias_metadata</code> 会把最近 5 章的块提到前面，
      降低漂移造成的排序错乱，但<b>召回内容本身的不一致没有被消除</b>。
    </div></div>
  </div>
</section>
<!-- ===================== 09 State ===================== -->
<section id="state">
  <div class="wrap">
    <div class="eyebrow">09 · State</div>
    <h2 id="state">State 设计：业务数据与"本轮临时产物"分开</h2>
    <p class="lead">
      <code>NovelState</code>（<span class="path">app/core/state.py:325</span>）里 22 个字段，
      但它们分成<b>两类</b>，这个区分直接决定 checkpoint 大小与"用完即清"的那批字段怎么写。
    </p>
    <div class="g2">
      <div class="card ok">
        <span class="ico">📚</span><h4 id="state-37">业务数据（长期保留）</h4>
        <p><code>project_meta</code> <code>llm_config</code> <code>world_setting</code>
           <code>character_settings</code> <code>outline</code> <code>chapters</code>
           <code>foreshadow</code> <code>messages</code></p>
        <p><small>这些构成作品的真实内容，回退时要保住。</small></p>
      </div>
      <div class="card warn">
        <span class="ico">🧹</span><h4 id="state-38">本轮临时产物（用完清空）</h4>
        <p><code>retrieved_context</code> <code>retrieved_sources</code> <code>retrieval_stats</code>
           <code>chapter_research</code> <code>chapter_foreshadow_plan</code>
           <code>chapter_new_characters</code> <code>polish_candidate</code></p>
        <p><small>它们只服务于<b>下一次</b>节点调用，写完即清，不进历史快照。</small></p>
      </div>
    </div>
    <h3 id="state-39">"用完清空"是硬性要求</h3>
    <pre><span class="c"># nodes.py · writing_node 的返回</span>
<span class="k">return</span> {
    ...
    <span class="s">"retrieved_context"</span>: <span class="s">""</span>,           <span class="c"># 用完清空，不残留进 checkpoint</span>
    <span class="s">"retrieved_sources"</span>: citations,
    <span class="s">"retrieval_stats"</span>: retrieval_stats,
    <span class="s">"chapter_research"</span>: <span class="s">""</span>,            <span class="c"># 资料已注入本次 prompt</span>
}</pre>
    <p>
      <code>chapter_research</code> 是最长的一段（章纲阶段预取的资料，≤4000 字）。
      每章都留一份的话，50 章就是 20 万字的纯冗余——<b>它对下一章毫无用处</b>，
      因为下一章会重新预取自己的资料。
    </p>
    <h3 id="state-40">三个刻意不放进 State 的东西</h3>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>东西</th><th>放哪</th><th>为什么</th></tr></thead>
        <tbody>
          <tr><td>章节正文全文</td><td>TiDB <code>chapter_bodies</code></td><td>State 每次 checkpoint 都全量存，放不下（见 §11）</td></tr>
          <tr><td>检索向量</td><td>Qdrant</td><td>同上；且向量是<b>可重建</b>的派生物</td></tr>
          <tr><td>讨论日志 / 会话流</td><td>TiDB <code>sidecar_events</code></td>
              <td>旁路讨论<b>不写 checkpoint</b>（见 §14）</td></tr>
        </tbody>
      </table>
    </div>
    <h3 id="state-41"><code>stage_gate</code> 不在 PUT /state 白名单内</h3>
    <p>
      门禁状态<b>只由 <code>stage_gate_node</code> 写入</b>。把它排除在通用 state 更新接口之外，
      是为了防止前端一个误操作就把"已确认"改成未确认、或反过来绕过门禁。
    </p>
  </div>
</section>
<!-- ===================== 10 reducer ===================== -->
<section id="reducers">
  <div class="wrap">
    <div class="eyebrow">10 · Reducers</div>
    <h2 id="reducers">三类 reducer：覆盖、深合并、增量操作（外加 LangGraph 内置的 <code>add_messages</code>）</h2>
    <p class="lead">
      LangGraph 里节点返回的是<b>状态增量</b>，怎么合并由字段上的 <code>Annotated[…, reducer]</code> 决定。
      选错reducer 的后果通常是<b>静默丢数据</b>，所以这三个必须区分清楚。
    </p>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>reducer</th><th>语义</th><th>用在哪些字段</th></tr></thead>
        <tbody>
          <tr>
            <td><b>默认（无 reducer）</b></td>
            <td><b>整体覆盖</b></td>
            <td><code>outline</code>（卷/章两级，可整体覆盖）、所有标量字段</td>
          </tr>
          <tr>
            <td><code>merge_dict</code></td>
            <td><b>逐键深合并</b>，未提及的键保持原值</td>
            <td><code>project_meta</code> <code>llm_config</code> <code>world_setting</code></td>
          </tr>
          <tr>
            <td><code>apply_ops</code></td>
            <td><b>按 ops 增删改排序</b></td>
            <td><code>character_settings</code> <code>chapters</code> <code>foreshadow</code></td>
          </tr>
          <tr>
            <td><code>add_messages</code></td>
            <td><b>追加并按 id 去重</b></td>
            <td><code>messages</code></td>
          </tr>
        </tbody>
      </table>
    </div>
    <h3 id="reducers-43">列表字段为什么需要 <code>apply_ops</code></h3>
    <p>
      节点只会返回<b>它改动的那几条</b>。若用默认覆盖语义，返回 <code>[新角色]</code> 会把
      已有角色全清掉。所以 <code>apply_ops</code> 让节点返回操作列表：
    </p>
    <pre><span class="c"># nodes.py · 章节变更走ops 通道</span>
<span class="s">"chapters"</span>: {<span class="s">"ops"</span>: [{<span class="s">"op"</span>: <span class="s">"upsert"</span>, <span class="s">"item"</span>: chapter}]}</pre>
    <p>这让「多个节点/接口改同一份列表」变成可能，且互不覆盖：</p>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>op</th><th>作用</th></tr></thead>
        <tbody>
          <tr><td><code>upsert</code></td><td>按 id 存在则更新，否则插入</td></tr>
          <tr><td><code>delete</code></td><td>按 id 删除</td></tr>
          <tr><td><code>reorder</code></td><td>调整顺序（设定中心的上移/下移）</td></tr>
        </tbody>
      </table>
    </div>
    <div class="note w"><b>⚠ <code>outline</code> 为什么反而用覆盖</b><div>
      大纲是<b>一次性整体产出</b>的结构（一次生成一个卷 + 若干章），不逐条追加。
      覆盖语义正好匹配"这次生成的大纲整体替换"。
      真正需要的是<b>卷内增删章</b>——那走章纲阶段的 <code>chapter_outline</code> 节点单独 upsert。
    </div></div>
    <h3 id="reducers-44">踩过的坑</h3>
    <div class="note d"><b>✗ 生成失败会把设定清空</b><div>
      此前人设阶段生成失败时，节点仍返回 <code>"character_settings": []</code>（覆盖语义），
      于是<b>设定中心变成空角色页</b>，而模型只是偶尔失败一次。<br>
      修法：失败时<b>不返回该字段</b>，让它保持原值——<code>merge_dict</code> / <code>apply_ops</code>
      的价值正在于此。
    </div></div>
  </div>
</section>
<!-- ===================== 11 正文外置 ===================== -->
<section id="body">
  <div class="wrap">
    <div class="eyebrow">11 · Body Store</div>
    <h2 id="body">正文外置：H3 / H8 是整个时间旅行能成立的前提</h2>
    <div class="vs">
      <div class="card warn">
        <h4 id="body-46">正文进 State</h4>
        <p>每章 6000 字 × 50 章 = 30 万字。<b>每个 checkpoint 都全量存一份</b>，
        写放大随章节数平方增长；而且回退时无法精确控制"退到哪一版正文"。</p>
      </div>
      <div class="mid">→</div>
      <div class="card ok">
        <h4 id="body-47">正文外置（H3）</h4>
        <p>State 只存 <code>content_ref = "ch_0003@v7"</code> 指针，
        正文在 TiDB 按 <code>(chapter_id, version)</code> <b>追加</b>（H8）。
        快照小、回退精确、GC 安全。</p>
      </div>
    </div>
    <h3 id="body-48">版本化约定</h3>
    <pre><span class="c"># app/storage/body_store.py</span>
H8：正文按 (chapter_id, version) **追加**保存，覆盖写会丢历史；快照回退时正文随content_ref 一并回滚。
content_ref 格式："{chapter_id}@v{version}"（如 ch_0003@v7）；
历史遗留的无版本指针（裸 chapter_id）仍可读，指向 version=0 的基线行。</pre>
    <h3 id="body-49">读取的三级回退链</h3>
    <pre><span class="c"># body_store.get()</span>
<span class="s">"{cid}@v{N}"</span>  →读vN   <span class="c"># ① 正常路径</span>
       <span class="k">if</span> missing → 读 v0<span class="c"># ② H3 兼容基线</span>
       <span class="k">if</span> missing → 读 max(v)<span class="c"># ③ 宁可降级，不可丢稿</span></pre>
    <div class="note i"><b>💡 ③ 这一级为什么必要</b><div>
      目标版本的正文可能已被 GC，或 <code>content_ref</code> 指向了一个被删除的版本。
      拿到<b>一个旧版本</b>远好过拿到空——空会让写作节点把整章当成"没写过"，
      从而重新生成，把作者的稿子覆盖掉。<b>降级优于失败</b>是这里的设计原则。
    </div></div>
    <h3 id="body-50">与检索侧的配合</h3>
    <p>
      章节正文在Qdrant 里另有一份<b>切块后的副本</b>（<code>payload["_text"]</code>）。
      两者是<b>不同形态、不同用途</b>的同一份内容：
    </p>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th></th><th>body_store（TiDB）</th><th>Qdrant <code>_text</code></th></tr></thead>
        <tbody>
          <tr><td>形态</td><td>整章全文</td><td>切块 + 前缀富化（≤500 字/块）</td></tr>
          <tr><td>用途</td><td>回退、导出、快照</td><td>检索命中后直接拼 prompt</td></tr>
          <tr><td>权威性</td><td style="color:var(--ok)">✓ 权威</td><td style="color:var(--danger)">派生，可重建</td></tr>
          <tr><td>时序</td><td>H8 追加多版本</td><td>只保留<b>定稿</b>版本（见 §14）</td></tr>
        </tbody>
      </table>
    </div>
  </div>
</section>
<!-- ===================== 12 踩坑 ===================== -->
<section id="traps">
  <div class="wrap">
    <div class="eyebrow">12 · Traps</div>
    <h2 id="traps">踩过的坑：六条写在这里的规则</h2>
    <p class="lead">
      每一条都对应一次真实故障，且<b>都有一个共同特征：日志里看不到明显错误</b>。
    </p>
    <ol class="steps">
      <li><b>路由函数不能改 State</b><span>
        J25 的「继续创作毫无反应」：<code>router</code> 判定了目标阶段却只能 <code>return</code>，
        <code>current_stage</code> 仍是 <code>completed</code>。必须借 <code>recover</code> 节点写回。
        <b>判断与改状态不能在同一函数里。</b></span></li>
      <li><b>节点名不能与 State 键同名</b><span>
        LangGraph 限制。所以 State 字段叫 <code>stage_gate</code>，节点叫 <code>gate</code>；
        阶段名 <code>character</code> 对应的节点叫 <code>character_gen</code>。
        这也是 <code>STAGE_TO_NODE</code> 这张映射表存在的原因。</span></li>
      <li><b>流转表只能有一份</b><span>
        J25 之前分卷推进判定在 <code>graph.py</code> 和 <code>next_chapter_node</code> 各存一份，
        口径漂移导致完成态判断不一致。现在统一放 <code>nodes.py</code>，<code>graph.py</code> 单向 import。</span></li>
      <li><b>interrupt 首轮不写 checkpoint</b><span>
        <code>discussion_id</code> 必须由 API 回传给前端、resume 时带回，否则门禁讨论断成两次无关会话。</span></li>
      <li><b>流式提示的顺序有讲究</b><span>
        <code>_iter_ndjson</code> 取 <code>messages[-1]</code> 判"已生成"，
        所以「篇幅超标」这类提示必须放在"已生成"<b>之前</b>，否则提示会顶掉收尾帧。</span></li>
      <li><b>失败时不要返回该字段</b><span>
        覆盖语义下返回 <code>[]</code> 就等于清空。人设生成失败曾把设定中心清成空白。
        <b>不返回 = 保持原值</b>，这正是 reducer 的价值。</span></li>
    </ol>
    <div class="note d"><b>✗ 一个共同特征</b><div>
      六条里有五条的失败表现是<b>「界面没反应」或「界面显示为空」</b>，不会抛异常。
      因为状态机把控制流藏在数据结构里，<b>错误不会自己浮出来</b>——这也是本文档存在的理由。
    </div></div>
  </div>
</section>
<!-- ===================== 13 短板 ===================== -->
<section id="limits">
  <div class="wrap">
    <div class="eyebrow">13 · Known Limits</div>
    <h2 id="limits">已知短板：写在这里，免得被踩到</h2>
    <div class="g2">
      <div class="card danger">
        <span class="ico">⏳</span><h4 id="limits-53">向量库不参与时间旅行</h4>
        <p>回退 State 不会回退 Qdrant。可能出现"界面显示旧版正文，但检索仍能召回新版章节的块"。
        检索侧的<b>时间偏置</b>（把最近 5 章提前）只缓解排序漂移，<b>没有消除内容不一致</b>。</p>
        <p><small>这是当前<b>最需要补</b>的一环。</small></p>
      </div>
      <div class="card warn">
        <span class="ico">🔁</span><h4 id="limits-54">单进程约束</h4>
        <p><code>--workers &gt; 1</code> 被明确禁止（日志序号缓存 + 防重写守卫）。
        好处是流式与日志都简单；代价是<b>没有水平扩展能力</b>，
        且任何"每连接一份内存状态"的设计都不可行。</p>
      </div>
      <div class="card warn">
        <span class="ico">📝</span><h4 id="limits-55">审核一致性靠模型自查</h4>
        <p><code>reviewing</code> 让 LLM 输出 <code>ReviewIssue</code>，
        <b>没有规则引擎、没有 NLI 硬校验</b>。伏笔回收靠"未回收伏笔进检索 query"被动防漏。
        系统的保证是「作者有机会看到并否决」，「问题一定被找全」则是奢望。</p>
      </div>
      <div class="card warn">
        <span class="ico">🗑️</span><h4 id="limits-56">GC 会真删数据</h4>
        <p><code>gc_versions</code> 回收未被任何快照引用的正文版本。
        若某些 checkpoint 已被 20 条保留策略淘汰，其对应的正文版本可能被 GC——
        <b>那一版就再也回不去了</b>。两者必须协同设计，不能各自独立改。</p>
      </div>
      <div class="card warn">
        <span class="ico">📚</span><h4 id="limits-57">State 字段在膨胀</h4>
        <p>22 个字段里已有若干"临时产物"靠约定清空。这个约定<b>没有机制保证</b>：
        漏清一个字段只会让快照慢慢变大，不会有任何报错。</p>
      </div>
      <div class="card warn">
        <span class="ico">🔌</span><h4 id="limits-58">阶段名与节点名双轨</h4>
        <p><code>STAGE_TO_NODE</code> / <code>NODE_TO_STAGE</code> 是手写映射。
        加一个阶段要同时改三处（这张表、<code>STAGE_FLOW</code>、<code>NODES</code>），
        <b>漏改</b>的表现是阶段流转到不存在的节点。</p>
      </div>
    </div>
    <h3 id="limits-59">如果要补，优先级建议</h3>
    <div class="steps">
      <li><b>让向量库参与回退</b><span>在 <code>reindex</code> 时以 checkpoint 的章节版本为准重建索引；
        或给向量点带上 <code>content_ref</code> 版本号，检索时按当前 State 过滤。</span></li>
      <li><b>一致性升级为结构化校验</b><span>人物出场表、时间线冲突、伏笔状态机的<b>规则检查</b>，
        比"让模型自查"可靠得多。这是最薄弱也最能拉开差距的一环。</span></li>
      <li><b>用配置驱动替换手写映射</b><span>把阶段定义收进一份声明式配置（阶段名 → 节点名 → 门禁策略 → 下一阶段），
        三张表合一。</span></li>
    </div>
  </div>
</section>
<!-- ===================== 14 代码地图 ===================== -->
<section id="ref">
  <div class="wrap">
    <div class="eyebrow">14 · Reference</div>
    <h2 id="ref">代码地图与速查</h2>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>文件</th><th>职责</th><th>关键符号</th></tr></thead>
        <tbody>
          <tr>
            <td><span class="path">app/core/graph.py</span><br><small>156 行</small></td>
            <td>全图接线：节点注册、条件边、编译</td>
            <td><code>build_graph</code> <code>build_async_graph</code> <code>router</code>
                <code>route_after_gate</code> <code>route_after_human_review</code>
                <code>STAGE_TO_NODE</code></td>
          </tr>
          <tr>
            <td><span class="path">app/core/state.py</span><br><small>438 行</small></td>
            <td>State 定义、reducer、初始状态</td>
            <td><code>NovelState</code> <code>merge_dict</code> <code>apply_ops</code>
                <code>create_initial_state</code></td>
          </tr>
          <tr>
            <td><span class="path">app/core/nodes.py</span><br><small>2008 行</small></td>
            <td>12 个节点 + 流转表</td>
            <td><code>NODES</code> <code>STAGE_FLOW</code> <code>STAGE_GATES</code>
                <code>stage_gate_node</code> <code>human_review_node</code>
                <code>writing_node</code> <code>_index_approved_chapter</code></td>
          </tr>
          <tr>
            <td><span class="path">app/storage/checkpointer.py</span><br><small>343 行</small></td>
            <td>TiDB checkpointer（同步 / 异步共用一份实现）</td>
            <td><code>get_saver</code> <code>TiDBSaver</code></td>
          </tr>
          <tr>
            <td><span class="path">app/storage/body_store.py</span><br><small>243 行</small></td>
            <td>正文外置 + 版本化 + GC</td>
            <td><code>body_store</code> <code>parse_ref</code> <code>put_version</code>
                <code>gc_versions</code></td>
          </tr>
          <tr>
            <td><span class="path">app/core/retention.py</span></td>
            <td>checkpoint 保留策略（里程碑 vs 步级 20）</td>
            <td><code>cleanup_thread_checkpoints</code> <code>retain_checkpoint_ids</code>
                <code>classify_snapshot</code></td>
          </tr>
          <tr>
            <td><span class="path">app/api/routers/creation.py</span></td>
            <td><code>/run</code> <code>/resume</code> 与 NDJSON 流式帧</td>
            <td><code>run_project</code> <code>resume_question</code> <code>_iter_ndjson</code></td>
          </tr>
          <tr>
            <td><span class="path">app/api/routers/chapters.py</span></td>
            <td>正文版本列表 / 回退（时间旅行在正文侧的落地接口）</td>
            <td><code>list_chapter_versions</code> <code>restore_chapter_version</code></td>
          </tr>
          <tr>
            <td><span class="path">app/api/routers/branches.py</span></td>
            <td>分支：从快照派生 / 对比 / 合并</td>
            <td><code>create_branch</code>（<code>from_snapshot_id</code>）<code>merge_branch</code></td>
          </tr>
        </tbody>
      </table>
    </div>
    <h3 id="ref-61">关键常量</h3>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>常量</th><th>值</th><th>含义</th></tr></thead>
        <tbody>
          <tr><td><code>STAGE_GATES</code></td><td>4 个阶段</td><td>需要「先对齐再创作」的阶段</td></tr>
          <tr><td><code>GATE_MAX_ROUNDS</code></td><td><code>5</code></td><td>门禁轮次<b>软</b>上限，只提示不强制</td></tr>
          <tr><td><code>settings.checkpoint_keep_recent</code></td><td><code>20</code></td><td>步级快照保留数（env 可调，里程碑不参与淘汰）</td></tr>
          <tr><td><code>MAX_RESEARCH_CHARS</code></td><td><code>4000</code></td><td>章纲阶段预取资料的注入上限</td></tr>
          <tr><td><code>PREV_TAIL_CHARS</code></td><td><code>1200</code></td><td>上一章结尾原文直塞长度</td></tr>
        </tbody>
      </table>
    </div>
    <h3 id="ref-62">改代码前必读的三条不变量</h3>
    <div class="note d"><b>✗ 动 <code>graph.py</code> / <code>nodes.py</code> 前先确认</b><div>
      <b>① 阶段流转只能有一份定义</b>：<code>STAGE_FLOW</code> / 分卷推进判定都在
      <code>nodes.py</code>。<b>在 graph.py 里再写一份就是漂移的开始。</b><br><br>
      <b>② 路由函数是纯函数</b>：需要改 State 就必须新增一个真节点，
      不能在 <code>add_conditional_edges</code> 的函数里写 State。<br><br>
      <b>③ 阶段节点必须无条件连到 <code>human_review</code></b>：
      这是「所有产物都要人审」的<b>唯一保障点</b>，靠业务代码自觉会漏。
    </div></div>
  </div>
</section>
</div>
