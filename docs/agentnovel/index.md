---
title: NovelCraft AI · 系统设计与实现详解
description: NovelCraft AI 系统设计与实现详解：一套基于 LangGraph 的智能小说创作系统——整体架构、技术栈、创作引擎、人在回路、存储与检索、部署与设计权衡。
outline: [2, 3]
---
<div class="an-doc">
<header class="hero">
  <div class="wrap">
    <div class="eyebrow">System Design · Implementation Notes</div>
    <h1 id="把跟-llm-聊天写小说变成一条可控的创作流水线">把「跟 LLM 聊天写小说」<br>变成一条可控的创作流水线</h1>
    <p class="lead">
      NovelCraft AI 是一套基于 LangGraph 的智能小说创作系统。它的价值在于解决长篇创作中三个真正致命的问题——
      底层模型与你直接聊天时完全一样：
      <b>上下文会爆</b>、<b>历史改不动</b>、<b>一致性保不住</b>。
    </p>
    <div class="badges">
      <span class="badge">Python 3.11 · FastAPI</span>
      <span class="badge">LangGraph 状态机</span>
      <span class="badge">React 19 · Vite 7</span>
      <span class="badge">TiDB Cloud</span>
      <span class="badge">Qdrant 向量库</span>
      <span class="badge">人在回路 HITL</span>
    </div>
    <div class="stats">
      <div class="stat"><b>6 阶段</b><small>创作流程状态机</small></div>
      <div class="stat"><b>2 类</b><small>挂起中断 interrupt</small></div>
      <div class="stat"><b>步级</b><small>checkpoint 粒度</small></div>
      <div class="stat"><b>20</b><small>步级快照保留数</small></div>
      <div class="stat"><b>8 个</b><small>前端页面</small></div>
      <div class="stat"><b>11 个</b><small>后端路由模块</small></div>
    </div>
  </div>
</header>
<!-- ===================== 01 架构 ===================== -->
<section id="arch">
  <div class="wrap">
    <div class="eyebrow">01 · Architecture</div>
    <h2 id="arch">系统总览</h2>
    <p class="lead">
      生产环境由三部分构成：<b>Nginx</b> 托管前端静态资源并反代 API，<b>FastAPI + LangGraph</b> 承担全部业务逻辑，
      <b>TiDB / Qdrant / LLM API</b> 作为外部依赖。三者缺一不可——TiDB 是唯一的业务存储，<b>没有本地回退</b>。
    </p>
    <div class="diagram">
      <div class="stack">
        <div class="box w-sm">
          <b>浏览器 · 作者工作台</b>
          <small>三栏工作台：大纲 / 编辑器 / AI 会话面板</small>
        </div>
        <div class="link"><em>HTTPS</em><i></i></div>
        <div class="box w-md blue">
          <b>Nginx　80 / 443</b>
          <small>静态资源 dist　·　/api 反向代理（proxy_buffering off）</small>
        </div>
        <div class="link"><em>127.0.0.1:3000</em><i></i></div>
        <div class="box w-lg mark">
          <b>FastAPI + Uvicorn（--loop asyncio）</b>
          <small>LangGraph 状态机　·　流式 NDJSON 事件　·　JWT 鉴权　·　11 个路由模块</small>
        </div>
        <div class="link"><em>三类外部依赖</em><i></i></div>
        <div class="cols3">
          <div class="svc">
            <b>TiDB Cloud</b>
            <small>checkpoints / writes<br>chapter_bodies / sidecar_events</small>
            <span class="tag warn">唯一业务存储，无回退</span>
          </div>
          <div class="svc">
            <b>Qdrant</b>
            <small>设定 / 角色 / 伏笔<br>章节正文 / 上传文档</small>
            <span class="tag ok">无 key 时降级本地</span>
          </div>
          <div class="svc">
            <b>LLM API</b>
            <small>默认 SiliconFlow<br>DeepSeek-V3.2</small>
            <span class="tag gray">9 家供应商可切换</span>
          </div>
        </div>
      </div>
      <div class="cap">图 1 · 生产部署架构：Nginx → FastAPI / LangGraph → 三个外部依赖</div>
    </div>
    <div class="note w"><b>⚠</b><div>外部依赖里 TiDB（<code>gateway01.ap-northeast-1.prod.aws.tidbcloud.com:4000</code>）与
      Qdrant（<code>us-east-1</code>）都在<b>境外</b>，默认 LLM 供应商 SiliconFlow 在境内。跨境链路要验证的是前两者——
      尤其是 TiDB，它一旦不通，服务<b>启动即失败</b>，没有任何降级路径。</div></div>
  </div>
</section>
<!-- ===================== 02 技术栈 ===================== -->
<section id="stack">
  <div class="wrap">
    <div class="eyebrow">02 · Tech Stack</div>
    <h2 id="stack">技术栈</h2>
    <p class="lead">后端重编排与持久化，前端重编辑体验与流式呈现。</p>
    <div class="grid g2">
      <div class="card">
        <h4 id="stack-3">后端 <code>novelcraft/</code></h4>
        <div class="tbl-wrap" style="margin:8px 0 0">
          <table style="min-width:0">
            <tbody>
              <tr><th>语言</th><td>Python 3.11+</td></tr>
              <tr><th>Web</th><td>FastAPI + Uvicorn</td></tr>
              <tr><th>编排</th><td>LangGraph ≥0.3 / LangChain</td></tr>
              <tr><th>业务存储</th><td>TiDB Cloud（MySQL 兼容）</td></tr>
              <tr><th>向量库</th><td>Qdrant（云端 / 本地降级）</td></tr>
              <tr><th>Embedding</th><td>bge-m3（1024 维，走 API）</td></tr>
              <tr><th>鉴权</th><td>PyJWT + bcrypt</td></tr>
            </tbody>
          </table>
        </div>
      </div>
      <div class="card">
        <h4 id="stack-4">前端 <code>frontend/</code></h4>
        <div class="tbl-wrap" style="margin:8px 0 0">
          <table style="min-width:0">
            <tbody>
              <tr><th>框架</th><td>React 19 + TypeScript</td></tr>
              <tr><th>构建</th><td>Vite 7（SWC 插件）</td></tr>
              <tr><th>样式</th><td>Tailwind CSS 4 + shadcn/ui</td></tr>
              <tr><th>状态</th><td>Zustand</td></tr>
              <tr><th>请求</th><td>Axios + TanStack Query</td></tr>
              <tr><th>流式</th><td>fetch ReadableStream 解析 NDJSON</td></tr>
              <tr><th>编辑器</th><td>CodeMirror 6（Markdown）</td></tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    <h3 id="stack-5">为什么流式用 NDJSON</h3>
    <p>创作接口返回 <code>application/x-ndjson</code>，每行一个 JSON 事件。选它是为了解决三个具体问题：</p>
    <ul class="clean">
      <li><b>多目标分流</b>：同一条流要同时推送「正文 token」「审核报告」「润色对比」「引用卡」「阶段切换」，NDJSON 天然支持异构事件混排。</li>
      <li><b>逐字打印</b>：token 增量用 <code>delta</code> 事件按目标分发——<code>editor</code> 中间栏正文、<code>review</code> 独立审核页、<code>polish</code> 润色对比右栏、<code>artifact</code> 阶段产物视图。</li>
      <li><b>代理友好</b>：相比 SSE，NDJSON 就是普通 HTTP 响应体，Nginx 关掉 <code>proxy_buffering</code> 即可透传。</li>
    </ul>
    <div class="note w"><b>◈</b><div>启动后端时 <code>--loop asyncio</code> 不能省：uvloop 在信号打断时会命中
      <code>Assertion 'errno == EINTR' failed</code> 直接 abort，导致收到 SIGTERM 时崩溃退出，做不到优雅关闭。</div></div>
  </div>
</section>
<!-- ===================== 03 创作引擎 ===================== -->
<section id="graph">
  <div class="wrap">
    <div class="eyebrow">03 · Creation Engine</div>
    <h2 id="graph">创作引擎：LangGraph 状态机</h2>
    <p class="lead">
      创作引擎是一张编译过的状态图。六个创作阶段依次推进，
      每个阶段产出后统一进入人工审核，通过后再由 router 分发到下一阶段。
    </p>
    <div class="diagram">
      <div class="flow">
        <div class="node gate">worldbuilding<small>世界观</small></div>
        <span class="arw"></span>
        <div class="node gate">character_gen<small>人设</small></div>
        <span class="arw"></span>
        <div class="node gate">outline_gen<small>卷纲</small></div>
        <span class="arw"></span>
        <div class="node gate">writing<small>撰写正文</small></div>
        <span class="arw"></span>
        <div class="node soft">reviewing<small>AI 审核</small></div>
        <span class="arw"></span>
        <div class="node soft">polishing<small>润色 · 可选</small></div>
        <span class="arw faint"></span>
        <div class="node plain">next_chapter<small>下一章</small></div>
      </div>
      <div class="flow-bar">
        <b>human_review · 每个阶段产出后统一进入</b>
        <small>approve 通过　·　modify 白名单改字段　·　reject 驳回并携带意见重跑</small>
      </div>
      <div class="flow-router">
        <span class="chip">router</span>
        <p>通过 → 回 router 统一分发到下一阶段；驳回 → 直连当前阶段节点重跑（不重复门禁）</p>
      </div>
      <div class="cap">图 2 · 创作状态机：橙色节点进入前需与作者对齐确认；reviewing / polishing 不设门禁。图中画的是<b>节点名</b>——阶段 <code>character</code> / <code>outline</code> 对应的节点叫 <code>character_gen</code> / <code>outline_gen</code>（见下节约束③）</div>
    </div>
    <h3 id="graph-7">三条图结构上的关键约束</h3>
    <div class="grid g3">
      <div class="card accent">
        <span class="ico">①</span>
        <h4 id="graph-8">router 是唯一分发点</h4>
        <p>覆盖<b>首次进入 / 阶段推进 / 下一章 / 完成态恢复</b>四条路径，门禁才能无遗漏。早期版本中 <code>human_review</code> 与 <code>next_chapter</code> 直连阶段节点绕过 router，导致门禁插不进去。</p>
      </div>
      <div class="card accent">
        <span class="ico">②</span>
        <h4 id="graph-9">驳回不重复门禁</h4>
        <p>驳回走<b>直连</b>回到当前阶段节点重跑；只有「通过」才回 router。已经对齐过的事不该再问一遍作者。</p>
      </div>
      <div class="card accent">
        <span class="ico">③</span>
        <h4 id="graph-10">节点名 ≠ State 键</h4>
        <p>LangGraph 限制两者不能同名，所以节点叫 <code>gate</code>，而它写入的 State 字段叫 <code>stage_gate</code>。</p>
      </div>
    </div>
    <h3 id="graph-11">J18：写作前先出章纲</h3>
    <p>普通做法是「正文和章纲一起生成」。本系统在 <code>writing</code> 之前插了专门的 <code>chapter_outline</code> 节点：</p>
    <div class="steps">
      <li><b>router 检查</b><span>当前章没有章纲 → 先走 <code>chapter_outline</code> 生成章纲，并预取本章写作资料</span></li>
      <li><b>进门禁</b><span>作者先就<b>章纲</b>讨论确认，此时正文还没有开始写</span></li>
      <li><b>确认后才动笔</b><span>确认写入 <code>stage_gate.confirmed</code>，router 据此放行到 <code>writing</code></span></li>
    </div>
    <div class="note g"><b>✓</b><div>改一章<b>纲</b>的成本远低于改一章正文。把人工介入点前移到动笔之前，等于把最贵的返工提前拦截。</div></div>
  </div>
</section>
<!-- ===================== 04 人在回路 ===================== -->
<section id="hitl">
  <div class="wrap">
    <div class="eyebrow">04 · Human-in-the-Loop</div>
    <h2 id="hitl">人在回路：interrupt 与 Command</h2>
    <p class="lead">
      整套交互建立在 LangGraph 的两个原语上：<code>interrupt(payload)</code> 挂起、<code>Command(resume=…)</code> 恢复。
      理解「恢复时节点会从头重放」这一点，就理解了全部代码写法。
    </p>
    <div class="note i"><b>◈ 核心语义</b><div>
      恢复时节点函数<b>重新执行一遍</b>，直到再次运行到 <code>interrupt()</code> 那一行——第二次调用直接返回注入的决策，不再抛异常。<br>
      推论：<b>所有跨轮状态只能存在两个地方</b>——State 字段，或 resume 回传的数据。
      这就是为什么轮次要写成 <code>gate["round"] + 1</code>、为什么 <code>discussion_id</code> 必须让前端原样回传。
    </div></div>
    <h3 id="hitl-13">三类挂起点（实际只有两个在用）</h3>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>kind</th><th>触发节点</th><th>时机</th><th>恢复接口</th><th>决策动作</th></tr></thead>
        <tbody>
          <tr><td><code>confirm</code></td><td><code>gate</code><br><small>State 字段叫 <code>stage_gate</code></small></td><td>进入 世界观 / 人设 / 大纲 / 撰写 之前</td><td><code>POST /resume</code></td><td>confirm 放行 / revise 自环</td></tr>
          <tr><td><code>review</code></td><td><code>human_review</code></td><td>每个阶段产出之后</td><td><code>POST /review</code></td><td>approve / modify / reject</td></tr>
          <tr><td><code>question</code></td><td colspan="4"><small>保留兼容代码：<code>interrupt_question_event</code> 与 <code>/resume</code> 的 <code>action=answer</code> 分支都还在，但<b>没有任何节点发出 <code>kind=question</code></b>。挂起点实际只有上面两个。</small></td></tr>
        </tbody>
      </table>
    </div>
    <p><b>reviewing / polishing 不设门禁</b>——它们是对产物的加工，再拦一次会让作者每章确认五次。</p>
    <h3 id="hitl-14">一次「写第 N 章」的完整时序</h3>
    <div class="diagram">
      <ul class="tl">
        <li>
          <div class="from">前端 → API</div>
          <div class="txt">① <b>POST /run</b> 启动创作，返回 NDJSON 流</div>
        </li>
        <li>
          <div class="from">API → 图</div>
          <div class="txt">② <b>astream</b> 驱动状态机（updates + messages 双模式）</div>
        </li>
        <li>
          <div class="from">图 → 外部服务</div>
          <div class="txt">③ RAG 检索设定与伏笔，随后调用 LLM 生成</div>
        </li>
        <li class="alt">
          <div class="from cyan">图 → 前端</div>
          <div class="txt">④ <b>delta 事件</b>：正文 token 逐字流入编辑器（按 target 分流）</div>
        </li>
        <li class="bar">
          <div class="from amber">图（挂起）</div>
          <div class="txt">⑤ <b>interrupt()</b> 暂停，checkpoint 落 TiDB</div>
        </li>
        <li>
          <div class="from">API → 前端</div>
          <div class="txt">⑥ 下发 <b>confirm / review 卡</b>（含 brief、issues、产出内容）</div>
        </li>
        <li class="alt">
          <div class="from cyan">前端 → API</div>
          <div class="txt">⑦ <b>POST /discuss</b> 可来回 N 轮 —— <b>旁路通道，不写 checkpoint、不进 State</b></div>
        </li>
        <li>
          <div class="from">前端 → API</div>
          <div class="txt">⑧ <b>POST /resume</b> 提交决策（confirm / revise / answer）</div>
        </li>
        <li>
          <div class="from">API → 图</div>
          <div class="txt">⑨ <b>Command(resume=…)</b> 恢复执行</div>
        </li>
        <li class="alt">
          <div class="from cyan">图</div>
          <div class="txt">⑩ 节点<b>重放</b>：<code>interrupt()</code> 这一行直接返回决策，不再抛异常</div>
        </li>
        <li>
          <div class="from">图 → 外部服务</div>
          <div class="txt">⑪ 按决策撰写正文 / 登记伏笔与新角色</div>
        </li>
        <li class="alt">
          <div class="from cyan">图 → 前端</div>
          <div class="txt">⑫ 继续输出 delta，直到下一个 interrupt 或结束</div>
        </li>
        <li class="bar">
          <div class="from amber">图（收尾）</div>
          <div class="txt">⑬ 流结束 → 异步维护：checkpoint 保留 + 正文版本 GC + 会话日志轮转</div>
        </li>
      </ul>
      <div class="cap">图 3 · 蓝点 = 数据流，橙点 = 挂起 / 状态边界，蓝紫点 = 旁路讨论</div>
    </div>
    <h3 id="hitl-15">门禁的作用域：按章 / 按卷</h3>
    <p>为解决「每章都被反复询问」的烦人感，门禁确认是<b>带作用域</b>的：</p>
    <div class="vs">
      <div class="card accent">
        <h4 id="hitl-16">writing → 按<b>章</b></h4>
        <p>第 5 章确认过不影响第 6 章重新确认；但第 5 章内反复「继续」不会被拦。</p>
      </div>
      <div class="mid">VS</div>
      <div class="card accent">
        <h4 id="hitl-17">outline → 按<b>卷</b></h4>
        <p>本卷的计划章数、结局走向确认一次即可，不必每章重问。</p>
      </div>
    </div>
    <h3 id="hitl-18">payload 必须从 interrupt 任务里取</h3>
    <p>首轮 interrupt 的 payload <b>不落 checkpoint</b>，只读 <code>state.values</code> 会拿到空：</p>
    <pre>intr_payload = {}
<span class="k">for</span> t <span class="k">in</span> (getattr(state, <span class="s">"tasks"</span>, <span class="k">None</span>) <span class="k">or</span> []):
    <span class="k">for</span> i <span class="k">in</span> (getattr(t, <span class="s">"interrupts"</span>, <span class="k">None</span>) <span class="k">or</span> []):
        <span class="k">if</span> isinstance(getattr(i, <span class="s">"value"</span>, <span class="k">None</span>), dict):
            intr_payload = i.value   <span class="c"># {kind, stage, round, discussion_id, brief}</span></pre>
    <h3 id="hitl-19">四个来自实战的经验约束</h3>
    <div class="grid g2">
      <div class="card warn">
        <h4 id="hitl-20">作者的驳回理由 ≠ AI 审核结论</h4>
        <p>驳回时写入的 issue 带 <code>rejected=True</code>，必须留在 State（重跑要用），但下发前端前要剔除，
          否则下一轮卡片会把作者自己的话回显成「AI 发现的严重问题」。</p>
      </div>
      <div class="card warn">
        <h4 id="hitl-21">门禁卡上填的答案必须能进 prompt</h4>
        <p>曾把「本卷计划章数」只写进讨论日志，阶段节点读不到，于是每卷都按默认值 10 章生成。
          修复后写入 <code>stage_gate.notes</code>——<b>回路要闭环，读得到才算数</b>。</p>
      </div>
      <div class="card warn">
        <h4 id="hitl-22">定稿才进向量库</h4>
        <p><code>writing</code> 通过只是「草稿进入审核」，此时入库会让后续检索命中未定稿内容。
          只有 <code>reviewing</code> / <code>polishing</code> 通过才写。</p>
      </div>
      <div class="card warn">
        <h4 id="hitl-23">停在未知节点要报错</h4>
        <p>LLM 连接失败会让图停在原节点等待重试。这种情况既没有卡片可操作也不是正常结束，
          必须补发错误帧，否则前端按钮永久停在「停止」状态。</p>
      </div>
    </div>
  </div>
</section>
<!-- ===================== 05 存储 ===================== -->
<section id="storage">
  <div class="wrap">
    <div class="eyebrow">05 · Storage</div>
    <h2 id="storage">存储设计：为什么正文不能进 State</h2>
    <p class="lead">
      这是全系统最重要的一条架构决策。LangGraph 每执行一步都会把<b>整个 State</b> 序列化成一个 checkpoint。
      如果正文也在 State 里，写第 30 章时每一步都要存一份 30 章的全文——存储会持续膨胀，
      回退和分支复制还得搬着整份正文跑。
    </p>
    <div class="diagram">
      <div class="vs">
        <div class="card accent">
          <h4 id="storage-25">State</h4>
          <p style="font-size:13px;color:var(--ink-3);margin-top:0">每步整体序列化进 checkpoint</p>
          <ul class="clean" style="font-size:13.5px">
            <li>current_stage / current_chapter_index</li>
            <li>world_setting / character_settings</li>
            <li>outline / foreshadow</li>
            <li><b>chapters[].content_ref</b> ← 只存指针</li>
          </ul>
        </div>
        <div class="mid">content_ref&nbsp;→<br><code>ch_0003@v7</code></div>
        <div class="card ok">
          <h4 id="storage-26">body store · <code>chapter_bodies</code></h4>
          <p style="font-size:13px;color:var(--ink-3);margin-top:0">正文权威副本，按版本追加</p>
          <ul class="clean" style="font-size:13.5px">
            <li>key = (project, chapter, version)</li>
            <li>v0 基线　v1　v2　v3 … v7</li>
            <li><b>改一次新增一行，永不覆盖</b></li>
            <li>读取三级回退：目标版本 → v0 → 最新版</li>
          </ul>
        </div>
      </div>
      <h4 id="storage-27" style="text-align:center;margin-top:26px">全部落在 TiDB 的八张表</h4>
      <div class="grid g3">
        <div class="svc" style="text-align:left">
          <b>checkpoints / writes</b>
          <small>LangGraph 状态链<br>UUID 字典序即时间序<br>自研 TiDBSaver</small>
        </div>
        <div class="svc" style="text-align:left">
          <b>chapter_bodies</b>
          <small>正文版本（追加式）<br>GC 独立判定<br>v0 基线永久保留</small>
        </div>
        <div class="svc" style="text-align:left">
          <b>sidecar_events</b>
          <small>会话回放 + 讨论明细<br>append-only，200ms 批量刷<br>绝不进创作 State</small>
        </div>
      </div>
      <p style="text-align:center;font-size:12.5px;color:var(--ink-3);margin-bottom:0">
        另有 projects / users / login_failures / token_usage 四张业务表（<code>token_usage</code> 是「用户 × 天」的 token 日聚合，
        配额闸门在 <code>/run</code>、<code>/discuss</code> 入口判超额）；向量数据在 Qdrant
      </p>
      <div class="cap">图 4 · 存储分层：State 存指针，正文独立按版本追加</div>
    </div>
    <h3 id="storage-28">为什么不用官方 <code>langgraph-checkpoint-mysql</code></h3>
    <p>
      官方实现的 SELECT 依赖 MySQL 的 <code>JSON_TABLE()</code>，TiDB 8.5 <b>不支持</b>（直接报 1064）；
      upsert 用的 <code>INSERT … AS new</code> 别名语法 TiDB 同样不支持。所以按 <code>SqliteSaver</code> 的语义重新移植了一份：
    </p>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>官方 / SQLite 写法</th><th>TiDB 写法</th><th>用途</th></tr></thead>
        <tbody>
          <tr><td><code>INSERT OR REPLACE</code></td><td><code>REPLACE INTO</code></td><td>写 checkpoint 行</td></tr>
          <tr><td><code>INSERT OR IGNORE</code></td><td><code>INSERT IGNORE INTO</code></td><td>写特殊 channel 的 writes</td></tr>
          <tr><td>SQL 侧 <code>JSON_EXTRACT</code> 过滤</td><td>Python 侧过滤</td><td>metadata 过滤不上推数据库</td></tr>
          <tr><td>逐行 INSERT</td><td>单条多值 INSERT</td><td>每次网络往返 0.3s 起，必须批量</td></tr>
        </tbody>
      </table>
    </div>
    <h3 id="storage-29">针对网络延迟的两处读优化</h3>
    <ul class="clean">
      <li><code>get_tuple</code> 用<b>单条 SQL JOIN</b> 同时取 checkpoint 和它的 pending writes——这是最热的读路径，拆两条就翻倍。</li>
      <li><code>list</code> <b>一次取回</b>涉及 thread 的全部 writes，避免 N+1（逐个查会让历史回放不可用）。</li>
    </ul>
  </div>
</section>
<!-- ===================== 06 时间旅行 ===================== -->
<section id="checkpoint">
  <div class="wrap">
    <div class="eyebrow">06 · Time Travel</div>
    <h2 id="checkpoint">Checkpoint 与时间旅行</h2>
    <p class="lead">
      每次 <code>interrupt()</code> 都是一个 checkpoint。因此「作者思考三小时」和「三年后回来重看」在系统眼里没有区别——
      状态已经躺在 TiDB 里了。
    </p>
    <div class="diagram">
      <div class="retain">
        <div class="z del">
          <b>超出 20 的步级</b>
          删除并重链父指针
        </div>
        <div class="z keep">
          <b>保留区</b>
          里程碑全部保留 + 最近 20 个步级
        </div>
      </div>
      <div class="dots">
        <span class="m" title="create 里程碑"></span>
        <span class="d"></span><span class="d"></span><span class="d"></span><span class="d"></span><span class="d"></span><span class="d"></span>
        <span class="gap"></span>
        <span class="s"></span><span class="s"></span><span class="m" title="stage 里程碑"></span><span class="s"></span>
        <span class="s"></span><span class="s"></span><span class="m" title="chapter 里程碑"></span><span class="s"></span>
        <span class="s"></span><span class="m" title="review 里程碑"></span><span class="s"></span><span class="s"></span>
      </div>
      <div class="legend">
        <span><i class="m"></i>里程碑 · 永久保留</span>
        <span><i class="s"></i>步级 · 保留最近 20</span>
        <span><i class="d"></i>被清理</span>
      </div>
      <div class="cap">图 5 · 时间轴由左至右。注意最左侧的 create 里程碑虽然很老，仍因是里程碑而保留</div>
    </div>
    <h3 id="checkpoint-31">里程碑怎么判定</h3>
    <p><b>读取历史时按快照内容确定性推导</b>，不依赖写入时注入的 metadata——这样对历史数据同样有效：</p>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>条件</th><th>动作标签</th></tr></thead>
        <tbody>
          <tr><td>没有更早的快照（首点）</td><td><code>create</code>　分支线程为 <code>branch</code></td></tr>
          <tr><td><code>current_stage</code> 发生变化</td><td><code>stage:{阶段}</code></td></tr>
          <tr><td>某章 status 推进到 reviewed / polished</td><td><code>chapter:{状态}</code></td></tr>
          <tr><td>进入人审等待（interrupt 产物）</td><td><code>review</code></td></tr>
          <tr><td><code>current_stage == completed</code></td><td><code>completed</code></td></tr>
          <tr><td>链头（最新快照）</td><td><code>latest</code></td></tr>
          <tr><td><b>反序列化失败</b></td><td><code>unreadable-keep</code>　宁可多留不可误删</td></tr>
        </tbody>
      </table>
    </div>
    <h3 id="checkpoint-32">删除的时机</h3>
    <div class="note i"><b>◈</b><div>
      没有定时清理任务。<b>唯一自动触发点是「一次创作流程跑完时」</b>（<code>/run</code>、<code>/review</code>、<code>/resume</code>、<code>/rerun</code> 的流结束），
      后台异步执行，不阻塞响应；上一轮没跑完就跳过。只聊天讨论不会触发（它不写 checkpoint）。
    </div></div>
    <p>一次维护按顺序做四件事，<b>顺序是硬约束</b>：</p>
    <div class="steps">
      <li><b>清理过期快照</b><span>决定哪些快照还活着</span></li>
      <li><b>数引用</b><span>把还活着的所有快照翻一遍，收集它们指向的正文版本——必须是「清理后仍存在」的快照</span></li>
      <li><b>删无引用的正文</b><span>正文表中不在引用集合里的版本删掉；<code>v0</code> 基线永久保留</span></li>
      <li><b>会话日志轮转</b><span>超过 5 万条时丢弃最早部分，保留最近 2 万条</span></li>
    </div>
    <p>手动删除则是即时的：<b>删除章节</b>会清掉该章所有正文版本；<b>删除项目</b>会全清（快照、分支快照、正文、向量、会话与讨论）。</p>
    <h3 id="checkpoint-33">时间旅行能做什么</h3>
    <div class="grid g2">
      <div class="card accent"><span class="ico">↺</span><h4 id="checkpoint-34">从快照派生</h4><p>创建分支时可传 <code>from_snapshot_id</code> 指定任一历史快照作为起点（<code>POST /projects/{id}/branches</code>）。<b>快照本身不能原地回滚</b>——要回退就派生一条分支再对比。</p></div>
      <div class="card accent"><span class="ico">⑂</span><h4 id="checkpoint-35">分支</h4><p>复制 State 到新 thread，支持左右对比与合并（<code>strategy: replace | new_snapshot</code>）。</p></div>
      <div class="card accent"><span class="ico">⟳</span><h4 id="checkpoint-36">局部重跑</h4><p>指定起始章节重跑后续 N 章（默认 3 章）。重跑前会先按 <code>source="chapter"</code> + <code>chapter_index ≥ from</code> 精确定点删除旧向量，避免废弃设定被召回回来。</p></div>
      <div class="card accent"><span class="ico">◷</span><h4 id="checkpoint-37">正文版本回退</h4><p><code>GET /chapters/{id}/versions</code> 列出全部正文版本，<code>POST /chapters/{id}/versions/{v}/restore</code> 以旧版本<b>追加一份新版本</b>（append-only，历史不被抹掉）。</p></div>
    </div>
  </div>
</section>
<!-- ===================== 07 检索 ===================== -->
<section id="rag">
  <div class="wrap">
    <div class="eyebrow">07 · Retrieval</div>
    <h2 id="rag">检索与一致性保障</h2>
    <p class="lead">
      长篇创作中，第 30 章需要的前情不能靠「把前 29 章塞进上下文」——那会爆。
      系统改为<b>按需检索</b>：写章前根据章纲、未回收伏笔、角色名构造子查询，从向量库取回最相关的片段注入 prompt。
    </p>
    <div class="diagram">
      <div class="flow" style="padding-top:0">
        <div class="node plain">本章输入<small>章纲 + 伏笔 + 角色</small></div>
        <span class="arw"></span>
        <div class="node gate">构造子查询<small>伏笔优先，上限 2 条</small></div>
        <span class="arw"></span>
        <div class="node">Embedding<small>bge-m3 · 1024 维</small></div>
        <span class="arw"></span>
        <div class="node gate">相似度过滤<small>每条子查询各自 min_score = 0.45</small></div>
        <span class="arw"></span>
        <div class="node soft">Qdrant 检索<small>scope=story（前情正文 + 伏笔）<br>每条 top-3 · 合并后 k=8</small></div>
        <span class="arw"></span>
        <div class="node plain">合并去重<small>名次轮转 + 最近 5 章时间偏置</small></div>
      </div>
      <div class="link"><em>注入写作 prompt</em><i></i></div>
      <div class="flow-router">
        <span class="chip">writing_node</span>
        <p>检索结果同时下发前端渲染「引用卡」，作者能看到模型到底参考了哪些资料</p>
      </div>
      <div class="cap">图 6 · 写章前的检索链路：从章纲到上下文注入。世界观 / 人设走直塞区块（不走检索），作者上传的设定集另走 <code>scope="document"</code> 一路作为硬约束</div>
    </div>
    <h3 id="rag-39">阈值是怎么标定的</h3>
    <p><code>RAG_MIN_SCORE = 0.45</code> 由实测标定得出，标定点如下：</p>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>样本</th><th>分数</th><th>结论</th></tr></thead>
        <tbody>
          <tr><td>完全无关的查询（噪声地板）</td><td>0.4297</td><td>阈值必须高于它</td></tr>
          <tr><td>真命中的首位结果</td><td>0.5498 ～ 0.7135</td><td>阈值必须低于它</td></tr>
          <tr><td>第 3～4 位边缘命中</td><td>0.41 ～ 0.49</td><td>与噪声重叠，会被误伤</td></tr>
        </tbody>
      </table>
    </div>
    <p>取 0.45 的代价是少数边缘命中被砍掉，但写入时 top_k 本来就不大，可以接受。想更保守调 0.35，想更干净调 0.55。</p>
    <div class="note w"><b>⚠ 一致性是软检测</b><div>
      <code>reviewing</code> 节点让 LLM 输出 <code>ReviewIssue{id, kind: ooc | foreshadow | conflict | logic | style, severity: critical | major | minor, description, suggestion}</code>，
      并给出 <code>overall_score</code>（0–100）。
      这里<b>没有规则引擎、没有 NLI 硬校验</b>，本质是「让模型自查」，会漏也会误报。
      伏笔回收靠「未回收伏笔进检索 query」被动防漏。<br>
      所以系统的保证是「作者有机会看到并否决」，「问题一定被找全」做不到。
    </div></div>
  </div>
</section>
<!-- ===================== 08 旁路讨论 ===================== -->
<section id="sidecar">
  <div class="wrap">
    <div class="eyebrow">08 · Sidecar</div>
    <h2 id="sidecar">旁路讨论：图挂起 ≠ 对话挂起</h2>
    <p class="lead">
      在聊天工具里「跟 AI 讨论一下」会永久污染上下文。本系统把讨论做成图的<b>旁路服务</b>：
      可以来回 N 轮，图上毫无痕迹。
    </p>
    <div class="grid g3">
      <div class="card ok"><span class="ico">✓</span><h4 id="sidecar-41">不推进图</h4><p>讨论不会让状态机前进一步。</p></div>
      <div class="card ok"><span class="ico">✓</span><h4 id="sidecar-42">不写 checkpoint</h4><p>否则讨论轮次会让 checkpoint 堆积。</p></div>
      <div class="card ok"><span class="ico">✓</span><h4 id="sidecar-43">不进 State</h4><p>历史只落 sidecar 表，绝不污染创作上下文。</p></div>
    </div>
    <h3 id="sidecar-44">AI 只给建议，不直接改稿</h3>
    <p>
      讨论产出结构化 <code>suggestion</code> 事件（<code>{field, target_id, summary, reason}</code>），
      落地必须走既有通道：<code>PUT /state</code> 或 <code>POST /review{modify}</code>。<b>不开后门</b>——
      这是保证「所有对 State 的修改都经过同一套校验」的关键。
    </p>
    <h3 id="sidecar-45">两条低成本修改通道</h3>
    <p>驳回意味着一次完整阶段重跑（整章重写），成本很高。真正便宜的改法不经过 interrupt：</p>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>接口</th><th>行为</th></tr></thead>
        <tbody>
          <tr><td><code>POST /revise-field</code></td><td>局部改世界观 / 人设 / 大纲。提示词强约束「未提及部分逐字保留」，产出完整字段值草稿供确认</td></tr>
          <tr><td><code>POST /revise-chapter</code></td><td>按意见整章修订，流式输出到中间栏编辑器</td></tr>
          <tr><td><code>PUT /chapters/{id}/paragraph/{i}</code></td><td>段落级直接编辑，最细粒度</td></tr>
        </tbody>
      </table>
    </div>
  </div>
</section>
<!-- ===================== 09 前端 ===================== -->
<section id="frontend">
  <div class="wrap">
    <div class="eyebrow">09 · Frontend</div>
    <h2 id="frontend">产品形态</h2>
    <p class="lead">三栏工作台：左栏大纲与章节、中间栏编辑器与产物视图、右栏 AI 会话面板。</p>
    <div class="grid g3">
      <div class="card"><span class="ico">☰</span><h4 id="frontend-47">登录页 <code>/login</code></h4><p>JWT 登录（用户体系可开关）+ 算术验证码</p></div>
      <div class="card"><span class="ico">◫</span><h4 id="frontend-48">项目列表 <code>/</code></h4><p>创建 / 重命名 / 删除 / 复制项目，显示章数与字数</p></div>
      <div class="card"><span class="ico">☗</span><h4 id="frontend-49">成员管理 <code>/admin</code></h4><p>用户列表、改密（同步吊销会话）、成员作品只读浏览、删号级联清理</p></div>
      <div class="card"><span class="ico">▤</span><h4 id="frontend-50">工作台 <code>/p/:id</code></h4><p>三栏写作台：大纲、章节编辑、流式生成日志</p></div>
      <div class="card"><span class="ico">⚙</span><h4 id="frontend-51">设定中心 <code>/p/:id/settings</code></h4><p>角色（含别名）/ 世界观 / 伏笔的集中管理</p></div>
      <div class="card"><span class="ico">⑂</span><h4 id="frontend-52">分支对比 <code>/p/:id/branches</code></h4><p>分支列表与左右内容差异对比</p></div>
      <div class="card"><span class="ico">⌕</span><h4 id="frontend-53">全文搜索 <code>/p/:id/search</code></h4><p>跨章节检索，命中段落可跳转高亮</p></div>
      <div class="card"><span class="ico">◈</span><h4 id="frontend-54">NDJSON 流式消费</h4><p><code>fetch</code> ReadableStream 逐行解析，按 target 分发到不同面板</p></div>
      <div class="card"><span class="ico">◇</span><h4 id="frontend-55">本地缓存</h4><p>Zustand + <code>localStorage</code>，只持久化 UI 偏好、JWT 与视图模式；正文草稿只在内存，刷新即失</p></div>
    </div>
    <div class="note i"><b>◈</b><div>前端用 <code>BrowserRouter</code>，所以 Nginx 必须配
      <code>try_files $uri $uri/ /index.html</code>，否则刷新子路由会 404。</div></div>
  </div>
</section>
<!-- ===================== 10 部署 ===================== -->
<section id="deploy">
  <div class="wrap">
    <div class="eyebrow">10 · Deployment</div>
    <h2 id="deploy">部署形态</h2>
    <p class="lead"><code>dev.sh</code> 仅供本地开发。生产用 <b>systemd 托管 uvicorn（只监听 127.0.0.1:3000）</b> + <b>Nginx 托管静态资源并反代 /api</b>。</p>
    <div class="steps">
      <li><b>安装运行时</b><span>Python 3.11+、Node 22 LTS、pnpm、Nginx。Debian 12 自带 3.11 可用</span></li>
      <li><b>建 venv 并装依赖</b><span><code>python3 -m venv venv</code> → <code>pip install -r requirements.txt</code></span></li>
      <li><b>手动创建 .env</b><span>它被 gitignore，换机器必填：<code>TIDB_PASSWORD</code>、<code>OPENAI_API_KEY</code>、<code>QDRANT_API_KEY</code>；对外部署还要设 <code>AUTH_ENABLED=true</code> 与 <code>JWT_SECRET</code></span></li>
      <li><b>systemd 托管</b><span><code>ExecStart</code> 指向 venv 里的 python，注意路径与 <code>WorkingDirectory</code> 必须一致</span></li>
      <li><b>构建前端</b><span><code>pnpm install --frozen-lockfile</code> → <code>pnpm build</code>，产物在 <code>frontend/dist</code></span></li>
      <li><b>Nginx 配置</b><span>静态托管 + <code>/api/</code> 反代 + <code>proxy_buffering off</code> + <code>client_max_body_size</code></span></li>
    </div>
    <div class="note w"><b>⚠</b><div>两个最容易踩的坑：
      ① systemd 里 <code>ExecStart</code> 的 venv 路径写错会报 <code>status=203/EXEC</code> 并无限重启；
      ② <code>.env</code> 不随 git 下来，也不会自动生成，换机器时最容易漏。</div></div>
  </div>
</section>
<!-- ===================== 11 权衡 ===================== -->
<section id="tradeoff">
  <div class="wrap">
    <div class="eyebrow">11 · Trade-offs</div>
    <h2 id="tradeoff">设计权衡与已知边界</h2>
    <p class="lead">
      和「直接在聊天窗口里写小说」相比，差距到底在哪？一句话：<b>不在「写得更好」，而在「写得完、改得动、回得去」</b>。
    </p>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>维度</th><th>对比直接聊天</th><th>说明</th></tr></thead>
        <tbody>
          <tr><td>长篇（10 章以上）跨会话可控性</td><td><b>质变</b></td><td>聊天到第 15 章左右必然失控</td></tr>
          <tr><td>可回溯 / 分支对比</td><td><b>从 0 到 1</b></td><td>聊天里完全没有这个概念</td></tr>
          <tr><td>产出稳定性（方差）</td><td>明显提升</td><td>流程约束让单次抽风毁不掉整章</td></tr>
          <tr><td>设定一致性</td><td>中等提升</td><td>喂了结构化设定 + 专门审核轮次，但仍是软检测</td></tr>
          <tr><td>单段文笔</td><td>几乎无差别</td><td>底层是同一个模型</td></tr>
          <tr><td>短篇（≤3 章）效率</td><td><b>反而更差</b></td><td>流程开销大于收益</td></tr>
        </tbody>
      </table>
    </div>
    <h3 id="tradeoff-58">已知边界</h3>
    <div class="grid g2">
      <div class="card warn"><h4 id="tradeoff-59">多副本部署被硬性禁止</h4><p><code>in_flight</code>、sidecar seq 缓存、改写重跑标记都是进程内状态，所以第二个进程共用数据目录时<b>启动即失败</b>——<code>lifespan</code> 一进来就用 <code>flock</code> 抢实例锁，抢不到直接抛错（见 <code>core/instance_lock.py</code>）。要横向扩展必须先把这三处换成 Redis 之类的共享存储。</p></div>
      <div class="card warn"><h4 id="tradeoff-60">AI 看不到讨论过程</h4><p>多轮讨论只以 <code>notes</code> 与最终 brief 进入生成，中间推理链不传给阶段节点。</p></div>
      <div class="card warn"><h4 id="tradeoff-61">reject 成本高</h4><p>一次驳回 = 一次完整阶段重跑。低成本修改应走 <code>/revise-field</code>、<code>/revise-chapter</code>。</p></div>
      <div class="card warn"><h4 id="tradeoff-62">门禁轮次只是软上限</h4><p>超过 5 轮仍要求确认，只在提示里建议「可直接确认」。</p></div>
    </div>
    <div class="note g"><b>✓ 下一步最值得补的</b><div>
      把一致性从「LLM 自查」升级为<b>结构化校验</b>（人物出场表、时间线冲突、伏笔状态机的规则检查）。
      这是目前最薄弱的一环，也是最能拉开差距的地方。
    </div></div>
  </div>
</section>
</div>
