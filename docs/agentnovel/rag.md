---
title: 检索系统（RAG）设计详解
description: NovelCraft AI 检索系统（RAG）设计详解：从分块、入库前缀到查询链路的完整设计，以及每个反直觉设计背后的真实故障。
outline: [2, 3]
---
<div class="an-doc">
<header class="hero">
  <div class="wrap">
    <div class="eyebrow">Retrieval Augmented Generation · Design Deep Dive</div>
    <h1 id="检索系统rag设计详解">检索系统（RAG）设计详解</h1>
    <p class="lead">
      这份文档解释 NovelCraft AI 的检索系统<strong>为什么长成这样</strong>。
      每一节都会先说「遇到什么问题」，再说「现在怎么做的」，最后说「不这么做会怎样」——
      因为本系统里几乎每个反直觉的设计，都是某次真实的静默故障换来的。
      <strong>不需要任何 AI 背景</strong>，读完你应该能自己判断「为什么我的设定没被检索到」。
    </p>
    <div class="badges">
      <span class="badge">bge-m3 · 1024 维</span>
      <span class="badge">Qdrant · cosine</span>
      <span class="badge">切块 500 字 / 重叠 80</span>
      <span class="badge">子查询 ≤ 6 · 每条取 3</span>
      <span class="badge">阈值 0.45</span>
      <span class="badge">只索引定稿正文</span>
    </div>
    <div class="stats">
      <div class="stat"><b>5</b><small>检索域 source</small></div>
      <div class="stat"><b>6</b><small>子查询上限</small></div>
      <div class="stat"><b>8</b><small>保底注入条数</small></div>
      <div class="stat"><b>500</b><small>单块字数上限</small></div>
      <div class="stat"><b>3</b><small>单次写作的检索路数</small></div>
      <div class="stat"><b>0</b><small>静默失败的检索</small></div>
    </div>
  </div>
</header>
<!-- ===================== 01 为什么 ===================== -->
<section id="why">
  <div class="wrap">
    <div class="eyebrow">01 · Motivation</div>
    <h2 id="why">为什么需要检索：两个绕不过去的物理限制</h2>
    <p class="lead">
      很多人对 RAG 的印象是「让模型知道更多资料」。但在这类长篇创作系统里，
      检索要解决的是两个更硬的问题——<b>一个是容量问题，一个是时效问题</b>。
      它们属于「不解决就做不成」的那类问题，谈不上优化。
    </p>
    <h3 id="why-2">限制一：上下文窗口装不下前 29 章</h3>
    <p>
      假设一本小说写到第 30 章，每章 3000 字，前 29 章合计约 <b>8.7 万字</b>，
      换算成 token 约 <b>7.7 万</b>。主流模型的上下文窗口在 8 万～200 万之间，
      也就是说：
    </p>
    <ul class="clean">
      <li>哪怕窗口"够大"，把 8 万字全部塞进去，也意味着每次请求都付这笔钱、每次都等这么久；</li>
      <li>更糟的是<b>注意力被稀释</b>——窗口里塞满 8 万字，模型对"第 3 章那句台词"几乎没有注意力权重；</li>
      <li>而且这是<b>死路</b>：写到第 100 章时，20 万字无论哪个模型都装不下。</li>
    </ul>
    <div class="note w"><b>⚠ 关键认知</b><div>
      上下文窗口大 ≠ 能用好上下文。窗口是<b>工作记忆</b>，得按「需要什么查什么」的方式用，
      每次把整个库读一遍的做法行不通。
    </div></div>
    <h3 id="why-3">限制二：模型不会「回忆」，只会「读」</h3>
    <p>
      写作第 30 章时，模型需要知道：主角身上的旧伤是怎么来的、第 7 章那个配角后来去哪了、
      第 12 章埋的伏笔现在该收没收。这些信息<b>确实存在于项目里</b>，
      但模型并不会自动去翻——它只能看到你放进 prompt 的内容。
    </p>
    <p>
      放进 prompt 的方式只有两种，全量塞或者按需取：
    </p>
    <div class="vs">
      <div class="card warn">
        <span class="ico">📚</span>
        <h4 id="why-4">全量直塞</h4>
        <p>把整个设定库 + 全部正文都放进 prompt。上下文一炸就失败；放到第 50 章直接不可用。而且大部分内容这一章根本用不到。</p>
      </div>
      <div class="mid">VS</div>
      <div class="card ok">
        <span class="ico">🔎</span>
        <h4 id="why-5">按需检索（RAG）</h4>
        <p>写第 30 章时，先判断「这一章大概需要什么」，只把那几段取回来注入。本章用不到的、这一章就不花这个钱。</p>
      </div>
    </div>
    <h3 id="why-6">一个类比</h3>
    <p>
      写第 30 章时你需要参考旧资料，这相当于写论文要查文献。
      你不会把整座图书馆搬进书房，也不会只查「含有『月之森』的文献」——
      你会想：<i>我这章要写什么 → 需要哪几方面的资料 → 去把这几篇找出来 → 读一遍</i>。
    </p>
    <p>RAG 就是这个过程，只是把"想"换成了 embedding，把"找"换成了向量检索：</p>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>查文献时</th><th>系统里对应什么</th><th>在哪实现</th></tr></thead>
        <tbody>
          <tr><td>「我这一章要写什么」</td><td>章纲标题 + 梗概</td><td><code>build_story_queries</code></td></tr>
          <tr><td>「有哪些伏笔要收」</td><td>未回收伏笔清单</td><td><code>build_story_queries</code></td></tr>
          <tr><td>「谁会出场」</td><td>规范名 + 别名 + 身份（出场者优先）</td><td><code>_chapter_stage_text</code></td></tr>
          <tr><td>「去找相关段落」</td><td>embedding + 向量检索</td><td><code>_fetch_per_query</code></td></tr>
          <tr><td>「哪几篇最相关」</td><td>每条子查询先过 0.45 阈值，再名次轮转合并</td><td><code>search_dense_leg</code> → <code>_merge_round_robin</code></td></tr>
          <tr><td>「读一遍」</td><td>格式化成带出处的文本块注入 prompt</td><td><code>_format_context</code></td></tr>
        </tbody>
      </table>
    </div>
  </div>
</section>
<!-- ===================== 02 总览 ===================== -->
<section id="overview">
  <div class="wrap">
    <div class="eyebrow">02 · Overview</div>
    <h2 id="overview">30 秒总览：两条方向相反的链路</h2>
    <p class="lead">
      检索系统有两条链路：<b>入库</b>（写作时把新内容变成向量）和<b>检索</b>（写下一章时把老内容取回来）。
      它们共用同一份切块逻辑，但方向相反。理解这两条图，后面所有细节都有位置可放。
    </p>
    <h3 id="overview-8">链路 A · 入库：把文字变成"能算距离的东西"</h3>
    <div class="diagram">
      <div class="flow" style="padding-top:22px">
        <div class="node plain">原始文本<small>章节 / 设定 / 上传文档</small></div>
        <span class="arw"></span>
        <div class="node gate">句子感知切块<small>500 字 · 重叠 80</small></div>
        <span class="arw"></span>
        <div class="node gate">前缀富化<small>章纲 / 出场角色 ≤120 字</small></div>
        <span class="arw"></span>
        <div class="node">Embedding<small>bge-m3 → 1024 维</small></div>
        <span class="arw"></span>
        <div class="node soft">Qdrant upsert<small>payload 存原文+元数据</small></div>
      </div>
      <div class="link"><em>落库，按「来源+主键+块号」生成确定性 id</em><i></i></div>
      <div class="flow-router">
        <span class="chip">写作完成 / 人审定稿 / 设定保存</span>
        <p>章节正文<b>不在写完时入库</b>——只有作者点「定稿」才进向量库（见 <a href="#reliability">可靠性</a>）</p>
      </div>
      <div class="cap">图 1 · 入库链路：三个设计要点（句子感知切块、前缀富化、确定性 id）都在这条链上</div>
    </div>
    <h3 id="overview-9">链路 B · 检索：把"该看的"取回来</h3>
    <div class="diagram">
      <div class="flow" style="padding-top:22px">
        <div class="node plain">本章意图<small>章纲 + 伏笔 + 出场角色</small></div>
        <span class="arw"></span>
        <div class="node gate">构造子查询<small>≤6 条 · 伏笔优先</small></div>
        <span class="arw"></span>
        <div class="node">批量 Embedding<small>一次往返拿全部</small></div>
        <span class="arw"></span>
        <div class="node soft">并发向量检索<small>6 线程 · 每条 top3</small></div>
        <span class="arw"></span>
        <div class="node gate">阈值 0.45<small>每条子查询各自滤</small></div>
        <span class="arw"></span>
        <div class="node gate">轮转合并 + 去重<small>取前 8 条</small></div>
        <span class="arw"></span>
        <div class="node soft">时间偏置<small>最近 5 章提前</small></div>
      </div>
      <div class="link"><em>注入 prompt（截断 500 字/块）+ 下发引用卡</em><i></i></div>
      <div class="flow-router">
        <span class="chip">writing_node</span>
        <p>一次写作会走<b>三路</b>检索：保底（前情+伏笔）、设定参考（作者上传）、章纲阶段预取的资料</p>
      </div>
      <div class="cap">图 2 · 检索链路：注意"子查询"是复数——这是本设计最核心的决策，见第 08 节</div>
    </div>
    <h3 id="overview-10">一次写作的上下文预算</h3>
    <p>
      RAG 只是信息来源之一。写作时 prompt 里的东西分三类，来源不同、可靠性也不同：
    </p>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>类别</th><th>内容</th><th>为什么这样处理</th></tr></thead>
        <tbody>
          <tr>
            <td><b>全量直塞</b></td>
            <td>世界观各字段（每字段 ≤700 字）、角色档案（每人 ≤600 字）、上一章结尾原文（1200 字）</td>
            <td>有界且字段完整，检索反而会漏字段（说话方式、外貌常常召不到）。<b>有界</b>是关键——所以不进检索</td>
          </tr>
          <tr>
            <td><b>硬约束注入</b></td>
            <td>作者上传的「设定参考」，定向检索 top-4</td>
            <td>这是作者显式给的"硬设定"，必须稳定出现并单独标注，不能和章节块抢名额</td>
          </tr>
          <tr>
            <td><b>RAG 检索</b></td>
            <td>前情正文 + 未回收伏笔，分条召回 top-8</td>
            <td>无界（30 章 × 5000 字），只能按需取；伏笔此前从无直塞，<b>只能靠检索</b>进 prompt</td>
          </tr>
        </tbody>
      </table>
    </div>
    <div class="note i"><b>💡 为什么角色/世界观改成直塞</b><div>
      它们曾经也在检索域里。但它们在写作 prompt 里是<b>全量直塞</b>的（角色 ≤12 个、世界观 6 个字段，注入成本可控）。
      让它们再进一次保底检索，等于<b>同一份设定在 prompt 里出现两份</b>——一份完整直塞、一份被 500 字截断的检索片段。
      模型分不清哪份是权威，还白占 token。所以保底检索的域收窄为「前情正文 + 伏笔」。
    </div></div>
  </div>
</section>
<!-- ===================== 03 向量 ===================== -->
<section id="vector">
  <div class="wrap">
    <div class="eyebrow">03 · Embedding Basics</div>
    <h2 id="vector">向量是什么：为什么搜"意思"比搜"字"有用</h2>
    <h3 id="vector-12">从"关键词匹配"到"语义匹配"</h3>
    <p>
      最朴素的检索是关键词匹配：搜「弑父」，只有原文出现「弑父」两个字才命中。
      但小说里表达同一件事可能写「他亲手了结了父亲的性命」「他终于动了那一刀」。
      关键词检索对这种情况<b>完全失效</b>。
    </p>
    <p>
      语义检索（embedding）换了个思路：让模型把一段文字映射成一个<b>固定长度的数字数组</b>，
      使得「意思相近的文字，数组也相近」。这个数组就是向量。
    </p>
    <pre><span class="c">// 「他亲手了结了父亲的性命」→ [0.031, -0.87, 0.22, ..., 0.65]   共 1024 个数字</span>
<span class="c">// 「他终于动了那一刀」    → [0.28, -0.79, 0.14, ..., 0.58]   意思相近 → 数组也相近</span></pre>
    <p>
      两个向量有多接近，用<b>余弦相似度</b>衡量（看两个箭头夹角的大小，范围 −1 ~ 1，越大越像）。
      本系统用的 <code>BAAI/bge-m3</code> 模型输出 <b>1024 维</b>、已 L2 归一化，所以余弦相似度
      可以直接当相关度用。
    </p>
    <div class="note i"><b>💡 小白版理解</b><div>
      向量库可以想象成一个<b>巨大的书架</b>：每段文字被放在一个特定位置，
      意思越接近的段落放得越近。检索就是问「书架上哪个位置离我手里这把钥匙最近」。
      <b>难点在如何把文字准确地"钉"到正确的位置上</b>——这就是 embedding 模型的工作。
    </div></div>
    <h3 id="vector-13">一条铁律：向量只能有一个来源</h3>
    <p>
      本系统的向量<b>只有一个来源</b>：远端 OpenAI 兼容的 <code>/embeddings</code> 接口。
      早期版本还有「本地 sentence-transformers」与「md5 哈希兜底」两条旁路，<b>均已移除</b>。
    </p>
    <p>移除哈希兜底的理由值得单独说，因为它非常典型：</p>
    <div class="note d"><b>✗ 哈希兜底为什么有害</b><div>
      哈希兜底的做法是：对文本取 md5，散列到固定维度里当向量。问题在于它<b>不理解语义</b>，
      而且——这才是致命的——早期实现按<b>空格</b>分词。中文没有空格，
      于是<b>整段中文被当成一个 token</b>，任意两段文本都落到不同的桶但彼此正交，
      相关度<b>实测恒为 0.00</b>。<br><br>
      最可怕的地方在于它「看起来在工作」：接口正常返回、不报错、有命中条数。
      留着只会制造"检索在跑"的错觉。<b>宁可让检索明确失败，也不能假装成功。</b>
    </div></div>
    <div class="grid g3" style="margin-top:18px">
      <div class="card ok"><span class="ico">✅</span><h4 id="vector-14">远端可用</h4><p>正常 embedding、正常检索。</p></div>
      <div class="card warn"><span class="ico">⚠️</span><h4 id="vector-15">远端不可用</h4><p>语义是「<b>本次不检索 / 不索引</b>」，检索结果为空，并在检索账目里标记 <code>embedding: unavailable</code>。</p></div>
      <div class="card accent"><span class="ico">🧪</span><h4 id="vector-16">FAKE_LLM=1</h4><p>走离线确定性夹具（字符 bigram + md5 分桶），供 pytest / E2E 用，绝不发外网请求。</p></div>
    </div>
    <h3 id="vector-17">为什么"失败"必须比"凑合"好</h3>
    <p>
      向量库的集合（collection）维度在<b>创建时就固定</b>。如果同一批数据里混进了不同维度的向量，
      索引会被直接损坏，查询时报维度不匹配。也就是说，<b>降级等于把索引搞坏</b>，不存在"精度差一点"这种中间状态。
    </p>
    <p>所以 <code>embeddings.embed_texts()</code> 的契约是：<b>任何异常都返回 <code>None</code></b>，由调用方决定跳过本次操作，绝不做"半成功"。</p>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>层</th><th>配置项</th><th>默认值</th><th>作用</th></tr></thead>
        <tbody>
          <tr><td>模型</td><td><code>EMBEDDING_API_MODEL</code></td><td><code>BAAI/bge-m3</code></td><td>硅基流动上实测可用</td></tr>
          <tr><td>维度</td><td><code>EMBEDDING_DIM</code></td><td><code>1024</code></td><td><b>换模型必须同步改</b>，否则写入直接被拒</td></tr>
          <tr><td>批量</td><td><code>EMBEDDING_BATCH_SIZE</code></td><td><code>32</code></td><td>一次请求最多打包几条文本</td></tr>
          <tr><td>超时</td><td><code>EMBEDDING_TIMEOUT_S</code></td><td><code>30.0</code></td><td>单次 HTTP 超时</td></tr>
          <tr><td>阈值</td><td><code>RAG_MIN_SCORE</code></td><td><code>0.45</code></td><td>低于此分的命中丢弃</td></tr>
        </tbody>
      </table>
    </div>
    <div class="note w"><b>⚠ 失败冷却</b><div>
      远端超时一次后，<code>_COOLDOWN_S = 60</code> 秒内不再重试。
      否则每章写作都要白等一个 timeout，作者看到的是"生成前卡住很久"。
      同时还有 <code>_CACHE_MAX = 512</code> 条的<b>文本→向量缓存</b>：同一段文本重复 embedding 时直接命中缓存，
      <code>index_settings</code> 每章都调、但内容没变，因此实测几乎不产生新的 embedding 请求。
    </div></div>
  </div>
</section>
<!-- ===================== 04 切块 ===================== -->
<section id="ingest">
  <div class="wrap">
    <div class="eyebrow">04 · Chunking</div>
    <h2 id="ingest">切块：为什么 500，为什么不按字数硬切</h2>
    <p class="lead">
      向量库不能直接存一整章——一方面太长会稀释语义，另一方面向量检索的<b>最小单位是块</b>：
      召回的单位是块。切块质量直接决定检索质量。
    </p>
    <h3 id="ingest-19">问题：按字符硬切会切出"半句话"</h3>
    <p>
      最朴素的切法是每 500 字一刀。问题是<b>刀口可能落在句子中间</b>：
    </p>
    <div class="vs">
      <div class="card warn">
        <h4 id="ingest-20">按字符硬切</h4>
        <p style="font-family:var(--mono);font-size:13px">……他缓缓抬起手，<br>指尖还沾着未干的</p>
        <p style="margin-top:8px">注入 prompt 后模型看到的是「半句话 + 半句话」。它不知道这是谁的结局、发生在哪。</p>
      </div>
      <div class="mid">VS</div>
      <div class="card ok">
        <h4 id="ingest-21">句子感知（本系统）</h4>
        <p style="font-family:var(--mono);font-size:13px">……他缓缓抬起手。<br>指尖还沾着未干的血迹。</p>
        <p style="margin-top:8px">每块以<b>完整句</b>收尾，同样的 500 字预算下可读性和可引用性都更好。</p>
      </div>
    </div>
    <p>实现上分两步（<code>rag.chunk_text</code>）：</p>
    <ul class="clean">
      <li><b>切成原子单元</b>：按句末标点 <code>。！？!?…\n</code> 切段，标点归属前一句（原文零字符丢失）；超长句再硬切。</li>
      <li><b>滑动窗口拼装</b>：往块里加句子，加不下就封块，然后<b>回取上一块尾部不超过 80 字</b>作为重叠。</li>
    </ul>
    <div class="note i"><b>💡 为什么不包含逗号</b><div>
      中文逗号处不构成句子边界，在那里断开只会得到"半句话"的碎片，反而更差。
      <b>重叠区按完整句回取</b>（不硬切字符）：被腰斩的句子在注入时读起来是断的。
    </div></div>
    <h3 id="ingest-22">重叠 80 字：让切点不落在关键信息上</h3>
    <p>
      如果完全不重叠，每块的切点是硬边界。如果某个关键信息正好跨在切点上（比如一个名字在第 499 和 500 字），
      那么<b>任何一块都不包含完整信息</b>，检索时永远召不回完整语义。
    </p>
    <div class="diagram">
      <div class="stack w-lg">
        <div class="box blue">
          <b>块 1：正文 [0, 500)</b>
          <small>内容 0 ～ 499 字（实际最后一句会收尾对齐）</small>
        </div>
        <div class="box mark">
          <b>块 2：正文 [420, 920)</b>
          <small>块 1 的最后 ~80 字在这里重现（黄色 = 重叠区）</small>
        </div>
        <div class="box blue">
          <b>块 3：正文 [840, 1340)</b>
          <small>步长 = 500 − 80 = 420 字，窗口首尾相接</small>
        </div>
      </div>
      <div class="cap">图 3 · 可视窗口：步长 420，窗口 500 → 相邻窗口重叠 80，无缝隙</div>
    </div>
    <p>
      所以「步长 = 块长 − 重叠 = 420」。<b>重叠区存在的唯一目的是让切点无害</b>，
      它本身不提供新信息，但因为会随每个块被 embedding 一次，成本是 16%。
    </p>
    <h3 id="ingest-23">不变量 ①：单块长度必须 ≤ 注入截断（同一个常量）</h3>
    <p>
      这是整个切块设计里<b>最容易被悄悄破坏</b>的地方，值得单独讲。注入 prompt 时有个截断：
      <code>_injectable(content) = content[:CHUNK_SIZE]</code>。只有 500 字，也就是<b>每块最多只有前 500 字进入模型</b>。
    </p>
    <p>
      现在的写法是 <code>content[:CHUNK_SIZE]</code>——<b>直接引用同一个常量</b>。
      两者恒等由结构保证，无需靠"配数值"去凑。
    </p>
    <div class="note d"><b>✗ 如果两者脱钩会怎样</b><div>
      设块长 C、重叠 O、注入截断 T，则<b>步长 S = C − O</b>。
      每块只有前 T 字进入 prompt，于是第 <code>T .. S</code> 字<b>既不在本块的可视部分、也不在下一块</b>（下一块从 S 才开始）——
      <b>每 S 字里有 (S − T) 字永远进不了模型</b>，而且<b>无声无息</b>：作者以为设定已经被参考了。
    </div></div>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>配置</th><th>步长 S</th><th>可视窗口</th><th>后果</th></tr></thead>
        <tbody>
          <tr>
            <td><b>C=500　O=80　T=500</b>（现状）</td><td>420</td>
            <td>[0,500) [420,920) [840,1340)</td>
            <td style="color:var(--ok)"><b>0 字丢失</b>，重叠区无缝覆盖</td>
          </tr>
          <tr>
            <td>C=1000　O=200　T=500</td><td>800</td>
            <td>[0,500) [800,1300) …</td>
            <td style="color:var(--danger)"><b>每 800 字丢 300 字 —— 37.5% 的正文凭空消失</b></td>
          </tr>
          <tr>
            <td>C=800　O=80　T=500</td><td>720</td>
            <td>[0,500) [720,1220) …</td>
            <td style="color:var(--danger)">每 720 字丢 220 字（30.6% 盲区）</td>
          </tr>
        </tbody>
      </table>
    </div>
    <div class="note w"><b>⚠ 为什么这个坑特别危险</b><div>
      此前 <code>_injectable</code> 里是写死的 <code>[:500]</code>，而 <code>CHUNK_SIZE</code> 是另一个常量。
      想调块大小的人<b>只会看到「切 1000 更好」</b>，不会看到「同时得把注入截断也改掉」——
      于是踩进第二行。改成引用同一个常量后，这类漂移<b>在结构上就不可能发生</b>。
    </div></div>
    <h3 id="ingest-24">不变量 ②：原文零丢失，且刻意不去重</h3>
    <p>
      <code>chunk_text</code> 保证所有字符至少出现在一个块里（<code>"".join(chunks)</code> 必须含全文）。
      这里有一个<b>刻意不做</b>的优化，值得说明：
    </p>
    <div class="note d"><b>✗ 为什么不按"文本相同"去重</b><div>
      一个看起来很合理的优化是"相邻块文本一样就去重"。但那会<b>吃掉真实数据</b>：
      重复内容（<code>'啊' * 2000</code> → 四个一模一样的 500 字块）切出来的块文本当然相同，
      但它们代表<b>不同位置</b>，去重等于把 2000 字压成 500 字——<b>整段正文凭空消失</b>，而检索侧毫无察觉。
      "下一块与上一块重复"的隐患已由循环里的 <code>cur = []</code> 兜底：每块至少含一个新单元。
    </div></div>
    <h3 id="ingest-25">切块大小受多重约束</h3>
    <div class="note i"><b>💡 为什么不把块调大一点？</b><div>
      因为"越大越准"的直觉在这里不成立：<b>块太大会让一个向量混进多个主题，精度下降得比块太小更狠</b>。
      行业里更该走的方向是「<b>匹配粒度与阅读粒度分离</b>」（小块检索 + 父段注入）；把块调大与此相反。真要调大，必须先想清楚 prompt 预算——注入量是 <code>块长 × 命中条数</code>，翻倍就是翻倍。
    </div></div>
  </div>
</section>
<!-- ===================== 05 前缀富化 ===================== -->
<section id="enrich">
  <div class="wrap">
    <div class="eyebrow">05 · Contextual Retrieval</div>
    <h2 id="enrich">前缀富化：让裸块带上"这是谁的哪一段"</h2>
    <p class="lead">
      检索命中后注入的是<b>裸块</b>——模型看到一段从中间截断的 500 字，
      <b>不知道是哪一章、哪一场、有哪些人在场</b>。前缀富化就是在每块前面加一段短上下文。
    </p>
    <div class="vs">
      <div class="card warn">
        <h4 id="enrich-27">裸块入库</h4>
        <pre style="margin:8px 0;font-size:12px"><span class="c">「……他缓缓抬起手，指尖还沾着未干的血迹。」</span></pre>
        <p>模型不知道这是第 12 章、是谁的结局、为什么在这里。</p>
      </div>
      <div class="mid">→</div>
      <div class="card ok">
        <h4 id="enrich-28">前缀富化后入库</h4>
        <pre style="margin:8px 0;font-size:12px"><span class="c">【第12章 雨夜】本章主线：素世</span>
<span class="c">与陆时摊牌\n出场：素世、陆时\n……他缓缓抬起手，指尖还沾着未干的血迹。</span></pre>
        <p>块自带定位，<b>embedding 也能因此带上信号</b>。</p>
      </div>
    </div>
    <h3 id="enrich-29">关键：前缀必须在入库<b>之前</b>拼接</h3>
    <p>
      这是最容易搞错的一点。embedding 是<b>对最终入库文本算的</b>，所以前缀必须在写入前拼好：
      放在入库后就没意义了（向量已经算完）。<code>index_settings</code> 里因此是
      <code>add_chunks()</code>（<b>切块前</b>逐块拼好身份前缀与「相关角色」）→ <code>rag.add_texts(...)</code> 的顺序。
    </p>
    <h3 id="enrich-30">预算：为什么正文只切到 379 字</h3>
    <p>
      前缀要占用块内空间，于是有一个看似奇怪的设计——<b>正文只切 379 字</b>（500 里给前缀留出预算）：
    </p>
<pre><span class="k">CHUNK_SIZE</span>    = 500  <span class="c"># 块的绝对上限，也等于注入截断</span>
<span class="k">ENRICH_RESERVE</span> = 120  <span class="c"># 前缀最多占多少字</span>
<span class="k">CONTENT_BUDGET</span> = 500 - 120 - 1  <span class="c"># = 379，-1 留给拼接换行</span>
<span class="c"># 保证：前缀(≤120) + 正文(≤379) ≤ 500 = CHUNK_SIZE</span></pre>
    <div class="note d"><b>✗ 为什么不能"先切满再前置前缀"</b><div>
      那样每块会变成 <code>CHUNK_SIZE + len(prefix)</code>，注入时的 <code>_injectable()</code> 就会<b>削掉块尾真实内容</b>——
      正好破坏不变量 ①。所以必须给前缀<b>预留预算</b>。
    </div></div>
    <h3 id="enrich-31">前缀的三个来源与"固定上限"</h3>
    <ul class="clean">
      <li><b>章纲摘要</b>（章节块）：<code>【标题】梗概</code></li>
      <li><b>本章出场角色</b>（章节块）：<code>出场：素世、陆时</code>，最多 <code>ENRICH_MAX_NAMES = 8</code> 个，
          <b>只列本块里真出现的</b>——把本章 12 个角色全写进去会让每块都带一串无关专名，既吃预算又稀释语义</li>
      <li><b>相关角色</b>（设定块）：<code>相关角色：素世、陆时</code>，由 <code>_setting_prefix()</code> 与身份前缀<b>共用同一份 120 字预算</b>一起 clip</li>
    </ul>
    <div class="note i"><b>💡 <code>_clip_prefix</code> 为什么选固定上限</b><div>
      前缀长度固定 → <b>块的切分位置只取决于正文</b>，不因"这一块恰好提到几个角色"而漂移。
      切分几何稳定，<b>确定性 id 与陈旧块清理才不会误判</b>（见下一节）。
      超长时截成 <code>limit-1</code> 字 + 省略号，保留"被截了"的可读提示。
    </div></div>
    <h3 id="enrich-32">五个检索域与它们的元数据</h3>
    <p>
      <code>metadata.source</code> 是<b>域过滤</b>的唯一依据（详见第 10 节），也是引用卡类型的来源。
    </p>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>source</th><th>入库内容</th><th>关键 metadata</th><th>谁负责写入</th></tr></thead>
        <tbody>
          <tr><td><code>chapter</code></td><td>已定稿章节正文</td><td><code>chapter_id / chapter_index / title / outline_title / outline_summary / chunk_index</code></td><td><code>reindex_chapter</code></td></tr>
          <tr><td><code>world_setting</code></td><td>世界观各字段，<code>世界观-{字段}: {值}</code></td><td><code>field</code></td><td><code>index_settings</code></td></tr>
          <tr><td><code>character</code></td><td><code>角色-{名}({定位}): 性格/背景/目标/外貌/说话方式（+别名）</code></td><td><code>character_id / name / title</code></td><td><code>index_settings</code></td></tr>
          <tr><td><code>foreshadow</code></td><td><code>伏笔-{id}: 描述</code><br><small>状态 / 埋于章号<b>只进 payload</b>，不进文本</small></td><td><code>foreshadow_id / status / chapter_index</code></td><td><code>index_settings</code> / <code>index_foreshadow</code></td></tr>
          <tr><td><code>document</code></td><td>作者上传的设定参考（txt/md/pdf/docx）</td><td><code>doc_id / filename</code></td><td><code>documents.upload</code></td></tr>
        </tbody>
      </table>
    </div>
    <h3 id="enrich-33">为什么设定类文本也必须切块</h3>
    <p>
      这里有个历史教训。世界观 / 角色 / 伏笔曾经是「<b>一条 = 一个字段整段</b>」入库的，
      而注入 prompt 时 <code>_format_context</code> 会按 500 字截断。后果：
      <b>世界观的大段描述（实测 <code>setting</code> 常600~1500 字）后半段永远进不了模型</b>，
      而作者以为设定已经被参考了。现在三类设定都按 <code>CONTENT_BUDGET − len(前缀)</code> 切（<b>≤ 379</b>），章节按 <code>CONTENT_BUDGET</code>(379) 切，只有上传文档吃满 500 —— 三者都 ≤ 注入截断 500，不变量①仍然成立。
    </p>
    <div class="note i"><b>💡 那块长描述后面写的是什么，模型就永远看不见</b></div>
    <p>
      多块共享同一个 <code>field</code> / <code>character_id</code> / <code>foreshadow_id</code>，
      但引用卡按 <code>(type, id)</code> 去重，所以界面上仍显示为一条「世界观·setting」，不会刷屏。
    </p>
  </div>
</section>
<!-- ===================== 06 幂等 ===================== -->
<section id="idempotent">
  <div class="wrap">
    <div class="eyebrow">06 · Idempotent Writes</div>
    <h2 id="idempotent">幂等写入：为什么 id 必须由内容位置决定</h2>
    <p class="lead">
      <code>index_settings</code> 在<b>每次写章末尾</b>都会被调用一次。也就是说，同一份设定
      一天可能被写入几十次。如果每次都产生新 id，向量库会线性膨胀。
    </p>
    <div class="note d"><b>✗ 真实故障</b><div>
      实测<b>写 3 章后，世界观的向量从 2 条涨到 6 条</b>。后果是连锁的：
      向量库膨胀 → <b>top-k 被重复内容挤占</b> → prompt 里同一段设定反复出现 →
      token 浪费，且模型看到"设定被强调了三遍"，反而困惑。
      而这一切<b>没有任何报错</b>。
    </div></div>
    <h3 id="idempotent-35">解法：确定性 id</h3>
    <pre><span class="k">def</span> _stable_point_id(source, key, chunk_index):
    <span class="k">return</span> f<span class="c">"{source}:{key}:{int(chunk_index)}"</span>
<span class="c"># 例：world_setting:setting:2  →  character:c03:0  →  foreshadow:f07:1</span></pre>
    <p>
      id 由「<b>来源 + 该来源的主键 + 块序号</b>」三段决定，而主键在切分位置固定（因为前缀长度固定）的前提下也是固定的。
      Qdrant 的 <code>upsert</code> 按 id 覆盖，于是<b>重复索引天然幂等</b>。
    </p>
    <div class="note g"><b>✓ 收益：不再膨胀，还省掉三步动作</b><div>
      不再需要「先 scroll 查旧 id → 写新 → 再删旧」这套<b>三步动作</b>，
      也就不存在两个问题：两次写入之间库里同时存在两份内容（挤占 top-k）、
      以及写入失败后误删旧索引的危险窗口。<b>一步 upsert 就够了。</b>
    </div></div>
    <h3 id="idempotent-36">顺序：先写新，再删旧（不可颠倒）</h3>
    <div class="diagram">
      <div class="flow" style="padding-top:22px">
        <div class="node gate">构造 entries<small>切块 + 富化 + 定 id</small></div>
        <span class="arw"></span>
        <div class="node">add_texts<small>失败则返回空列表</small></div>
        <span class="arw"></span>
        <div class="node gate">_prune_stale_settings<small>只删「键已删 / 块数变少」</small></div>
      </div>
      <div class="flow-bar">
        <b>⚠ 失败时（返回空列表）直接 return，保留旧索引</b>
        <small>反过来「先删后写」会先把设定从索引里抹掉，要等下次重建才恢复 —— 那段时间检索全是空的</small>
      </div>
      <div class="cap">图 4 · <code>index_settings</code> 的顺序：先写新、再删旧，失败时保留旧索引</div>
    </div>
    <p>
      <code>add_documents</code> 返回<b>真正写入成功的 id 列表</b>，embedding 或写入失败都返回空列表。
      调用方必须据此判定"本次没索引"，<b>不能假设没抛异常就是成功</b>。
    </p>
    <h3 id="idempotent-37">陈旧块清理：只删真正过期的</h3>
    <p>
      upsert 覆盖了同 id 的块，但有两种情况它覆盖不到：<b>整个键被删了</b>（世界观某维度被作者删掉）、
      <b>同一键的块数变少了</b>（描述改短了，从 3 块变 1 块）。这些块的 id 不在新 entries 里，
      必须显式删：
    </p>
    <ul class="clean">
      <li>先按 <code>(source, 主键) → 应有块数</code> 建一张期望表；</li>
      <li>一次 <code>scroll</code> 覆盖三个设定域（<code>source</code> 支持 MatchAny），不做逐键往返；</li>
      <li>期望表里没有、或 <code>chunk_index ≥ 应有块数</code> 的 id 进删除列表。</li>
    </ul>
    <div class="note w"><b>⚠ 一个必须注意的边界</b><div>
      当 <code>entries</code> 为空（设定被清空）时<b>不能直接 return</b>——
      返回就等于"保留旧索引"，而旧索引正是该删的那些。此时仍需调用 <code>_prune_stale_settings(rag, [])</code>。
    </div></div>
    <h3 id="idempotent-38">章节索引：单章先删后写</h3>
    <p>
      章节走的是另一套（<code>reindex_chapter</code>）：<b>先按 <code>chapter_id</code> 删该章旧块，再写新块</b>。
      原因是章节正文会被作者改写——如果只追加新 chunk，同一章会同时召回<b>改动前后两个互相矛盾的版本</b>。
      这正是"改过正文，后续章节却仍按旧内容写"的根源。单章重建成本极低，所以不做增量。
    </p>
    <div class="note d"><b>✗ 一条硬规则：只有定稿进向量库</b><div>
      <code>APPROVED_CHAPTER_STATUS = ("reviewed", "polished")</code>。
      草稿留在 body store 供快照回退，<b>不入索引</b>。此前写完就索引，
      而那时作者还没看过——实测点「通过」之前该章的 16 条块已在向量库里，
      讨论路径的引用卡会带上还没定稿的正文。
    </div></div>
  </div>
</section>
<!-- ===================== 07 入库全过程 ===================== -->
<section id="ingestflow">
  <div class="wrap">
    <div class="eyebrow">07 · Ingestion Walkthrough</div>
    <h2 id="ingestflow">入库全过程：从「点通过」到向量落库</h2>
    <p class="lead">
      前面三节讲了切块、前缀富化、幂等 id 各自为什么这么设计。这一节把它们串起来：
      用<b>真实的调用顺序</b>和<b>实测数字</b>走一遍，作者点一次「通过」之后，数据到底是怎么变成向量的。
      本节所有数字均来自实际调用 <code>chunk_text</code> / <code>index_chapter</code> / <code>index_settings</code> 的结果。
    </p>
    <h3 id="ingestflow-40">四条入库路径，参数各不相同</h3>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>路径</th><th>触发时机</th><th>切块尺寸</th><th>id 形态</th><th>幂等</th></tr></thead>
        <tbody>
          <tr>
            <td><b>A · 章节正文</b></td>
            <td>人审「通过」/ 采用润色候选</td>
            <td><code>379</code><br><small>给前缀留 120 预算</small></td>
            <td><code>uuid4</code></td>
            <td style="color:var(--danger)"><b>否</b> → 必须<b>先删后写</b></td>
          </tr>
          <tr>
            <td><b>B · 设定</b><br><small>世界观/角色/伏笔</small></td>
            <td><b>每次写章末尾</b> / 重建索引</td>
            <td><code>379 − len(前缀)</code><br><small>前缀与正文共用一份预算</small></td>
            <td><code>world_setting:setting:0</code><br><code>character:ch0:0</code><br><code>foreshadow:f07:1</code></td>
            <td style="color:var(--ok)"><b>是</b> → upsert 覆盖</td>
          </tr>
          <tr>
            <td><b>C · 上传文档</b></td>
            <td>作者上传时（仅此一次）</td>
            <td><code>500</code><br><small>无前缀，无需预留</small></td>
            <td><code>uuid4</code></td>
            <td style="color:var(--danger)"><b>否</b></td>
          </tr>
          <tr>
            <td><b>D · 伏笔</b></td>
            <td>伏笔状态变更 / 章节删除后</td>
            <td><code>379 − len(前缀)</code><br><small>与 <code>index_settings</code> 完全一致</small></td>
            <td><code>foreshadow:f07:0</code></td>
            <td style="color:var(--ok)"><b>是</b></td>
          </tr>
        </tbody>
      </table>
    </div>
    <h3 id="ingestflow-41">路径 A · 章节正文（只有定稿才发生）</h3>
    <p>
      写作节点<b>不会</b>索引刚生成的正文——那时作者还没看过。
      索引发生在人审「通过」时：
    </p>
    <ol class="steps">
      <li><b>取章与章纲</b><span><code>_index_approved_chapter(state)</code> 从 <code>state.chapters</code> 里取出 <code>index == current_chapter_index</code> 的章；再用 <code>_outline_of(state, idx)</code> 取对应章纲的 <code>title</code> / <code>summary</code>。采用润色候选时必须<b>显式传入新版章节</b>——此时 State 里的 <code>content_ref</code> 还指向旧版本。</span></li>
      <li><b>先删该章旧块</b><span><code>rag.delete_by_metadata({"chapter_id": "c11"})</code> → 先 <code>get(where=...)</code> 拿 id 列表，再 <code>delete(ids)</code>。这一步<b>不能省</b>：章节 id 是随机的 <code>uuid4</code>，不删就会新旧两版并存，召回时同时出现「改动前」和「改动后」两个互相矛盾的版本。</span></li>
      <li><b>从 body store 读正文</b><span>State 里只有 <code>content_ref</code> 指针，正文外置在 body store。<code>body_store.get(project_id, content_ref or chapter_id)</code>。若整章被清空（无正文）→ 直接 return True，旧向量已删，索引为空，这是正确的。</span></li>
      <li><b>构造章纲头</b><span><code>head = f"【{outline_title}】{outline_summary}\n"</code></span></li>
      <li><b>切块</b><span><code>chunk_text(content, chunk_size=CONTENT_BUDGET)</code> → <b>379 字 / 重叠 80，步长 299</b>。</span></li>
      <li><b>逐块拼出场角色</b><span>对每一块跑 <code>_names_in(piece, names)</code>，只列<b>本块真正出现</b>的角色（按设定表顺序、最多 8 个）；拼成 <code>pre = head + "出场：素世、陆时\n"</code>，再 <code>_clip_prefix(pre)</code> 截到 ≤120。<br>最终 <code>text = prefix + piece</code>，<b>总长 ≤ 499</b>，注入时永不触发截断。</span></li>
      <li><b>生成 metadata 与 id</b><span>metadata 见下表；id <b>不传</b>，由 <code>add_documents</code> 现生成 <code>uuid4</code>（这正是步骤 2 必须存在的原因）。</span></li>
      <li><b>embedding 并落库</b><span><code>_embed(texts)</code> → 远端 <code>/embeddings</code>（命中缓存则免请求）→ <code>collection.add(...)</code> → Qdrant <code>upsert</code>，每批 128 条；payload = 清洗后的 metadata + <code>_text</code>（原文）+ <code>_id</code>（原始 id）。</span></li>
    </ol>
    <h4 id="ingestflow-42">实测规模（4200 字正文样本）</h4>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>路径</th><th>切块参数</th><th>块数</th><th>最长块</th><th>原文覆盖</th></tr></thead>
        <tbody>
          <tr><td>章节（路径 A）</td><td><code>chunk_size=379, overlap=80</code></td><td><b>14</b></td><td>379</td><td style="color:var(--ok)"><b>4200 / 4200</b></td></tr>
          <tr><td>上传文档（路径 C）</td><td><code>chunk_size=500, overlap=80</code></td><td><b>10</b></td><td>500</td><td style="color:var(--ok)"><b>4200 / 4200</b></td></tr>
        </tbody>
      </table>
    </div>
    <p><small>覆盖 4200/4200 即不变量 ②（原文零丢失）成立：每个字符至少出现在一个块里。</small></p>
    <h4 id="ingestflow-43">一块真实的入库文本（样例章 522 字，切出 2 块）</h4>
    <pre><span class="c"># 第 0 块 · 长度 421 = 前缀 44 + 正文 377</span>
<span class="s">【第12章 雨夜】素世与陆时在雨中对峙，陆时终于说出三年前事故的真相。</span>
<span class="s">出场：素世、陆时</span>雨下了整夜。素世站在便利店门口，看着对街那盏忽明忽暗的灯。陆时从巷口走出来，手里捏
着一枚旧钥匙扣。他说，三年前的事，我今天必须说清楚。素世没有说话，只是把伞往他那边偏了三寸。……</pre>
    <pre><span class="c"># 第 0 块的 metadata</span>
{"source":"chapter","chapter_id":"c11","chapter_index":11,"title":"第12章 雨夜",
 "outline_title":"第12章 雨夜","outline_summary":"素世与陆时在雨中对峙，陆时终于说出三年前事故的真相。",
 "chunk_index":0}</pre>
    <div class="note w"><b>⚠ 路径 A 固定「先删后写」</b><div>
      这与路径 B <b>相反</b>，且是刻意的：章节 id 是随机的 <code>uuid4</code>，只能靠"先删"来避免新旧并存。
      代价是——<b>若 embedding 在第 8 步失败，该章旧向量已被删掉且不会回滚</b>，
      这一章会从索引里消失，直到下次重建。<br>
      <code>_index_approved_chapter</code> 只记日志不阻断审核推进（检索只作增强，失败可跳过），
      但账目上会体现为 <code>embedding: unavailable</code>。
      <b>路径 B 特意避开这个风险</b>，所以顺序不同——见下。
    </div></div>
    <div class="note i"><b>💡 一个已存在的观感小瑕疵</b><div>
      <code>_clip_prefix</code> 内部的 <code>.strip()</code> 会把 <code>pre</code> 尾部的 <code>\n</code> 去掉，
      而拼接处也没有补回换行，于是前缀与正文直接相连（上面示例中的
      <code>…出场：素世、陆时雨下了整夜。</code>）。不影响检索与不变量，只是注入文本的可读性略差。
    </div></div>
    <h3 id="ingestflow-44">路径 B · 设定（每次写章末尾都跑一遍）</h3>
    <p>
      <code>writing_node</code> 末尾固定调用 <code>index_settings(LocalRAG(pid), state)</code>。
      注意它<b>与本章是否定稿无关</b>——设定不受"草稿不入库"约束，而且这里是收敛重复向量的时机。
    </p>
    <ol class="steps">
      <li><b>构造 entries</b><span>世界观每个字段一条 <code>世界观-{k}: {v}</code>；每个角色一条 <code>角色-{名}({定位}): 性格=…, 背景=…, 目标=…, 外貌=…, 说话方式=…</code>（带别名）；每条伏笔一条 <code>伏笔-{id}: {描述}</code>（<b>状态与埋于章号只进 payload</b>）。每类再按 <code>chunk_text(raw, chunk_size=CONTENT_BUDGET − len(前缀))</code> 切块，保证「前缀 + 正文 ≤ 379 ≤ 500」。</span></li>
      <li><b>定 id</b><span><code>_stable_point_id(source, key, i)</code> → <code>world_setting:setting:0</code> / <code>character:ch0:0</code> / <code>foreshadow:f07:1</code>。<b>与位置绑定，重复运行恒定</b>。</span></li>
      <li><b>前缀富化（入库前，逐块）</b><span><code>_setting_prefix()</code> 给<b>每一块</b>前置 <code>相关角色：素世、陆时\n</code>——只列本块真出现的，与身份前缀共用 120 字预算。<b>必须在 embedding 前做</b>，否则向量算完了再加前缀毫无意义。</span></li>
      <li><b>upsert</b><span><code>rag.add_texts(texts, metadatas, ids=...)</code>。id 稳定 → 同 id 直接覆盖，<b>写 100 次也还是那些块</b>。</span></li>
      <li><b>失败即停</b><span>返回空列表 → 记 warning「设定索引未更新，保留旧索引」→ <b>直接 return，不清理</b>。这就是「先写后删」的安全语义。</span></li>
      <li><b>清理陈旧块</b><span><code>_prune_stale_settings</code>：一次 scroll 覆盖三个域，删掉「键已不存在」或「<code>chunk_index ≥ 应有块数</code>」的块。</span></li>
    </ol>
    <h4 id="ingestflow-45">实测：一次 <code>index_settings</code> 产出的 entries</h4>
    <pre>id                         长度  source
world_setting:setting:0     244   world_setting   <span class="c"># 前缀「相关角色：素世、陆时」+ 正文</span>
character:ch0:0              49   character
character:ch1:0              46   character
character:ch2:0              41   character
foreshadow:f07:0             75   foreshadow</pre>
    <h4 id="ingestflow-46">陈旧块清理的两个触发情形（实测）</h4>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>作者的操作</th><th>库里原有</th><th>本次 entries</th><th>判定</th><th>结果</th></tr></thead>
        <tbody>
          <tr>
            <td>把伏笔描述从 444 字改短到 200 字</td>
            <td><code>f07:0, f07:1</code><br><small>（实测 444 字 → 2 块）</small></td>
            <td>只有 <code>f07:0</code></td>
            <td><code>want["foreshadow:f07"] = 1</code><br>库里 <code>chunk_index=1 ≥ 1</code></td>
            <td>删 <code>f07:1</code></td>
          </tr>
          <tr>
            <td>删掉了整个 <code>geography</code> 维度</td>
            <td><code>world_setting:geography:0..3</code></td>
            <td>无该键</td>
            <td><code>want.get(key) is None</code></td>
            <td>全部删除</td>
          </tr>
          <tr>
            <td>设定被<b>全部</b>清空</td>
            <td>各种</td>
            <td><code>entries == []</code></td>
            <td><b>仍必须调用清理</b></td>
            <td>全部删除<br><small>此处 return 就等于"保留旧索引"，而旧索引正是该删的那些</small></td>
          </tr>
        </tbody>
      </table>
    </div>
    <h3 id="ingestflow-47">路径 C · 上传文档</h3>
    <ol class="steps">
      <li><b>本地解析</b><span>txt/md 直接 decode；pdf/docx 本地解析，<b>不上传第三方</b>。超限返回 413。</span></li>
      <li><b>切块</b><span><code>chunk_text(text)</code> → <b>默认 500</b>。<b>上传文档用 500 是对的</b>：上传文档不做前缀富化，不需要给前缀预留预算，所以正文可以吃满 500，且仍 ≤ 注入截断（不变量①成立）。</span></li>
      <li><b>metadata</b><span><code>{type: "document", source: "document", doc_id, filename, chunk_index}</code>。<code>type</code> 是为兼容早期数据保留的冗余键。</span></li>
      <li><b>落库</b><span><code>rag.add_texts(chunks, metadatas)</code> —— <b>不传 ids</b>，因此不幂等：重复上传同一文件会产生两份向量。</span></li>
    </ol>
    <div class="note d"><b>✗ 正因如此，「重建索引」对 document 域故意不删</b><div>
      上传文档的 chunk <b>无法重建</b>——<b>原文不留存</b>，服务器上只有向量库里的那份文本。
      删掉 = 永久丢失作者的设定参考。所以 <code>reindex</code> 对 document 只<b>计数</b>，不删也不重嵌。
    </div></div>
    <h3 id="ingestflow-48">路径 D · 伏笔单独重建（以及一个已存在的不一致）</h3>
    <p>
      章节删除后要清理伏笔引用（埋下的删除 / 回收过的回滚），必须同步向量库，
      否则检索回来的仍是旧伏笔状态，模型会照着旧状态继续写。
    </p>
    <div class="note w"><b>⚠ 仅剩的一处差异：<code>index_foreshadow</code> 不带「相关角色」前缀</b><div>
      切块尺寸与身份前缀规则两条路径现已<b>完全一致</b>（共用 <code>_setting_prefix()</code> 与 <code>_body_budget()</code>），
      块数不会再互相拉锯——早前「一边切 379 一边切 500、导致 <code>f07:1</code> 被反复删建」的问题已修复。<br>
      剩下的唯一差别是 <code>index_foreshadow</code> 调用时传入空的角色表（<code>_char_entries({"character_settings": []})</code>），
      块里因此没有「相关角色：X」这一行 → 同一条伏笔经两条路径写出的向量不同，分数会有轻微漂移。
      <b>不影响正确性</b>；要完全消除，把 <code>index_foreshadow</code> 也接上 <code>_char_entries(state)</code> 即可。
    </div></div>
    <h3 id="ingestflow-49">入库之后，库里长什么样</h3>
    <p>一次「写第 13 章 + 点通过」之后，这个项目在 Qdrant 里的向量分布：</p>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>source</th><th>典型块数</th><th>块长</th><th>id</th><th>检索时能否被命中</th></tr></thead>
        <tbody>
          <tr><td><code>chapter</code></td><td>已定稿章节 × ~14 块/章</td><td>≤ 499</td><td><code>uuid4</code></td><td>✓ 保底检索（scope=story）</td></tr>
          <tr><td><code>world_setting</code></td><td>6 字段 × 1~4 块</td><td>≤ 500</td><td><code>world_setting:{field}:{i}</code></td><td>只在 scope=world 或 all</td></tr>
          <tr><td><code>character</code></td><td>≤12 人 × 1~2 块</td><td>≤ 500</td><td><code>character:{id}:{i}</code></td><td>只在 scope=character 或 all</td></tr>
          <tr><td><code>foreshadow</code></td><td>每条 1~2 块</td><td>≤ 500</td><td><code>foreshadow:{id}:{i}</code></td><td>✓ 保底检索（scope=story）</td></tr>
          <tr><td><code>document</code></td><td>按上传文件</td><td>≤ 500</td><td><code>uuid4</code></td><td>✓ 设定参考独立一路</td></tr>
        </tbody>
      </table>
    </div>
    <p>
      <b>草稿章节不在这个表里</b>——它们只存在于 body store。这是「只有定稿可被检索」这条保证的物理体现。
    </p>
  </div>
</section>
<!-- ===================== 08 分条召回 ===================== -->
<section id="retrieve">
  <div class="wrap">
    <div class="eyebrow">08 · Multi-Query Recall</div>
    <h2 id="retrieve">分条召回：本系统最核心的一个决策</h2>
    <p class="lead">
      这是整个 RAG 设计里影响最大的一处改动：<b>多个检索意图拆成多条查询分别检索，再合并。</b>
      如果你只读一节，读这一节。
    </p>
    <h3 id="retrieve-51">旧做法：拼成一条长串</h3>
    <p>早先的代码是把所有实体用空格连成一条 query：</p>
    <pre><span class="c">"第12章 雨夜 与 素世 的 对峙 未回收伏笔 陆时 素世 陆时 苏晚 ......"</span></pre>
    <h3 id="retrieve-52">为什么这行不通：向量拿到的是"质心"</h3>
    <p>
      一条长 query 经过 embedding，得到的向量代表的是<b>这些互不相关实体的质心（平均值）</b>。
      问题的严重性随实体数量增长：
    </p>
    <ul class="clean">
      <li>角色上限 12 个，本章往往<b>只出场 2 个</b>；</li>
      <li>另外 10 个名字把向量<b>摊平</b>，每个方面都召回不深；</li>
      <li>结果：<b>每个方面都召回不深</b>。看着"什么都有了"，其实什么都召不准。</li>
    </ul>
    <div class="vs">
      <div class="card warn">
        <h4 id="retrieve-53">拼成一条（质心）</h4>
        <div class="dots" style="justify-content:flex-start">
          <span class="d"></span><span class="d"></span><span class="d"></span>
          <span class="s"></span><span class="m"></span><span class="s"></span>
          <span class="d"></span><span class="d"></span><span class="d"></span>
        </div>
        <div class="legend" style="justify-content:flex-start;margin-top:8px">
          <span><i class="d"></i>无关 10 个</span><span><i class="m"></i>本章 2 个被摊薄</span>
        </div>
        <p style="margin-top:10px">"面"覆盖到了，"点"没覆盖到。</p>
      </div>
      <div class="mid">VS</div>
      <div class="card ok">
        <h4 id="retrieve-54">分条召回</h4>
        <div class="dots" style="justify-content:flex-start">
          <span class="m"></span><span class="s"></span><span class="m"></span>
          <span class="s"></span><span class="m"></span><span class="s"></span>
          <span class="m"></span><span class="s"></span><span class="m"></span>
        </div>
        <div class="legend" style="justify-content:flex-start;margin-top:8px">
          <span><i class="m"></i>每条查询各自贡献自己的第一名</span>
        </div>
        <p style="margin-top:10px">"点"被覆盖到，才谈得上准。</p>
      </div>
    </div>
    <h3 id="retrieve-55">子查询的构造顺序就是优先级</h3>
    <p>
      <code>build_story_queries_with_info</code> 按固定顺序拼装，然后<b>保序截断</b>到 <code>MAX_SUBQUERIES = 6</code>：
    </p>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>顺序</th><th>来源</th><th>条数</th><th>为什么排这个位置</th></tr></thead>
        <tbody>
          <tr><td>1</td><td><b>本章章纲</b>（标题 + 梗概）</td><td>1</td><td>本章的意图本身，最不该被挤掉</td></tr>
          <tr><td>2</td><td><b>未回收伏笔</b>描述</td><td>≤ 2<br><code>MAX_FORESHADOW_SUBQUERIES</code></td><td>伏笔遗漏是<b>明确的写作事故</b>（读者视角的"作者忘了"），固定留名额，不按列表顺序截断</td></tr>
          <tr><td>3</td><td><b>出场角色</b>：<code>规范名 + 别名（≤3）+ 身份</code></td><td>剩余名额</td><td>先给"章纲/门禁/提名里点到名的"，再给其他。别名<b>合并进同一条</b>子查询；独立成条会挤掉伏笔与出场角色的名额</td></tr>
          <tr><td>—</td><td><b>非出场角色</b></td><td>剩余名额</td><td>兜底：可能临时出场，也可能是被提及</td></tr>
        </tbody>
      </table>
    </div>
    <h4 id="retrieve-56">「出场」的判定依据</h4>
    <p>
      <code>_chapter_stage_text</code> 取三个来源，都是作者/LLM <b>已经明确表达过</b>的本章意图：
    </p>
    <ul class="clean">
      <li><b>本章章纲</b>的标题 + 梗概（章纲里点名的人就是要出场的人）；</li>
      <li><b>写作门禁卡</b>上的「本章必写情节点」（作者手填，权威性最高）；</li>
      <li><b>本章提名的新角色</b>（<code>chapter_new_characters</code>，等作者勾选）。</li>
    </ul>
    <p>
      判定仍是<b>纯字符串包含、没有语义推断</b>（刻意保持确定性），但匹配的是<b>规范名 + 全部别名</b>（<code>_all_names()</code>）——
      章纲里写「阿晚出场」必须能认出那就是「林晚」，否则最该检索的人会被挤出 <code>MAX_SUBQUERIES</code>。
    </p>
    <h4 id="retrieve-57">一个曾经漏掉角色的 bug</h4>
    <p>
      此前是按 <code>character_settings</code> <b>数组顺序</b>截断，于是角色一多就必然漏：
      扣掉章纲 1 条 + 伏笔 2 条，只剩 3 个名额，而本章真正出场的人很可能在数组末尾——
      <b>漏检的还是最该检的那几个</b>。现在出场角色排前面，问题消失。
    </p>
    <div class="note g"><b>✓ 丢弃必须记账</b><div>
      被截断的内容记在 <code>dropped</code> / <code>dropped_queries</code> 里并写进日志与检索账目。
      <b>静默丢弃等于让作者以为"这个角色的设定这次没被需要"</b>——这种结果其实是漏检。
    </div></div>
    <h3 id="retrieve-58">性能：一次批量 embedding + 6 线程并发</h3>
    <div class="diagram">
      <div class="flow" style="padding-top:22px">
        <div class="node plain">6 条子查询</div>
        <span class="arw"></span>
        <div class="node gate">embed_queries（一次批量）<small>1 次 HTTP 往返</small></div>
        <span class="arw"></span>
        <div class="node soft">ThreadPoolExecutor(6)<small>并发 search_dense_leg<br>（稀疏开启时同池再提交 search_sparse_leg）</small></div>
        <span class="arw"></span>
        <div class="node">每条各取 top-3<small>PER_SUBQUERY_TOP_K</small></div>
      </div>
      <div class="flow-bar">
        <b>写一章要走三路检索，合计 30+ 次网络调用</b>
        <small>逐条串行会把延迟叠加得很明显；并发是安全的（彼此独立、只读）。但不宜开太大——远端 embedding 服务有限流</small>
      </div>
      <div class="cap">图 5 · 分条召回的快路径：批量 embedding 一次拿全部，检索并发</div>
    </div>
    <p>
      降级路径也存在：<code>rag</code> 不支持批量接口（测试替身）或 embedding 不可用时，退回逐条
      <code>search()</code>，此时拿不到第二条返回值，<code>stats</code> 里<b>不填该字段</b>
      （填 0 会掩盖"没测到"这件事）。
    </p>
    <h3 id="retrieve-59">合并：按名次轮转</h3>
    <p>这是分条召回真正兑现价值的地方，也是最容易被"优化"坏的地方。</p>
    <div class="vs">
      <div class="card warn">
        <h4 id="retrieve-60">全局按分数重排（错的）</h4>
        <p>「项目背景」这类宽泛子查询的<b>高分命中会把 top-k 全占满</b>。各角色、各伏笔自己的命中永远进不来。</p>
        <p style="color:var(--danger)"><b>换汤不换药</b>，依旧被一条查询主导——分条白做了。</p>
      </div>
      <div class="mid">VS</div>
      <div class="card ok">
        <h4 id="retrieve-61">名次轮转（本系统）</h4>
        <p>排序键是 <code>(名次, 子查询顺序)</code>：<b>第 1 名轮流取一遍，再取第 2 名，依次下推</b>。</p>
        <p style="color:var(--ok)"><b>每条子查询至少贡献自己的第一名</b>，覆盖面才真的换来了。</p>
      </div>
    </div>
    <pre><span class="c"># 子查询：Q0=章纲  Q1=伏笔a  Q2=伏笔b  Q3=素世  Q4=陆时</span>
Q0: [<span class="s">0.71</span>, 0.38, 0.30]
Q1: [<span class="s">0.66</span>, 0.41]
Q2: [<span class="s">0.64</span>]
Q3: [<span class="s">0.69</span>, 0.44, 0.35]
Q4: [<span class="s">0.67</span>, 0.36]
<span class="c"># 轮转结果（k=5）：Q0#1 . Q1#1 . Q2#1 . Q3#1 . Q4#1</span>
<span class="c">#   0.71      0.66     0.64     0.69     0.67</span>
<span class="c"># 全局排序会选：0.71 . 0.69(Q3) . 0.67(Q4) . 0.66 . 0.64 —— 分不出差别？</span>
<span class="c"># 但当 Q0 有 10 条高分时，全局排序下 Q1~Q4 一条都进不了前 5。</span></pre>
    <div class="note i"><b>💡 确定性是这个设计的硬要求</b><div>
      排序只依赖「名次 + 子查询顺序」两个<b>确定性输入</b>，不依赖字典遍历顺序或时间。
      因此<b>同输入同结果</b>：每章上下文稳定、防 OOC、可重跑、时间旅行能复现。
      这也是为什么<b>没有</b>引入 LLM 做"重排 / rerank"——那会引入随机性。
    </div></div>
    <h3 id="retrieve-62">去重：同一块被多条查询召回时必须收敛</h3>
    <p>
      不收敛的后果是<b>同一段内容在 prompt 里重复出现</b>（挤占 top-k），引用卡也会出现重复条目。
      去重键按优先级取：
    </p>
    <ul class="clean">
      <li>优先「<code>source</code> + 该来源主键 + <code>chunk_index</code>」：<code>chapter:chapter_id=c05:chunk=2</code></li>
      <li>主键字段依次尝试：<code>chapter_id / doc_id / character_id / foreshadow_id / field / id</code></li>
      <li>都拿不到时回落到<b>内容前缀 120 字</b></li>
    </ul>
    <p>
      合并完成后 <code>stats["duplicates"] = kept_hits − merged</code>。注意它统计的是
      <b>「候选里没进最终名单的条数」</b>——真去重与被 <code>k</code> 截断都算在内，
      所以<b>它通常不为 0，且单独看它判断不出重叠是否严重</b>。详见<a href="#queryflow">第 11 节</a>的实测拆解。
    </p>
  </div>
</section>
<!-- ===================== 08 阈值 ===================== -->
<section id="threshold">
  <div class="wrap">
    <div class="eyebrow">09 · Threshold</div>
    <h2 id="threshold">阈值 0.45 怎么来的，以及为什么必须有阈值</h2>
    <h3 id="threshold-64">分数的含义</h3>
    <p>
      相关度 <code>score</code> 由 Qdrant 的<b>余弦相似度</b>换算而来：
      <code>score = 1 - distance</code>，其中 <code>distance = 1 - cosine_similarity</code>，
      所以 <code>score</code> <b>就是余弦相似度本身</b>，范围 −1 ~ 1，越大越像。
    </p>
    <p>
      没有阈值的话，检索会<b>永远返回 top-k</b>，哪怕最不像的那条也有 0.31 分。
      于是 prompt 里塞满"其实不相关"的段落，<b>噪声挤占了正文的预算</b>。
    </p>
    <h3 id="threshold-65">标定过程（实测数据）</h3>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>样本</th><th>分数</th><th>结论</th></tr></thead>
        <tbody>
          <tr><td>完全无关的查询（噪声地板）</td><td><b>0.4297</b></td><td>阈值必须<b>高于</b>它，否则噪声会被召回</td></tr>
          <tr><td>真命中的首位结果</td><td><b>0.5498 ～ 0.7135</b></td><td>阈值必须<b>低于</b>它，否则真命中被砍</td></tr>
          <tr><td>第 3～4 位边缘命中</td><td><b>0.41 ～ 0.49</b></td><td>与噪声重叠，会被误伤——这就是代价</td></tr>
        </tbody>
      </table>
    </div>
    <p>
      0.45 取在噪声地板（0.4297）与真命中下界（0.5498）之间，<b>刻意不取中点</b>：
      宁可多要一点边缘命中，也别放进噪声——噪声会挤占预算并误导模型。
    </p>
    <div class="note i"><b>💡 怎么调</b><div>
      更保守（少误伤、多漏检）调 <code>0.35</code>；更干净（少噪声、多漏检）调 <code>0.55</code>。
      因为这套值只在<b>真 embedding</b>下有意义，所以"哈希兜底时豁免阈值"的分支已被一并移除。
    </div></div>
    <div class="note w"><b>⚠ 阈值会静默丢掉一批块</b><div>
      这是最容易被忽视的一点：作者看到的引用卡条数与"检索到的条数"对不上，
      因为中间有一批被阈值筛掉了。设计意图是让 <code>search_dense_leg</code>
      同时返回「阈值后的命中」和「阈值前的命中数」，从而区分
      <b>"向量库里没有"</b>（该重建索引了）和<b>"有但不够像"</b>（阈值太严要调）。<br>
      <b>但实测：当前实现 <code>return hits, len(hits)</code> 的两个值都是阈值<i>之后</i>的</b>——
      该区分目前<b>拿不到</b>，详见<a href="#queryflow">第 11 节</a>的实测说明。
    </div></div>
  </div>
</section>
<!-- ===================== 09 域过滤 ===================== -->
<section id="scope">
  <div class="wrap">
    <div class="eyebrow">10 · Scope Filtering</div>
    <h2 id="scope">域过滤：只查该查的，别的一律不看</h2>
    <p class="lead">
      <code>metadata.source</code> 到检索域的映射由 <code>SCOPE_SOURCE</code> 定义，
      翻译成 Qdrant 的等值过滤（<code>MatchValue</code> / <code>MatchAny</code>）。
      过滤在<b>向量检索阶段</b>就生效，所以不需要"取回来再筛"——top-k 全部是被允许的域。
    </p>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>scope</th><th>映射为</th><th>谁在用</th></tr></thead>
        <tbody>
          <tr><td><code>chapter</code></td><td><code>source = "chapter"</code></td><td>定向查某一类</td></tr>
          <tr><td><code>character</code></td><td><code>source = "character"</code></td><td>定向查某一类</td></tr>
          <tr><td><code>world</code> / <code>world_setting</code></td><td><code>source = "world_setting"</code></td><td>定向查某一类</td></tr>
          <tr><td><code>document</code></td><td><code>source = "document"</code></td><td><b>设定参考独立一路</b></td></tr>
          <tr><td><code>foreshadow</code></td><td><code>source = "foreshadow"</code></td><td>定向查某一类</td></tr>
          <tr>
            <td><b><code>story</code></b></td>
            <td><code>source ∈ [chapter, foreshadow]</code></td>
            <td><b>保底检索专用域</b>：只查 prompt 里<b>没有</b>的东西</td>
          </tr>
          <tr><td><code>all</code></td><td>无过滤</td><td>LLM 计划资料的兜底</td></tr>
        </tbody>
      </table>
    </div>
    <h3 id="scope-67">为什么保底检索要排除 character 和 world_setting</h3>
    <div class="vs">
      <div class="card warn">
        <h4 id="scope-68">如果它们还在保底域里</h4>
        <ul class="clean" style="font-size:14px;margin:0">
          <li>同一份设定在 prompt 里<b>出现两份</b></li>
          <li>一份完整直塞、一份被 500 字截断</li>
          <li>模型<b>分不清哪份是权威</b></li>
          <li>还白占 token</li>
        </ul>
      </div>
      <div class="mid">VS</div>
      <div class="card ok">
        <h4 id="scope-69">排除后保底检索只剩两件事</h4>
        <ul class="clean" style="font-size:14px;margin:0">
          <li>召回<b>已定稿前情正文</b>——量无界，只能检索</li>
          <li>召回<b>伏笔</b>——此前从未直塞，<b>只能靠检索进 prompt</b></li>
        </ul>
      </div>
    </div>
    <p>这正是它该做的：<b>只补 prompt 里缺的那一块，不重复已经有的。</b></p>
    <h3 id="scope-70">时间偏置：防止上下文漂移</h3>
    <p>
      <code>_bias_metadata</code> 在合并之后做一次轻量重排：<b>确保最近 <code>window = 5</code> 章的正文块被包含</b>，
      其余位置由原结果补全。
    </p>
    <p>
      理由是防<b>上下文漂移</b>：如果本章该发生的事与第 28 章强相关，
      但 top-k 被第 3 章的相似片段占满，模型就会"忘记"最近发生了什么。
      这个偏置是<b>确定性的</b>（只依赖 <code>chapter_index</code> 与 <code>idx</code>），不引入随机性。
    </p>
    <h3 id="scope-71">为什么 `rag_search_direct` 绕开工具封装</h3>
    <p>
      章纲阶段预取的「本章写作资料」走 <code>rag_search_direct</code>，绕开 LangGraph 的
      <code>rag_search</code> 工具。原因是后者依赖 prebuilt agent 自动注入
      <code>tool_call_id</code> / <code>config</code>，在节点内手动 <code>invoke</code> 会因缺少
      <code>InjectedToolCallId</code> 而抛错。
    </p>
    <p>
      更重要的是<b>它已被移除的那部分</b>：早期版本有「agentic rag_search 工具 ReAct 循环」——
      让模型自己决定查什么、查几轮。现在资料清单在<b>章纲阶段一次性备齐</b>，
      写作阶段<b>零临时检索</b>。理由是行为可复现：同样的输入必须得到同样的上下文，
      否则「时间旅行回退到上一版」就没有意义了。
    </p>
  </div>
</section>
<!-- ===================== 11 检索实战 ===================== -->
<section id="queryflow">
  <div class="wrap">
    <div class="eyebrow">11 · Retrieval Walkthrough</div>
    <h2 id="queryflow">一次章生成的查询全过程（真实调用逐行拆解）</h2>
    <p class="lead">
      这一节用<b>一个具体的项目状态</b>把第 08～10 节串起来跑一遍。
      下面出现的子查询文本、命中排序、账目字段，都是实际调用
      <code>build_story_queries_with_info</code> / <code>_merge_round_robin</code> /
      <code>_bias_metadata</code> 得到的<b>真实输出</b>（向量分数为示意值，用于说明排序逻辑）。
    </p>
    <h3 id="queryflow-73">场景：写第 13 章（<code>current_chapter_index = 12</code>）</h3>
    <pre><span class="c"># State 中与检索相关的部分</span>
outline[0].chapters[12] = {
    "index": 12, "title": "第13章 对峙",
    "summary": "素世在雨夜与陆时对峙，终于说出三年前那场事故的真相；第7章埋下的钥匙扣在此回收。"
}
stage_gate.notes.must   = "必须写出钥匙扣的来历，且与第7章一致"
chapter_new_characters  = [{"name": "苏晚"}]
foreshadow = [
    {"id":"f07","description":"陆时随身带的旧钥匙扣，来自三年前那场事故","status":"pending","planted_chapter_index":6},
    {"id":"f11","description":"苏晚的左手手腕有一道疤",              "status":"pending","planted_chapter_index":9},
    {"id":"f03","description":"便利店老板记得每一个深夜来的客人",      "status":"resolved","planted_chapter_index":2},
]
character_settings = 12 人：素世(主角) 陆时(男主) 苏晚(配角) 陈教授 阿枝 林伯 周医生 阿七 小满 老赵 阿九 陆母</pre>
    <h3 id="queryflow-74">第 1 步 · 构造子查询</h3>
    <p><code>build_story_queries_with_info(state, 12)</code> 按固定顺序拼装：</p>
    <pre><span class="c"># ① 章纲 1 条 → ② 未回收伏笔 ≤2 条 → ③ 出场角色 → ④ 其他角色</span>
items = [
  "第13章 对峙 素世在雨夜与陆时对峙，终于说出三年前那场事故的真相；第7章埋下的钥匙扣在此回收。",
  "陆时随身带的旧钥匙扣，来自三年前那场事故",     <span class="c"># f07 (pending)</span>
  "苏晚的左手手腕有一道疤",                      <span class="c"># f11 (pending)</span>
  "素世 主角", "陆时 男主", "苏晚 配角",           <span class="c"># on_stage（出场优先）</span>
  "陈教授 配角", "阿枝 配角", "林伯 配角", ... , "陆母 配角",   <span class="c"># off_stage（9 人）</span>
]
<span class="c"># 注意 f03 是 resolved，不参与</span></pre>
    <p>
      <b>「出场」怎么判定的</b>：<code>_chapter_stage_text</code> 把
      <i>章纲标题 + 梗概 + 门禁必写点 + 新角色提名</i> 拼成一段文本，
      再做简单的 <code>名字 in 文本</code> 包含判断：
    </p>
    <pre>stage_text = "第13章 对峙 素世在雨夜与陆时对峙… 必须写出钥匙扣的来历，且与第7章一致 苏晚"
on_stage   = ["素世", "陆时", "苏晚"]      <span class="c"># 素世/陆时来自章纲，苏晚来自新角色提名</span>
off_stage  = ["陈教授", "阿枝", "林伯", "周医生", "阿七", "小满", "老赵", "阿九", "陆母"]</pre>
    <h4 id="queryflow-75">实际输出（<code>_dedup_queries</code> 清洗 → 去重 → 保序截断到 6）</h4>
    <pre>Q0: 第13章 对峙 素世在雨夜与陆时对峙，终于说出三年前那场事故的真相；第7章埋下的钥匙扣在此回收。
Q1: 陆时随身带的旧钥匙扣，来自三年前那场事故
Q2: 苏晚的左手手腕有一道疤
Q3: 素世 主角
Q4: 陆时 男主
Q5: 苏晚 配角
info = {
  "on_stage": ["素世", "陆时", "苏晚"],
  "dropped": 9,                                  <span class="c"># 15 - 6</span>
  "dropped_queries": ["陈教授 配角", "阿枝 配角", "林伯 配角", ... ],
}</pre>
    <div class="note w"><b>⚠ 这里有 9 个角色本次没被检索</b><div>
      <code>dropped = 9</code> 会被写进检索账目和日志，属于<b>漏检信号</b>，需要处理——
      如果本章其实需要某个 off_stage 角色的设定，正确做法是把他的名字写进章纲或门禁必写点，
      让他进入 <code>on_stage</code>。<br>
      <small>另注：判定用的是<b>子串包含</b>，所以名字很短的角色（如单字名）容易被误判为出场。</small>
    </div></div>
    <h3 id="queryflow-76">第 2 步 · 批量 embedding（一次往返）</h3>
    <p>
      <code>rag.embed_queries(kept)</code> → <code>_embed(6 条)</code> →
      <code>embeddings.embed_texts(texts)</code>：
    </p>
    <pre><span class="c"># 逐条查进程内缓存 _CACHE（上限 512 条）</span>
命中 → 直接用
未命中 → 按 EMBEDDING_BATCH_SIZE=32 打包，POST {base}/embeddings
         body = {"model": "BAAI/bge-m3", "input": [6 条文本]}
         → 返回 6 × 1024 维向量</pre>
    <div class="note g"><b>✓ 缓存在这条链路上特别有效</b><div>
      Q0～Q5 的文本<b>完全由 State 决定</b>：只要章纲、伏笔、角色没改，
      同一章重跑时这 6 条文本<b>一字不差</b> → 全部命中缓存 → <b>零 HTTP 请求</b>。
      这也是为什么"驳回重跑"很快：embedding 那一段几乎不花钱。
    </div></div>
    <h3 id="queryflow-77">第 3 步 · 并发向量检索（6 线程）</h3>
    <p>域过滤 <code>scope="story"</code> 先被翻译成 Qdrant Filter：</p>
    <pre>_scope_filter("story")  →  {"source": ["chapter", "foreshadow"]}
                           →  Filter(must=[FieldCondition(key="source", match=MatchAny(any=[...]))])</pre>
    <p>然后 <code>ThreadPoolExecutor(max_workers=6)</code> 并行执行 6 次 <code>rag.search_dense_leg(vec_i, leg_k, flt)</code>
      （<code>leg_k = PER_SUBQUERY_TOP_K = 3</code>；稀疏路开启时为 <code>max(3×3, _SPARSE_LEG_K=10)</code>）。
      注意写章路径<b>不走</b> <code>search_by_embedding</code>——那个函数会把两路串行化，代价更大：</p>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>子查询</th><th>向量库返回（按分数降序，top-3）</th><th>0.45 阈值后</th></tr></thead>
        <tbody>
          <tr><td>Q0 章纲</td><td>c05#2 <b>0.68</b> · c07#0 <b>0.52</b> · c11#3 <b>0.47</b></td><td>3 条</td></tr>
          <tr><td>Q1 伏笔 f07</td><td>f07:0 <b>0.79</b> · c06#1 <b>0.51</b> · c03#4 0.44</td><td>2 条<br><small>0.44 被砍</small></td></tr>
          <tr><td>Q2 伏笔 f11</td><td>f11:0 <b>0.74</b> · c09#2 0.43</td><td>1 条<br><small>0.43 被砍</small></td></tr>
          <tr><td>Q3 素世</td><td>c11#1 <b>0.71</b> · c08#0 <b>0.63</b> · c02#3 <b>0.58</b></td><td>3 条</td></tr>
          <tr><td>Q4 陆时</td><td>c11#4 <b>0.66</b> · c05#0 <b>0.59</b> · f07:0 <b>0.55</b></td><td>3 条</td></tr>
          <tr><td>Q5 苏晚</td><td>c11#1 <b>0.61</b> · c10#2 <b>0.55</b></td><td>2 条</td></tr>
        </tbody>
      </table>
    </div>
    <p><small><code>c05#2</code> = 第 6 章（<code>chapter_index=5</code>）的第 2 块；<code>f07:0</code> = 伏笔 f07 的第 0 块。</small></p>
    <h3 id="queryflow-78">第 4 步 · 轮转合并去重（<code>k = 8</code>）</h3>
    <p>排序键是 <code>(名次, 子查询序号)</code>，先取全部第 1 名，再取全部第 2 名，依次下推：</p>
    <pre>轮转顺序：(0,Q0)c05#2 → (0,Q1)f07:0 → (0,Q2)f11:0 → (0,Q3)c11#1 → (0,Q4)c11#4
         → (0,Q5)c11#1 <span class="k">← 与 (0,Q3) 同 key，去重跳过</span>
         → (1,Q0)c07#0 → (1,Q1)c06#1 → (1,Q3)c08#0 <span class="c">← 取满 8 条，停止</span></pre>
    <h4 id="queryflow-79">实际输出</h4>
    <pre>  1. c05#2   score=0.68   key=chapter:chapter_id=c05:chunk=2
  2. f07:0   score=0.79   key=foreshadow:foreshadow_id=f07:chunk=0
  3. f11:0   score=0.74   key=foreshadow:foreshadow_id=f11:chunk=0
  4. c11#1   score=0.71   key=chapter:chapter_id=c11:chunk=1
  5. c11#4   score=0.66   key=chapter:chapter_id=c11:chunk=4
  6. c07#0   score=0.52   key=chapter:chapter_id=c07:chunk=0
  7. c06#1   score=0.51   key=chapter:chapter_id=c06:chunk=1
  8. c08#0   score=0.63   key=chapter:chapter_id=c08:chunk=0
stats = {"raw_hits": 14, "kept_hits": 14, "duplicates": 6}
sources(合并后) = {"chapter": 6, "foreshadow": 2}</pre>
    <div class="note i"><b>💡 注意第 6 条：c07#0 只有 0.52 分，却排在 c08#0（0.63）前面</b><div>
      这正是<b>名次轮转</b>的直接体现：c07#0 是 Q0 的第 <b>2</b> 名，c08#0 是 Q3 的第 <b>2</b> 名，
      按 <code>(名次, 子查询序号)</code> 排序，Q0 先于 Q3。
      牺牲了一点绝对分数，换来的是<b>每条子查询都至少贡献自己的第一名</b>。
      代价与替代方案见第 17 节。
    </div></div>
    <div class="note d"><b>⚠ 账目字段的两个命名陷阱（实测确认）</b><div>
      · <code>raw_hits</code> 的 docstring 写的是「阈值<b>前</b>的命中数」，
        但 <code>search_dense_leg</code> 实际 <code>return hits, len(hits)</code> ——
        <b>阈值已经过滤过了</b>，所以 <code>raw_hits</code> 恒等于 <code>kept_hits</code>（本例都是 14）。
        想看"阈值砍掉了多少"目前<b>拿不到</b>。<br>
      · <code>duplicates</code> 的公式是 <code>kept_hits − merged</code>（本例 14−8=6），
        它统计的是<b>「候选里没进最终名单的条数」</b>，其中只有 1 条是真去重（c11#1 重复），
        其余 5 条是被 <code>k=8</code> 截断的。<b>两者当前无法区分。</b>
    </div></div>
    <h3 id="queryflow-80">第 5 步 · 时间偏置（<code>window = 5</code>）</h3>
    <p>
      <code>_bias_metadata(results, state, idx=12, window=5)</code> 把
      <code>7 ≤ chapter_index &lt; 12</code>（即第 8～12 章）的块提到前面：
    </p>
    <div class="vs">
      <div class="card">
        <h4 id="queryflow-81">偏置前</h4>
        <p style="font-family:var(--mono);font-size:12.5px;margin:0">
          c05#2(ci=5) · f07:0 · f11:0 · c11#1(11) · c11#4(11)<br>
          c07#0(7) · c06#1(6) · c08#0(8)
        </p>
      </div>
      <div class="mid">→</div>
      <div class="card ok">
        <h4 id="queryflow-82">偏置后</h4>
        <p style="font-family:var(--mono);font-size:12.5px;margin:0">
          <b>c11#1(11) · c11#4(11) · c07#0(7) · c08#0(8)</b><br>
          c05#2(5) · f07:0 · f11:0 · c06#1(6)
        </p>
      </div>
    </div>
    <p>
      最近 5 章的块被提到最前，其余按原顺序补全，总数仍是 8。
      <code>sources</code> 不变（chapter 6 / foreshadow 2），<code>stats["merged"] = 8</code>。
    </p>
    <h3 id="queryflow-83">第 6 步 · 格式化注入</h3>
    <p>
      <code>format_hits(biased)</code> → <code>_format_context</code> 给每块加 <code>[出处]</code> 与相关度，
      并对内容做 <code>_injectable</code>（截断到 500）。由于块本身 ≤ 499，
      <b>这里永远不会真的截断</b>：
    </p>
    <pre>=== 相关检索结果 ===
[1] (相关度: 0.71) [第12章 雨夜]【第12章 雨夜】素世与陆时在雨中对峙，陆时终于说出三年前事故的真相。
出场：素世、陆时雨下了整夜。素世站在便利店门口，看着对街那盏忽明忽暗的灯。……
[2] (相关度: 0.79) [伏笔·f07]伏笔-f07: 陆时随身带的旧钥匙扣，来自三年前那场事故
[3] (相关度: 0.74) [伏笔·f11]伏笔-f11: 苏晚的左手手腕有一道疤
……</pre>
    <p><small>伏笔的「状态」与「埋于第 N 章」<b>只在 payload 里</b>，不进文本——它们永远匹配不到任何查询，
    却会让每次状态变更都必须重新 embedding。引用卡上的 <code>[伏笔·f07]</code> 标签才是它们的展示位置。</small></p>
    <p><small>注意第 1 条出现了两次章节标题：一次来自引用卡的 <code>[出处]</code> 前缀（<code>outline_title</code>），
    一次来自块自身的入库前缀。这是真实行为，不影响检索。</small></p>
    <h3 id="queryflow-84">第 7 步 · 第二路与第三路检索</h3>
    <p>保底检索只是<b>三路之一</b>。同一章写作还并行发生：</p>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>路</th><th>scope</th><th>查询来源</th><th>k</th><th>注入形态</th></tr></thead>
        <tbody>
          <tr>
            <td><b>① 保底</b></td><td><code>story</code></td>
            <td>上面 6 条子查询</td><td>8</td>
            <td><code>baseline</code>，放进 system prompt 末尾</td>
          </tr>
          <tr>
            <td><b>② 设定参考</b></td><td><code>document</code></td>
            <td><code>build_doc_queries</code>：写正文时复用<b>同一套</b>章纲子查询；早期无章纲时回落项目背景 + 世界观各维度 + 已有角色名</td>
            <td>4</td>
            <td><code>doc_reference_block(...)</code> → <b>硬约束区块</b>（有修改要求时自动降级措辞）</td>
          </tr>
          <tr>
            <td><b>③ 资料预取</b></td><td>清单里各自指定，兜底 <code>all</code></td>
            <td>章纲阶段 LLM 产出的资料清单 <code>_plan_chapter_lookups</code></td>
            <td>每条 3</td>
            <td>在<b>章纲阶段</b>就固化成「本章写作资料」（≤4000 字），写作阶段直接使用</td>
          </tr>
        </tbody>
      </table>
    </div>
    <p>
      ② 的失败被单独 <code>try/except</code> 包住：检索失败只记 warning，
      <b>不注入</b>，但绝不断掉写作。
    </p>
    <h3 id="queryflow-85">第 8 步 · 下发引用卡与检索账目</h3>
    <p>
      <code>to_citations([*doc_hits, *base_hits])</code> —— <b>设定参考排在前面</b>（作者最关心），
      按 <code>(type, id)</code> 去重，上限 12 条：
    </p>
    <pre>[
  {"type":"document",   "id":"d9f2a1",   "label":"设定参考·世界观手册.pdf", "snippet":"月之森位于大陆东侧…", "score":0.612},
  {"type":"foreshadow", "id":"f07",      "label":"伏笔·f07",              "snippet":"伏笔-f07: 陆时随身带的旧钥匙扣…", "score":0.790},
  {"type":"foreshadow", "id":"f11",      "label":"伏笔·f11",              "snippet":"伏笔-f11: 苏晚的左手手腕有一道疤…", "score":0.740},
  {"type":"chapter",    "id":"c11",      "label":"第12章 雨夜",            "snippet":"【第12章 雨夜】素世与陆时在雨中对峙…", "score":0.710},
  {"type":"chapter",    "id":"c05",      "label":"第6章 便利店",           "snippet":"……", "score":0.680},
  ...
]</pre>
    <p>
      注意引用卡按 <code>(type, id)</code> 去重，所以 <code>c11#1</code> 和 <code>c11#4</code>
      在界面上<b>只显示一条</b>「第12章 雨夜」——注入是 2 块，卡片是 1 条。
    </p>
    <h4 id="queryflow-86">完整的 <code>retrieval_stats</code></h4>
    <pre>{
  "backend": "remote",                  <span class="c"># remote = 云端 Qdrant；local = 本地模式</span>
  "embedding": "ok",                    <span class="c"># unavailable = 远端不可用，本次没检索</span>
  "scope": "story",
  "scope_label": "前情正文 + 伏笔",
  "queries": 6,                         <span class="c"># 实际检索的子查询条数</span>
  "min_score": 0.45,
  "raw_hits": 14,                       <span class="c"># ⚠ 实为「阈值后」之和，见第 4 步的注</span>
  "kept_hits": 14,
  "duplicates": 6,                      <span class="c"># ⚠ 实为「候选未入选」= 去重 1 + 截断 5</span>
  "merged": 8,                          <span class="c"># 最终注入条数</span>
  "sources": {"chapter": 6, "foreshadow": 2},
  "on_stage": ["素世", "陆时", "苏晚"],
  "dropped": 9,                         <span class="c"># 触顶未检索 —— 漏检信号</span>
  "dropped_queries": ["陈教授 配角", "阿枝 配角", ...],
  "document": {"scope":"document", "queries":6, "merged":3, "min_score":0.45, ...},
  "direct": {"world": 6, "characters": 12, "prev_tail_chars": 1200}
}</pre>
    <h3 id="queryflow-87">全流程一览</h3>
    <div class="diagram">
      <div class="stack w-lg">
        <div class="box blue"><b>State（章纲 / 伏笔 / 角色 / 门禁）</b><small>纯确定性输入，不依赖时间或网络</small></div>
        <div class="link"><em>build_story_queries_with_info</em><i></i></div>
        <div class="box"><b>6 条子查询 + dropped 记账</b><small>章纲 1 · 伏笔 2 · 角色 3（出场优先）</small></div>
        <div class="link"><em>embed_queries：一次批量，缓存命中则不发请求</em><i></i></div>
        <div class="box"><b>6 × 1024 维向量</b><small>source ∈ [chapter, foreshadow] 域过滤</small></div>
        <div class="link"><em>6 线程并发，各取 top-3 → 阈值 0.45</em><i></i></div>
        <div class="box mark"><b>14 条候选</b><small>Q0×3 Q1×2 Q2×1 Q3×3 Q4×3 Q5×2</small></div>
        <div class="link"><em>轮转合并 + 去重 + 取前 8</em><i></i></div>
        <div class="box"><b>8 条命中</b><small>chapter 6 / foreshadow 2</small></div>
        <div class="link"><em>时间偏置（最近 5 章提前）</em><i></i></div>
        <div class="box blue"><b>注入 prompt（每块 ≤500 字）+ 引用卡 + 检索账目</b><small>同输入 → 同结果 → 可重跑、可时间旅行</small></div>
      </div>
      <div class="cap">图 6 · 一次章生成的检索全过程（数字来自本节实测）</div>
    </div>
    <div class="note g"><b>✓ 一句话概括这条链路的取向</b><div>
      从 State 出发，经过<b>完全确定</b>的变换，得到一份<b>每次都一样</b>的上下文。
      没有 LLM 参与决策（资料清单那一次除外，且它发生在章纲阶段并已被固化），
      没有随机重试，没有时间依赖。这是「时间旅行回退后能复现同一版正文」的前提。
    </div></div>
  </div>
</section>
<!-- ===================== 12 注入 ===================== -->
<section id="inject">
  <div class="wrap">
    <div class="eyebrow">12 · Injection</div>
    <h2 id="inject">注入：检索到了，还得能"用得上"</h2>
    <p class="lead">
      检索成功不等于模型会正确使用。这里有<b>三件事</b>决定注入质量：带出处、算预算、定措辞。
    </p>
    <h3 id="inject-89">一、每块必须带出处前缀</h3>
    <p>
      <code>_format_context</code> 给每一块加一个 <code>[出处]</code> 前缀和 <code>(相关度: 0.71)</code>：
    </p>
    <pre><span class="c">=== 相关检索结果 ===</span>
[1] (相关度: 0.71) [第12章 雨夜]……他缓缓抬起手，指尖还沾着未干的血迹。
[2] (相关度: 0.69) [素世] 相关角色：陆时……素世把伞往他那边偏了三寸。
[3] (相关度: 0.67) [设定参考·世界观手册.pdf] 月之森位于大陆东侧，学制为三学期制……</pre>
    <p>
      没有前缀会怎样：文档块不带 <code>filename</code> 时会渲染成
      「注入的设定参考片段不带任何出处」，<b>模型无从分辨这是作者给的硬设定还是普通前情</b>——
      同样的内容，标不标注，模型当它是"参考"还是"必须遵守"，行为完全不同。
    </p>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>source</th><th>前缀形态</th></tr></thead>
        <tbody>
          <tr><td><code>document</code></td><td><code>设定参考·{filename}</code></td></tr>
          <tr><td><code>world_setting</code></td><td><code>世界观·{field}</code>（必须标明维度，否则模型不知道碎片归属）</td></tr>
          <tr><td><code>foreshadow</code></td><td><code>伏笔·{foreshadow_id}</code></td></tr>
          <tr><td><code>chapter</code> / 其他</td><td><code>{outline_title 或 title 或 filename}</code></td></tr>
        </tbody>
      </table>
    </div>
    <h3 id="inject-90">二、预算：每块 500 字，一共几块</h3>
    <p>
      注入量是 <code>块长 × 命中条数</code>。保底检索 top-8 → 最多 4000 字；
      设定参考 top-4 → 最多 2000 字；加上世界观（6×700）、角色（12×600）、
      上一章结尾（1200）、章纲阶段预取资料（≤4000）。
    </p>
    <p>所以写作 prompt 的静态部分是有界的，可以心算出来。这就是<b>不能随便调大块长</b>的原因。</p>
    <h3 id="inject-91">三、措辞：硬约束 vs 可改编</h3>
    <p>
      作者上传的设定参考被声明为<b>硬约束</b>：
    </p>
    <pre><span class="c">【作者提供的设定参考 · 硬约束】
凡涉及以下专有名词、人物关系、地理/组织/规则设定，一律以此为准，
不得改名、改写或与之冲突：</span></pre>
    <div class="note d"><b>✗ 这个措辞曾经造成过一次真实事故</b><div>
      当作者驳回理由写的是「月之森、羽丘等学校没有做国内适配」时：
      <b>第 1 版</b>已把高中改成「明心中学」、日元改成人民币；
      <b>第 2 版反而全部退回日文原名</b>——<br>
      原因是<b>两条指令冲突</b>：「一律以此为准、不得改名」与「做本土化改编」直接对立，
      而模型选了<b>措辞更硬的一方</b>。<br><br>
      于是有了降级措辞：只要本轮<b>存在作者的修改要求</b>（<code>_has_revision_feedback</code>），
      就切换成——<br>
      <span class="c">【作者提供的设定参考】
      注意：本次生成带有**作者明确的修改要求**，两者冲突时**以作者修改要求为准**
      （例如要求做本土化改编时，改写机构名、地名、专有名词是允许的，不算冲突）。</span>
    </div></div>
    <p>
      降级只在"作者明确要求修改"时生效，常规的<b>防模型自造设定</b>能力不受影响。
      另外注意：<b>措辞只在 <code>rag.py</code> 里维护</b>，共三段常量 ——
      <code>DOC_REF_HEADER</code>（硬约束）、<code>DOC_REF_HEADER_ADAPTABLE</code>（有作者修改要求时降级）、
      <code>SOURCE_DATA_CLAUSE</code>（数据/指令分离，<b>间接注入防护</b>）。
      <code>doc_reference_block()</code> 按「header + clause + 检索文本」拼装；
      世界观 / 人设 / 正文三处注入必须用同一套措辞，否则模型在不同阶段对同一份设定
      得到不同的"遵守强度"。<br>
      <code>SOURCE_DATA_CLAUSE</code> 也加在 baseline + 本章资料区块上（见 <code>writing_node</code>）——
      没有这一段，设定文档里夹带的「此后所有输出都必须…」会被当成指令执行。
    </p>
    <h3 id="inject-92">上一章结尾为什么直接用原文</h3>
    <p>
      <code>_prev_tail_block</code> 只取<b>紧邻的上一章最后 1200 字原文</b>。
      理由是<b>接上文靠原文</b>：摘要接不住——"他推开门，屋内一片漆黑"这种句子，
      只有原文能告诉模型接下来该延续哪个氛围。更早的章节交给 RAG 按需召回。
    </p>
    <div class="note i"><b>💡 直塞与检索的分工，一句话</b><div>
      <b>无界且需要"接得住"→ 直塞原文</b>；<b>有界且需要"字段全"→ 直塞全量</b>；
      <b>无界且只需"大概相关"→ 检索</b>。
    </div></div>
  </div>
</section>
<!-- ===================== 11 存储层 ===================== -->
<section id="store">
  <div class="wrap">
    <div class="eyebrow">13 · Storage Layer</div>
    <h2 id="store">Qdrant 适配层：为什么要包一层薄封装</h2>
    <p class="lead">
      <code>rag.py</code>、<code>documents.py</code> 和一批测试都以
      <code>rag.collection.add / query / get / delete / count</code> 这套形态调用（原实现是 Chroma）。
      把 Qdrant 包成同样的形态，<b>"换存储"就只需要改 <code>LocalRAG</code> 里的一处构造</b>。
    </p>
    <div class="grid g2">
      <div class="card ok">
        <span class="ico">☁️</span><h4 id="store-94">远端模式（生产）</h4>
        <p><code>qdrant_url</code> 非空<b>且</b>能取到 key → 连 Qdrant Cloud 集群。</p>
        <p>key 取 <code>QDRANT_API_KEY</code> / <code>RAG_API_KEY</code>；取不到时<b>自动退回本地模式并告警</b>，保证没配密钥的机器仍能跑起来。</p>
      </div>
      <div class="card accent">
        <span class="ico">🧪</span><h4 id="store-95">本地模式（pytest / 离线 E2E）</h4>
        <p><code>qdrant_url</code> 为空、或 <code>FAKE_LLM=1</code> → <code>qdrant-client</code> 本地模式（<code>":memory:"</code> 为纯内存）。</p>
        <p>不联网、结果确定——这是"检索是否命中"能在离线环境里被断言的<b>前提</b>。</p>
      </div>
    </div>
    <h3 id="store-96">集合名里为什么带模型和维度</h3>
    <pre><span class="c"># 集合名：novel_{project_id}__{model_tag}_d{dim}
novel_abc123__baai_bge_m3_d1024</span></pre>
    <p>
      Qdrant 的集合维度<b>创建时固定</b>，一旦换模型或维度就<b>不能</b>写进同一个集合
      （报 "Vector dimension error"）——而写错时点往往在几周后才发现。
      名字里带上模型与维度，让"这个集合是谁写的、多少维"<b>一眼可见</b>。
      删项目时 <code>delete_project_collections</code> 连带清理 <code>novel_{pid}__*</code> 全部形态。
    </p>
    <h3 id="store-97">payload 索引：不建就 400，而且是静默失效</h3>
    <div class="note d"><b>✗ 一个必须知道的 Qdrant 特性</b><div>
      <b>过滤字段必须先建 payload 索引</b>，否则带过滤的查询/删除直接 400
      （<code>Index required but not found for "source"</code>）。不建索引时，
      <b>按域检索、按章删除会全部静默失效</b>——旧块删不掉会不断累积。
    </div></div>
    <p>适配层在建集合时统一建好，并对历史集合做惰性补建：</p>
    <pre><span class="k">_FILTER_KEY_TYPES = {</span>
    <span class="c">"source", "type", "chapter_id", "doc_id", "character_id",</span>
    <span class="c">"foreshadow_id", "filename", "name", "field"  → keyword</span>
    <span class="c">"chapter_index", "chunk_index"                    → integer</span>
<span class="k">}</span></pre>
    <div class="note w"><b>⚠ 补建后必须等 0.3 秒</b><div>
      实测：在"数据已在、索引事后补建"的集合上，<b>紧接着的那一次</b>带过滤查询会命中 <b>0 条</b>
      （索引生效需要一点时间）。不处理的话，"按域检索"会静默变成"永远查不到"，
      而按章删除会变成"旧块删不掉、新块照写"——都很难被发现。
      每个进程每个集合只等这一次（后面走缓存）。
    </div></div>
    <h3 id="store-98">距离 ↔ 相似度：换算必须只有一个地方</h3>
    <p>
      Qdrant 的 COSINE 打分是<b>相似度</b>（越大越像），Chroma 的 distance 是<b>距离</b>（越小越像）。
      适配层在 <code>query</code> 里换算成 <code>1 - score</code>，
      保持 <code>rag.py</code> 里 <code>score = 1 - dist</code> 的既有算法不变。
      <b>换算只做一次</b>，业务代码只认"越大越像"。
    </p>
    <h3 id="store-99">惰性建集合 + id 映射</h3>
    <ul class="clean">
      <li><b>惰性建</b>：<code>get_or_create_collection</code> 只返回句柄，真正建集合发生在<b>首次写入</b>。
          因为 <code>LocalRAG</code> 在只读场景（统计、重建索引的前置检查）也会被构造，
          若构造时就建，会在云端留下一堆空集合。</li>
      <li><b>id 映射</b>：Chroma 的 id 是任意字符串，Qdrant 只接受 uuid 或 uint64。
          非 uuid 的 id（本系统的 <code>"world_setting:setting:0"</code> 这类）用
          <b>uuid5 确定性映射</b>，并在 payload 里保留原值，<code>get()</code> 时还原。</li>
      <li><b>本地模式必须复用 client</b>：同一 path 起第二个 client 会撞文件锁
          （"already accessed by another instance"），而 <code>LocalRAG</code> 每个节点都会新建实例。</li>
    </ul>
    <h3 id="store-100">失败语义：增强项失败即跳过</h3>
    <div class="note g"><b>✓ 统一约定</b><div>
      向量库读写失败<b>记告警并退化为空结果 / 跳过这次写入</b>，不让一次网络抖动把整章写作打断
      （与 <code>embeddings.embed_texts</code> 的处理一致）。
      但<b>编程错误必须立刻抛出来</b>——所以 <code>_to_filter</code> 的校验放在 <code>try</code>
      <b>之外</b>：若放进容错块，<code>$gt</code> 这类不支持的操作符会被降级成"删了 0 条"，
      看起来像"本来就没有数据"。
    </div></div>
  </div>
</section>
<!-- ===================== 12 可靠性 ===================== -->
<section id="reliability">
  <div class="wrap">
    <div class="eyebrow">14 · Observability</div>
    <h2 id="reliability">检索账目：让"没检索到"变成可诊断的信息</h2>
    <p class="lead">
      检索此前是<b>全静默</b>的：向量库里没有这章的块、命中全被阈值筛掉、命中进了 top-k
      但被 500 字截断——<b>三种完全不同的情况在界面上长得一模一样</b>，作者只能靠猜。
    </p>
    <h3 id="reliability-102">两类信息，缺一不可</h3>
    <div class="grid g2">
      <div class="card accent">
        <span class="ico">📇</span><h4 id="reliability-103">引用卡：用了什么</h4>
        <p>来自 <code>to_citations(hits)</code>，按来源去重后给前端渲染成「检索到 N 条上下文」卡片，
        每条含 <code>{type, id, label, snippet, score}</code>。</p>
        <p>此前写作路径只写 <code>retrieved_context</code>（拼好的文本）且随即清空，
        那条卡片<b>永远不会出现</b>——作者无从得知模型到底参考了什么，
        尤其"我上传的设定参考到底有没有被用上"。</p>
      </div>
      <div class="card warn">
        <span class="ico">📊</span><h4 id="reliability-104">检索账目：为什么没用上别的</h4>
        <p>引用卡只说明"用到了什么"，说明不了"为什么没用上别的"。账目字段下表。</p>
      </div>
    </div>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>字段</th><th>含义</th><th>怎么用它诊断</th></tr></thead>
        <tbody>
          <tr><td><code>backend</code></td><td><code>remote</code> / <code>local</code></td><td>显示 <code>local</code> 说明没连云端集群，别怀疑检索逻辑</td></tr>
          <tr><td><code>embedding</code></td><td><code>ok</code> / <code>unavailable</code></td><td><code>unavailable</code> → 检查 key / 网络 / 是否在冷却期</td></tr>
          <tr><td><code>queries</code></td><td>实际检索了几条子查询</td><td>0 → 本章没章纲也没伏笔角色；少 → 看 <code>dropped</code></td></tr>
          <tr><td><code>on_stage</code></td><td>判定为本章出场的角色</td><td>你期望出场的人不在里面 → 章纲/门禁没提到他的名字</td></tr>
          <tr><td><code>dropped</code> / <code>dropped_queries</code></td><td><b>被 6 条上限截断的</b>子查询</td><td><b>&gt;0 就说明有角色/伏笔没被检索</b>，这是漏检信号</td></tr>
          <tr><td><code>raw_hits</code></td><td>各子查询「阈值<b>后</b>」命中数之和<br><small style="color:var(--danger)">docstring 写的是「阈值前」，实测并非如此</small></td><td>恒等于 <code>kept_hits</code>；看"阈值砍了多少"目前做不到</td></tr>
          <tr><td><code>merged</code></td><td>实际注入的条数</td><td>0 且 <code>kept_hits</code> 也 0 → <b>该重建索引了 / embedding 不可用</b></td></tr>
          <tr><td><code>min_score</code></td><td>本次生效的阈值</td><td>改了配置就能对上账</td></tr>
          <tr><td><code>duplicates</code></td><td>候选里<b>没进最终名单</b>的条数<br><small><code>= kept_hits − merged</code>，含「真去重」与「被 k 截断」两部分</small></td><td>很大属正常（<code>k</code> 通常小于候选数）；<b>无法单独看出真去重有多少</b></td></tr>
          <tr><td><code>sources</code></td><td>命中按来源分布，如 <code>{chapter:3, foreshadow:2}</code></td><td>引用卡上的「前情 3 / 伏笔 2」就来自这里</td></tr>
          <tr><td><code>direct</code></td><td>直塞的条目数 + <code>prev_tail_chars</code></td><td>说明"引用卡之外还直塞了什么"</td></tr>
        </tbody>
      </table>
    </div>
    <div class="note w"><b>⚠ 一次都没检索到时必须明确说出来</b><div>
      <code>if not citations and not base_hits and not doc_hits</code> 时，
      账目里加一条 <code>warning</code>：<br>
      「本次未检索到任何上下文：若已有前文却出现该提示，多为索引未建立或 embedding 不可用」。<br><br>
      否则 prompt 里就是空上下文，作者会以为"这一章本来就没有前情可参考"，
      而真实原因可能是索引没建或远端挂了。
    </div></div>
    <h3 id="reliability-105">失败即跳过，从不降级</h3>
    <p>把本系统的"不靠谱兜底"清点一遍，可以看出一条贯穿的原则：</p>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>场景</th><th>处理</th><th>为什么不降级</th></tr></thead>
        <tbody>
          <tr><td>embedding 远端超时</td><td>返回 <code>None</code> → 本次不检索/不索引 → 告警 + 账目标记</td><td>混入别种维度的向量会<b>直接损坏索引</b></td></tr>
          <tr><td>向量库读写失败</td><td>返回空结果 / 返回写入条数 0 → 跳过本次</td><td>让一次网络抖动打断整章写作，比缺一点上下文更糟</td></tr>
          <tr><td>单条子查询检索失败</td><td>跳过该条，其余继续</td><td>一条失败不该拖垮整次检索</td></tr>
          <tr><td>设定索引写入失败</td><td><b>保留旧索引</b>，只是本次没更新</td><td>先删后写会把设定抹掉，那段时间检索全是空的</td></tr>
          <tr><td><code>FAKE_LLM=1</code></td><td>走离线夹具，<b>绝不发外网</b></td><td>否则开发机上恰好有 key 就会真去请求，测试结果随网络漂移</td></tr>
        </tbody>
      </table>
    </div>
  </div>
</section>
<!-- ===================== 13 时序 ===================== -->
<section id="timeline">
  <div class="wrap">
    <div class="eyebrow">15 · End-to-End</div>
    <h2 id="timeline">写一章的完整时序</h2>
    <p class="lead">
      把前面所有零件串起来。这是点一次「生成正文」之后真实发生的事（<code>writing_node</code>）的<b>压缩版</b>。
      检索的逐步数字见<a href="#queryflow">第 11 节</a>，入库的逐步数字见<a href="#ingestflow">第 07 节</a>，
      本节只关心<b>先后顺序</b>与<b>哪些动作发生在哪个阶段</b>。
    </p>
    <ul class="tl">
      <li>
        <div class="from">章纲阶段 · 一次性</div>
        <div class="txt">
          <b>① 让模型列出「写本章还需要查什么」</b>（<code>_plan_chapter_lookups</code>）——
          1 次 LLM 调用产出一份资料清单（每条带 query / scope / reason）。<br>
          <span style="color:var(--ink-3)">① 之后是对每条清单做定向检索（scope 各不相同，top_k=3），
          拼成随章纲一起固化的「本章写作资料」（≤4000 字）。<b>写作阶段零临时检索</b>，行为可复现。</span>
        </div>
      </li>
      <li class="alt">
        <div class="from cyan">writing_node · 第 1 段</div>
        <div class="txt">
          <b>② 保底检索</b>（<code>rag_retrieve_hits_with_stats</code>）——
          构造 ≤6 条子查询（章纲 → 伏笔 → 出场角色 → 其他角色），<b>一次批量 embedding</b> +
          6 线程并发检索，每条取 top-3，<b>每条各自先过 0.45 阈值</b>，再<b>轮转合并</b>去重取<b>前 8 条</b>，
          最后做最近 5 章的时间偏置。
        </div>
      </li>
      <li class="alt">
        <div class="from cyan">writing_node · 第 2 段</div>
        <div class="txt">
          <b>③ 直塞上下文</b>：世界观全量（每字段 ≤700 字）+ 角色档案（每人 ≤600 字）
          + 更早 2 章梗概 + <b>上一章结尾原文 1200 字</b>。这些不进检索。
        </div>
      </li>
      <li class="bar">
        <div class="from amber">writing_node · 第 3 段</div>
        <div class="txt">
          <b>④ 设定参考独立一路</b>（<code>rag_retrieve_documents_hits</code>，scope=<code>document</code>，top-4）——
          包成<b>硬约束区块</b>注入。有作者修改要求时自动降级措辞。
        </div>
      </li>
      <li>
        <div class="from">writing_node · 生成</div>
        <div class="txt">
          <b>⑤ 组装 prompt 并调用 LLM</b>：system 放世界观/角色/章纲/梗概/上一章原文/检索基线，
          prompt 放硬约束区块 + 本章资料 + 检索基线。正文用<b>单独收敛过 max_tokens 的 LLM</b>
          （中文 1 token ≈ 1.13 字，按比率反推，否则按 1.2 倍正推会让截断点冲出 max_words）。
        </div>
      </li>
      <li class="bar">
        <div class="from amber">writing_node · 收尾</div>
        <div class="txt">
          <b>⑥ 正文写外部 body store</b>（State 只存 <code>content_ref</code> 指针），
          <b>本章正文不入向量库</b>；但<b>设定索引在此刷新</b>——它与"本章是否定稿"无关，
          且是幂等收敛重复向量的时机。
        </div>
      </li>
      <li class="bar">
        <div class="from amber">writing_node · 下发</div>
        <div class="txt">
          <b>⑦ 下发引用卡 + 检索账目</b>：<code>retrieved_sources</code> = 引用卡，
          <code>retrieval_stats</code> = 账目。<code>retrieved_context</code> 与
          <code>chapter_research</code> <b>用完清空</b>，不残留进 checkpoint。
        </div>
      </li>
      <li class="alt">
        <div class="from cyan">人审 · 定稿时</div>
        <div class="txt">
          <b>⑧ 正文才进向量库</b>（<code>_index_approved_chapter</code> → <code>reindex_chapter</code>）：
          先按 <code>chapter_id</code> 删该章旧块，再写新块。
          接受润色候选时必须<b>显式传入新版章节</b>——此时 State 里的 <code>content_ref</code> 还指向旧版本。
        </div>
      </li>
    </ul>
    <div class="note g"><b>✓ 注意第 ⑧ 步的位置</b><div>
      「只有定稿可被检索」这条保证很容易从侧门被破坏——比如"重建索引"时不小心把草稿也灌回库里。
      <code>_reindex_chapters</code> 因此<b>只收 <code>APPROVED_CHAPTER_STATUS</code></b> 的章节，
      计数也只算定稿：报告"重建了几章"必须与实际入库口径一致，
      否则会显示 N 章而库里只有已定稿的那几章。
    </div></div>
    <h3 id="timeline-107">"重建索引"时有一个域故意不删</h3>
    <div class="note d"><b>✗ 上传文档的向量无法重建</b><div>
      <code>reindex</code> 里 world / character / foreshadow / chapter 都会先删后重嵌，
      但 <b>document 故意不删</b>：上传文档的 chunk <b>无法重建</b>——
      <b>原文不留存</b>，服务器上只有向量库里的那份文本，删掉就是<b>永久丢失作者的设定参考</b>。
      早期元数据没有 <code>source</code>，这条删除恰好"无效"；
      一旦把 <code>source</code> 补上却保留删除，一次「清空本地缓存并重建索引」就会<b>静默抹掉全部参考设定</b>。
    </div></div>
    <h3 id="timeline-108">改完设定为什么还要重建索引</h3>
    <p>
      向量库里存的是<b>索引时刻的快照</b>。改了 <code>world_setting</code> 或
      <code>character_settings</code> 之后，库里还是旧文本的向量——
      <code>scope=world</code> 或 <code>scope=character</code> 才能让检索看到新设定。
    </p>
    <div class="note w"><b>⚠ 一个曾经让"重建"白做的 bug</b><div>
      <code>reindex</code> 里曾有一份<b>不切块</b>的旧写法，于是"重建索引"会把已经修好的长描述
      又变回一条整段——重建后照样被 500 字截断，<b>等于白重建</b>。
      现在它直接复用 <code>index_settings</code>：<b>切块策略与文本格式只能有一份实现</b>。
    </div></div>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th><code>reindex</code> 的 scope</th><th>清理</th><th>重建</th><th>计数口径</th></tr></thead>
        <tbody>
          <tr><td><code>world</code></td><td>删 <code>source=world_setting</code></td><td><code>index_settings</code></td><td>库中实际条数</td></tr>
          <tr><td><code>character</code></td><td>删 <code>source=character</code> 与 <code>foreshadow</code></td><td><code>index_settings</code></td><td>库中实际条数</td></tr>
          <tr><td><code>chapters</code></td><td>删 <code>source=chapter</code></td><td>只重嵌<b>定稿</b>章节（正文从 body store 读）</td><td>定稿章数</td></tr>
          <tr><td><code>documents</code></td><td style="color:var(--danger)"><b>不删</b></td><td style="color:var(--danger)"><b>不重嵌</b></td><td>去重后的 <code>doc_id</code> 数</td></tr>
          <tr><td><code>all</code></td><td>以上除document 外全删</td><td>以上全部</td><td>合并</td></tr>
        </tbody>
      </table>
    </div>
    <h3 id="timeline-109">「重跑」之前还会再清一次旧向量</h3>
    <div class="note d"><b>✗ 不清会怎样（实测）</b><div>
      <code>POST /projects/{id}/rerun</code> 会把 <code>from_chapter_index</code> 起的各章<b>整章重写</b>。
      但重写前那一版的旧向量还留在库里，于是检索把它当成"前情"注入本次写作——
      更隐蔽的是：世界观 / 人物 / 大纲一并改掉后重跑全书，<b>作者已经删掉的设定</b>
      （实测：已从世界观移除的「校对局」）照样被召回，新稿又把它写了回来。<br>
      所以 <code>purge_chapter_vectors()</code> 在图启动前先扫集合，按
      <code>source="chapter"</code> + <code>chapter_index ≥ from_chapter_index</code> 精确删点，
      <b>再由定稿路径重新入库</b>。<br>
      刻意<b>不枚举 <code>state["chapters"]</code></b>：<code>GET /state</code> 默认就不返回它，
      照着 State 删会一个都删不掉、且没有任何报错——向量库才是"到底存了哪些旧块"的唯一事实来源。
      没有 <code>chapter_index</code> 的历史点按 0 处理（宁可多删）。
    </div></div>
  </div>
</section>
<!-- ===================== 14 FAQ ===================== -->
<section id="faq">
  <div class="wrap">
    <div class="eyebrow">16 · FAQ</div>
    <h2 id="faq">常见误解与自查</h2>
    <details open>
      <summary>我刚写的这一章，搜不到？</summary>
      <p class="a"><b>正常。</b>只有<b>定稿</b>（审核通过 <code>reviewed</code> 或润色采用 <code>polished</code>）的正文才进向量库。
      草稿只存在 body store 里，供快照回退。这样设计是为了避免作者还没点"通过"，这段正文就已经被检索到——
      实测那样会让引用卡带上还没定稿的内容。</p>
      <p class="a">先点「通过」再试。若已定稿仍搜不到，看账目：<code>kept_hits=0</code> 且 <code>embedding="ok"</code>
      → 向量库里确实没有这一章的块，<b>该重建索引了</b>；<code>embedding="unavailable"</code>
      → 远端 embedding 不可用，本次压根没检索。<br>
      <small>注意：<code>raw_hits</code> 实测等于 <code>kept_hits</code>，并不能说明"阈值砍掉了多少"（见第 11 节）。</small></p>
    </details>
    <details>
      <summary>为什么改了角色设定，检索还是旧的？</summary>
      <p class="a">向量库是<b>快照</b>。每次写章都会刷新设定索引，但如果你改了设定后<b>还没写下一章</b>，检索仍是旧向量。
      点一次「重建索引」并选 <code>scope=character</code>（或 <code>world</code>）即可生效。</p>
    </details>
    <details>
      <summary>我上传的设定参考好像没起作用？</summary>
      <p class="a">依次排查：</p>
      <ul class="clean">
        <li>账目里 <code>document.queries</code> 是否 &gt; 0——早期阶段（还没有章纲）用项目背景 + 世界观各维度 + 已有角色名构造查询，角色名<b>是</b>在内的（此前完全没进 query，是最大漏洞：书名常是作者自造的简称，并不含角色正式名）。</li>
        <li><code>document.merged</code> 是否 &gt; 0。</li>
        <li>引用卡里有没有 <code>设定参考·{文件名}</code> 这种条目——有就是真用上了。</li>
        <li>阈值：设定参考的相关度有时偏低，考虑把 <code>RAG_MIN_SCORE</code> 调到 0.35。</li>
      </ul>
    </details>
    <details>
      <summary>相关度 0.5 算高吗？</summary>
      <p class="a">算高的。标定数据里噪声地板是 0.4297，真命中首位是 0.5498～0.7135。
      所以 0.5 意味着"明确比噪声像"。数字本身<b>不能跨模型比较</b>，换了 embedding 模型要重新标定。</p>
    </details>
    <details>
      <summary>为什么角色和世界观走直塞？</summary>
      <p class="a">因为它们是<b>有界</b>的（角色 ≤12、世界观 6 字段），注入成本可控，而且<b>字段必须完整</b>——
      直塞能保证"说话方式""外貌"这些字段一定在（检索常常召不到）。
      让它们再进一次检索只会让同一份设定在 prompt 里出现两份，模型分不清哪份权威。</p>
    </details>
    <details>
      <summary>伏笔为什么必须靠检索？</summary>
      <p class="a">因为伏笔<b>此前从未直塞</b>——数量无界（可能几十条），全量注入会挤爆预算。
      而伏笔遗漏是<b>明确的写作事故</b>（读者视角的"作者忘了"），所以它固定留 2 条子查询名额，
      且排在角色之前。</p>
    </details>
    <details>
      <summary>能不能把块从 500 调到 800，一次多召回点？</summary>
      <p class="a">可以，但<b>不能只改这一处</b>。<code>CHUNK_SIZE</code> 同时是注入截断的上限，
      改成引用同一常量后，改一处两处都会跟着变——所以是安全的。真正要权衡的是：</p>
      <ul class="clean">
        <li>块变大会让<b>一个向量混进多个主题，精度下降得比块太小更狠</b>；</li>
        <li>注入量是 <code>块长 × 命中条数</code>，翻倍就是翻倍，会挤压正文预算；</li>
        <li>行业更该走「小块检索 + 父段注入」（匹配粒度与阅读粒度分离）。</li>
      </ul>
    </details>
    <details>
      <summary>为什么没有用 rerank（重排模型）？</summary>
      <p class="a">主要是<b>确定性</b>。当前合并只依赖「名次 + 子查询顺序」两个确定输入，
      不依赖时间或字典顺序，因此<b>同输入同结果</b>——这是"可重跑、时间旅行能复现"的前提。
      引入 LLM rerank 会带来随机性。<br>
      代价是排序精度上限受限：轮转只看<b>名次</b>不看绝对分数，
      所以一条"第 1 名 0.45"的子查询会抢在"第 2 名 0.72"之前。这是明确的已知短板，见第 17 节。</p>
    </details>
    <details>
      <summary>为什么不用 <code>score = α·dense + β·sparse</code> 的加权融合？</summary>
      <p class="a">稀疏路已经补上了（<code>RAG_SPARSE_ENABLED</code>，默认关，见第 19 节），
      但刻意<b>只做 RRF 重排、不参与召回</b>。原因是加权融合在本系统里会<b>静默失效</b>：
      阈值 0.45、引用卡「相关度」、检索账目三处都建立在「score 就是余弦相似度」这条不变式上。
      实测 Qdrant 的 RRF 取 k=1 时，两路都排第 1 才 1.000、仅排第 2 就是 0.444——
      拿 0.45 去卡，8 条命中只剩 1 条。所以补的这一路只重排，不扩展候选集。</p>
    </details>
    <details>
      <summary>"重建索引"会不会把我上传的设定参考删掉？</summary>
      <p class="a">不会。<b>document 域故意不删</b>，因为上传文档的原文<b>不留存</b>——
      服务器上只有向量库里的那份文本，删了就永久丢失。重建时它只被<b>计数</b>，不做重嵌。</p>
    </details>
    <details>
      <summary>为什么我看不到检索过程？</summary>
      <p class="a">写作阶段<b>零临时检索</b>。资料清单在<b>章纲阶段</b>一次性备齐（J20），
      检索结果随章纲一起固化，写作阶段直接使用。理由是行为可复现：
      早期版本有「agentic rag_search 工具 ReAct 循环」，让模型自己决定查什么、查几轮，
      导致同样的输入得到不同的上下文——那"时间旅行回退到上一版"就没有意义了。</p>
    </details>
  </div>
</section>
<!-- ===================== 15 权衡 ===================== -->
<section id="tradeoff">
  <div class="wrap">
    <div class="eyebrow">17 · Trade-offs</div>
    <h2 id="tradeoff">已知短板与设计权衡</h2>
    <p class="lead">
      这套设计的目标很具体：<b>在长篇中文创作这个场景下，把几个致命故障修掉</b>。
      诚实地列出短板，比宣称完备更有用。
    </p>
    <div class="grid g2">
      <div class="card warn">
        <span class="ico">⚖️</span><h4 id="tradeoff-111">稀疏路只重排，不参与召回</h4>
        <p>BM25 路已实现（<code>RAG_SPARSE_ENABLED</code>，默认关），但刻意只用 RRF 重排：
        语义不像的块仍然由 <code>rag_min_score</code> 挡住。代价是"一个字之差的专有名词"
        只能靠稠密路先把它捞进候选集，才谈得上被顶上来——真正的加权融合要等跨标度的分数归一化方案。</p>
      </div>
      <div class="card warn">
        <span class="ico">⚖️</span><h4 id="tradeoff-112">没有真正的 rerank</h4>
        <p>轮转合并只看名次不看绝对分数，所以"第 1 名 0.45"会抢在"第 2 名 0.72"之前。
        折中方案是纯规则的分数衰减（如第 n 名乘0.9^n），既保留确定性又利用绝对分数。</p>
      </div>
      <div class="card warn">
        <span class="ico">⚖️</span><h4 id="tradeoff-113">子查询上限是硬编码的</h4>
        <p><code>MAX_SUBQUERIES = 6</code> 是硬编码上限，不随预算自适应。角色多的项目必然触发
        <code>dropped</code>。虽然记账了，但更好的做法是按<b>可用时间预算</b>动态决定条数。</p>
      </div>
      <div class="card warn">
        <span class="ico">⚖️</span><h4 id="tradeoff-114">块级粒度，无父子结构</h4>
        <p>没有 <code>parent_span</code>，所以"小块检索 + 父段注入"这个更优形态还做不了。
        匹配粒度与阅读粒度被迫用同一个 <code>CHUNK_SIZE</code>。</p>
      </div>
      <div class="card warn">
        <span class="ico">⚖️</span><h4 id="tradeoff-115">embedding 缓存是进程内的</h4>
        <p><code>_CACHE_MAX = 512</code> 且进程退出即失效。多实例部署时缓存不共享，
        冷启动后会产生一批 embedding 请求。</p>
      </div>
      <div class="card warn">
        <span class="ico">⚖️</span><h4 id="tradeoff-116">间接注入防护有，内容审查默认关</h4>
        <p>注入侧已有 <code>SOURCE_DATA_CLAUSE</code>（"资料而非指令"）无条件兜底；
        定稿入索引前也有 P5 合规闸门（<code>compliance_enabled</code>，<b>默认 false</b>）。
        所以短板是明确的：<b>作者自己上传的设定参考文档</b>没有内容审查，
        一旦文档里写了指令性语句，靠的只有那条数据/指令分离声明。</p>
      </div>
      <div class="card warn">
        <span class="ico">⚖️</span><h4 id="tradeoff-117">两个账目字段名不副实（实测）</h4>
        <p><code>raw_hits</code> 声称是「阈值前命中数」，实际是<b>阈值后</b>（恒等于 <code>kept_hits</code>）；
        <code>duplicates</code> 实为「候选未入选数」，真去重与被 <code>k</code> 截断混在一起。
        两者都已在<a href="#queryflow">第 11 节</a>标注，<b>读账目时不要按字面理解</b>。
        修法很小：让 <code>search_dense_leg</code> 在过滤前先记一次 <code>len(hits)</code>。</p>
      </div>
    </div>
    <h3 id="tradeoff-118">但有几件事是<b>已经做对</b>的，值得强调</h3>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>做对的事</th><th>它避免了哪类事故</th></tr></thead>
        <tbody>
          <tr><td>向量单一来源，宁可不检索</td><td>"看起来在工作"的假成功；混合维度损坏索引</td></tr>
          <tr><td>块长与注入截断同一常量</td><td>调块大小时正文<b>静默</b>丢失 37.5%</td></tr>
          <tr><td>确定性 id + 先写后删</td><td>向量库线性膨胀、top-k 被重复内容挤占、失败时误删旧索引</td></tr>
          <tr><td>只有定稿入索引</td><td>作者没点通过的内容被检索、被引用</td></tr>
          <tr><td>分条召回 + 名次轮转</td><td>被一条宽泛查询主导，多路召回换汤不换药</td></tr>
          <tr><td>前缀富化 + 预算预留</td><td>注入时削掉块尾真实内容（破坏不变量①）</td></tr>
          <tr><td>设定参考独立成路 + 措辞可降级</td><td>与章节块抢名额；硬约束压过作者的改编要求</td></tr>
          <tr><td>丢弃记账 + 检索账目</td><td>"没检索到"与"检索到但没用上"在界面上长得一样</td></tr>
          <tr><td>document 域不删</td><td>"重建索引"静默抹掉全部作者上传的参考设定</td></tr>
          <tr><td>确定性合并（同输入同结果）</td><td>时间旅行回退后复现不出同一份上下文</td></tr>
        </tbody>
      </table>
    </div>
    <h3 id="tradeoff-119">一句话总结这套 RAG 的取向</h3>
    <div class="note i"><b>💡</b><div>
      它<b>不追求</b>"检索到最相关的内容"，而追求<b>"每次生成时，模型看到的前情是完整、有出处、且可复现的"</b>。
      大量设计（确定性合并、域收窄、直塞优先、宁可失败不降级）都是在为这一句服务的——
      对创作工具来说，<b>可预期的上下文比最聪明的召回更值钱</b>。
    </div></div>
  </div>
</section>
<!-- ===================== 16 速查 ===================== -->
<section id="ref">
  <div class="wrap">
    <div class="eyebrow">18 · Reference</div>
    <h2 id="ref">参数与代码速查</h2>
    <h3 id="ref-121">关键常量</h3>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>常量</th><th>值</th><th>含义与约束</th></tr></thead>
        <tbody>
          <tr><td><code>CHUNK_SIZE</code></td><td><code>500</code></td><td>单块字数上限。<b>必须等于注入截断</b>（同一常量）</td></tr>
          <tr><td><code>CHUNK_OVERLAP</code></td><td><code>80</code></td><td>重叠字数 → 步长 420，无缝隙</td></tr>
          <tr><td><code>ENRICH_RESERVE</code></td><td><code>120</code></td><td>前缀预算（固定上限，不自适应）</td></tr>
          <tr><td><code>CONTENT_BUDGET</code></td><td><code>379</code></td><td><code>= 500 − 120 − 1</code>，正文实际切分尺寸</td></tr>
          <tr><td><code>ENRICH_MAX_NAMES</code></td><td><code>8</code></td><td>前缀最多列几个角色名</td></tr>
          <tr><td><code>MAX_SUBQUERIES</code></td><td><code>6</code></td><td>单次检索子查询条数上限（保序截断）</td></tr>
          <tr><td><code>MAX_ALIASES_PER_QUERY</code></td><td><code>3</code></td><td>每条角色子查询最多带几个别名（<b>合并进同一条</b>，不各自成条）</td></tr>
          <tr><td><code>_SPARSE_LEG_K</code></td><td><code>10</code></td><td>稀疏路每条子查询的候选数（RRF 重排用，默认关）</td></tr>
          <tr><td><code>RAG_RRF_K</code></td><td><code>60</code></td><td>RRF 平滑常数；只影响分数量级、不影响排序，不对外暴露</td></tr>
          <tr><td><code>PER_SUBQUERY_TOP_K</code></td><td><code>3</code></td><td>每条子查询各取多少（合并按名次轮转，不必多取）</td></tr>
          <tr><td><code>MAX_FORESHADOW_SUBQUERIES</code></td><td><code>2</code></td><td>给未回收伏笔<b>固定</b>预留的名额</td></tr>
          <tr><td><code>_SEARCH_WORKERS</code></td><td><code>6</code></td><td>分条召回并发度（远端有限流，不宜过大）</td></tr>
          <tr><td><code>RAG_MIN_SCORE</code></td><td><code>0.45</code></td><td>相似度阈值（噪声地板 0.4297 / 真命中 ≥0.5498）</td></tr>
          <tr><td><code>APPROVED_CHAPTER_STATUS</code></td><td><code>reviewed, polished</code></td><td>只有这两种状态进向量库</td></tr>
          <tr><td><code>_COOLDOWN_S</code></td><td><code>60.0</code></td><td>embedding 失败冷却（避免每章白等一个 timeout）</td></tr>
          <tr><td><code>_CACHE_MAX</code></td><td><code>512</code></td><td>文本→向量缓存上限</td></tr>
        </tbody>
      </table>
    </div>
    <h3 id="ref-122">默认参数</h3>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>函数</th><th>默认</th><th>说明</th></tr></thead>
        <tbody>
          <tr><td><code>rag_retrieve_hits_with_stats(state, k, window)</code></td><td><code>k=8, window=5</code></td><td>保底检索；scope=<code>story</code>，注入条数 / 时间偏置窗口</td></tr>
          <tr><td><code>rag_retrieve_documents_hits(state, k)</code></td><td><code>k=4</code></td><td>设定参考；scope=<code>document</code></td></tr>
          <tr><td><code>rag_search_direct(state, query, scope, top_k)</code></td><td><code>scope=all, top_k=5</code></td><td>章纲阶段资料预取（每条清单 top_k=3）</td></tr>
          <tr><td><code>to_citations(hits, limit)</code></td><td><code>limit=12</code></td><td>引用卡，按 <code>(type, id)</code> 去重</td></tr>
          <tr><td><code>reindex(state, scope)</code></td><td><code>scope=all</code></td><td>可选 <code>world/character/chapters/documents</code></td></tr>
        </tbody>
      </table>
    </div>
    <h3 id="ref-123">代码地图</h3>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>文件</th><th>职责</th><th>关键函数</th></tr></thead>
        <tbody>
          <tr>
            <td><span class="path">app/core/rag.py</span></td>
            <td>RAG 全部业务逻辑：切块、查询构造、合并、注入格式、引用卡、各域索引</td>
            <td><code>LocalRAG</code> <code>chunk_text</code> <code>build_story_queries_with_info</code> <code>_search_many</code> <code>_merge_round_robin</code> <code>rag_retrieve_hits_with_stats</code> <code>rag_retrieve_documents_hits</code> <code>index_settings</code> <code>reindex_chapter</code> <code>reindex</code> <code>to_citations</code> <code>_injectable</code> <code>_format_context</code> <code>doc_reference_block</code></td>
          </tr>
          <tr>
            <td><span class="path">app/core/embeddings.py</span></td>
            <td>远端 <code>/embeddings</code> 客户端 + 缓存 + 冷却 + 离线夹具</td>
            <td><code>embed_texts</code> <code>fake_embed</code> <code>available</code></td>
          </tr>
          <tr>
            <td><span class="path">app/core/vector_store.py</span></td>
            <td>Qdrant 访问层（Chroma 兼容子集）、payload 索引、id 映射、失败语义</td>
            <td><code>open_store</code> <code>QdrantCollection</code> <code>_to_filter</code> <code>backend_mode</code></td>
          </tr>
          <tr>
            <td><span class="path">app/core/nodes.py</span></td>
            <td>写作节点：调用三路检索、组装 prompt、下发引用卡与账目、定稿索引</td>
            <td><code>writing_node</code> <code>_gather_chapter_research</code> <code>_plan_chapter_lookups</code> <code>_index_approved_chapter</code></td>
          </tr>
          <tr>
            <td><span class="path">app/core/prompts.py</span></td>
            <td>直塞区块的构造：世界观全量、角色档案、上一章结尾原文、三处注入共用措辞</td>
            <td><code>_world_block</code> <code>_character_block</code> <code>_prev_tail_block</code>
                <code>_direct_counts</code> <code>MAX_WORLD_FIELD_CHARS</code>
                <code>MAX_CHAR_PROFILE_CHARS</code> <code>PREV_TAIL_CHARS</code></td>
          </tr>
          <tr>
            <td><span class="path">app/api/routers/documents.py</span></td>
            <td>上传文档：本地解析 → 切块 → 以 <code>source=document</code> 入库</td>
            <td><code>upload</code> <code>list_documents</code></td>
          </tr>
          <tr>
            <td><span class="path">app/config.py</span></td>
            <td>embedding / Qdrant / 阈值配置</td>
            <td><code>embedding_*</code> <code>qdrant_*</code> <code>rag_min_score</code></td>
          </tr>
          <tr>
            <td><span class="path">tests/</span></td>
            <td>切块不变量、注入截断耦合、检索统计、Qdrant 适配、索引幂等、别名归一化、引用卡、稀疏路、重跑清向量</td>
            <td><code>test_chunking_enrichment.py</code> <code>test_inject_truncation_coupling.py</code> <code>test_rag_retrieval_stats.py</code> <code>test_qdrant_store.py</code> <code>test_index_idempotent.py</code> <code>test_entity_alias.py</code> <code>test_citations.py</code> <code>test_sparse.py</code> <code>test_rerun_purge_vectors.py</code></td>
          </tr>
        </tbody>
      </table>
    </div>
    <h3 id="ref-124">改参数前必读的三条不变量</h3>
    <div class="note d"><b>✗ 动<code>rag.py</code> 前先确认</b><div>
      <b>① 单块 ≤ 注入截断</b>：两者必须是同一个常量。<code>_injectable</code> 引用 <code>CHUNK_SIZE</code>，二者恒等，
      因此单块永不触发截断。<b>二者恒等由结构保证，不靠配数值凑出来。</b><br><br>
      <b>② 原文零丢失</b>：所有字符至少出现在一个块里，<b>且不要按"文本相同"去重</b>。<br><br>
      <b>③ 块几何稳定</b>：<code>_clip_prefix</code> 用<b>固定上限</b>，不采用自适应长度，
      前缀长度因此不随内容漂移，切分位置只取决于正文——这是确定性 id 与陈旧块清理能正确工作的前提。
    </div></div>
  </div>
</section>
<!-- ===================== 19 稀疏检索 ===================== -->
<section id="sparse">
  <div class="wrap">
    <div class="eyebrow">19 · Sparse Retrieval</div>
    <h2 id="sparse">补充检索：稀疏向量（BM25 路）</h2>
    <p class="lead">
      前面 18 节讲的全是<b>一条稠密路</b>。它有一个已知短板：<b>对专有名词过于宽容</b>。
      这一节记录为什么补了第二条稀疏路、补在哪、<b>以及为什么它只做重排、不做扩展</b>——
      最后这条是实测踩出来的，最反直觉也最重要。
    </p>
    <h3 id="sparse-126">为什么需要它：稠密向量对近形词不设防</h3>
    <p>
      bge-m3 判定「明心中学」和「明神中学」语义几乎一样，余弦可以高到 <b>0.92</b>。
      对语义检索这是优点，对设定集这是硬伤——<b>错一个字就是另一个专有名词</b>。
      纯稠密路下，作者上传的设定集里一处笔误可能永远召不回正确的块。
    </p>
    <div class="grid g2">
      <div class="card warn">
        <span class="ico">🔍</span><h4 id="sparse-127">稠密（bge-m3）</h4>
        <p><b>擅长</b>：同义、改写、语义近似（「她那天说了什么」）</p>
        <p><b>不擅长</b>：错字、近形词、精确 ID（「明心 / 明神」）</p>
      </div>
      <div class="card ok">
        <span class="ico">🔤</span><h4 id="sparse-128">稀疏（bigram 字面）</h4>
        <p><b>擅长</b>：专有名词、罕见词、精确字面匹配</p>
        <p><b>不擅长</b>：同义、改写（稀疏检索的天花板）</p>
      </div>
    </div>
    <p>所以它只起<b>补充</b>作用，替代不了稠密向量。同义 / 改写这条路永远要靠稠密向量。</p>
    <h3 id="sparse-129">原料从哪来：与稠密向量<b>同源</b></h3>
    <p>
      这是整套设计最省事的一点——<b>不需要新增任何数据源</b>。Qdrant 侧不存在「稀疏 embedding 服务」
      （稠密有 <code>/embeddings</code>，稀疏没有对应物），词频由本地算：
    </p>
    <pre><span class="c"># app/core/rag.py · add_documents() —— 两条路唯一的收口点</span>
texts      = [doc.page_content for doc in documents]  <span class="c"># 富化后的块文本</span>
vectors    = self._embed(texts)                      <span class="c"># 稠密：远程 BGE-M3</span>
sparse_list = [sparse.encode_text(t) for t in texts]  <span class="c"># 稀疏：本地纯 CPU</span>
written = self.collection.add(
    ids=ids, documents=texts, embeddings=vectors,
    sparse_vectors=sparse_list,                       <span class="c"># ← 新增</span>
    metadatas=metadatas)
<span class="c"># 4 条入库路径全部汇入这一处（grep add_texts 可验）：</span>
<span class="c">#   index_chapter 章节 / index_settings 设定 / index_foreshadow 伏笔 / documents.upload</span></pre>
    <div class="note g"><b>✓ 为什么「同源」很重要</b><div>
      稀疏向量与稠密向量必须来自<b>同一个字符串</b>。否则会出现「稀疏召回的块」与
      「最终注入 prompt 的文本」<b>边界错位</b>——而这个错误不会报错，只会让模型读到半句话。
      收口在 <code>add_documents</code> 一处，就从结构上排除了这种可能。
    </div></div>
    <h4 id="sparse-130">正文存了两份，各有职责</h4>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>副本</th><th>位置</th><th>是否权威</th><th>为什么需要</th></tr></thead>
        <tbody>
          <tr>
            <td><b>正文权威副本</b></td>
            <td>TiDB <code>chapter_bodies</code>（含全部历史版本）</td>
            <td style="color:var(--ok)"><b>权威</b></td>
            <td>H8 版本化，支撑快照回退；<b>原文永不丢</b></td>
          </tr>
          <tr>
            <td><b>检索副本</b></td>
            <td>Qdrant <code>payload["_text"]</code></td>
            <td>派生</td>
            <td>命中后要<b>立刻</b>拼进 prompt；不存就得回 TiDB 逐块查 8 次</td>
          </tr>
        </tbody>
      </table>
    </div>
    <p>
      稀疏向量<b>不存正文</b>，它和检索副本是并列的检索材料：<code>_text</code> 是命中后注入用的原文，
      <code>bm25</code> 是检索用的倒排项。
    </p>
    <h3 id="sparse-131">分词：为什么是字符 bigram</h3>
    <p>中文没有空格。三种选择的取舍：</p>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>方案</th><th>额外内存</th><th>新依赖</th><th>对专有名词</th><th>结论</th></tr></thead>
        <tbody>
          <tr><td>jieba 分词</td><td>+50~100 MB（35 万词条 dict）</td><td>有</td><td style="color:var(--danger)"><b>更差</b>（会切错「明心中学」）</td><td>否决</td></tr>
          <tr><td>BPE / 模型 tokenizer</td><td>模型体积</td><td>有</td><td>黑盒</td><td>否决</td></tr>
          <tr><td><b>字符 bigram</b></td><td style="color:var(--ok)"><b>0</b></td><td style="color:var(--ok)"><b>0</b></td><td style="color:var(--ok)">2 字滑窗，不切错</td><td><b>采用</b></td></tr>
        </tbody>
      </table>
    </div>
    <p>
      与 <code>embeddings.fake_embed</code> 里已验证的离线夹具同一思路。
      <b>2 字查询可用</b>是选它的唯一硬理由——实测 SQLite FTS5 的 <code>trigram</code> 分词器
      对「素世」「舞台」这类 2 字查询<b>返回 0 条</b>，而两字人名恰恰是本系统最高频的查询。
    </p>
    <div class="note w"><b>⚠ 为什么不用 SQLite FTS5（实测否决）</b><div>
      <code>tokenize='trigram'</code> <b>无法处理 3 字以下的查询</b>：<br>
      <code>素世 → 0 条　　舞台 → 0 条　　素世爱音 → 1 条　　爱音在 → 1 条</code><br>
      而 2 字人名（「素世」「爱音」「陆时」）是本系统最高频的查询。
      它 0.98 MB / 1.1 ms 的指标很漂亮，但对核心场景不成立。
    </div></div>
    <h4 id="sparse-132">空白充当<b>字段分隔符</b></h4>
    <p>
      子查询是「名字 + 身份」拼的（<code>"素世 主角"</code>）。若先 <code>join</code> 再滑窗，
      字段边界会造出<b>跨边界的伪 bigram</b>——这是实测查出来的真实缺陷：
    </p>
    <pre><span class="c"># 修复前：先 join 再滑窗</span>
"素世 主角"          -> 素世 / 世主   / 主角        <span class="c"># 世主 是伪词</span>
"素世 主角 苏晚 配角" -> 素世 / 世主 / 主角 / 角苏 / 苏晚 / 晚配 / 配角
                        <span class="c"># 7 个里 3 个是伪的，占 43%</span>
<span class="c"># 修复后：按空白分字段，字段内滑窗</span>
"素世 主角"          -> 素世 / 主角                <span class="c">✓</span>
"素世 主角 苏晚 配角"  -> 素世 / 主角 / 苏晚 / 配角  <span class="c">✓</span></pre>
    <p>
      换行同理：<code>chunk_text</code> 产出的块由若干句子用换行拼成，跨句 bigram 同样是噪声。
      这些伪词在正文里几乎不存在（实测「世界主角」产生的是「界主」「主角」，<b>不会</b>命中「世主」），
      所以危害主要是<b>白占索引空间 + 稀释真正起判别作用的词</b>，不会造成错误命中——但仍该修。
    </p>
    <h3 id="sparse-133">词 → uint32：无冲突编码</h3>
    <p>
      Qdrant 的 <code>indices</code> 是 <code>uint32</code>。直接哈希会有<b>静默碰撞</b>——
      20 万词表散列到 2³²，生日问题给出的期望碰撞对数 ≈ 4.7，每一对碰撞的 bigram 会被合并倒排项，
      分数莫名偏高且<b>永远查不出原因</b>。而 CJK 区只有 20992 字，15 bit 就够：
    </p>
    <pre>index = ((c1 − 0x4E00) &lt;&lt; 15) | (c2 − 0x4E00)   <span class="c"># 15 + 15 = 30 bit，零冲突</span>
<span class="c"># 非 CJK（CRYCHIC 这类 ASCII 双字母）回退 crc32，隔离到 [2^30, 2^32)</span></pre>
    <p>实测「素世」编码 <code>0x17900016</code> &lt; 2³⁰，「CR」编码 <code>0x5fe83ee1</code> &gt; 2³⁰，两区间不串扰。</p>
    <h3 id="sparse-134">IDF：为什么交给 Qdrant 算</h3>
    <p>
      <code>SparseVectorParams(modifier=Modifier.IDF)</code> 让服务端按<b>集合统计</b>套 IDF。
      实测确认了它的确切公式（受控语料 N=3 / df=2 / TF=3）：
    </p>
    <pre>IDF  = ln(1 + (N − df + 0.5) / (df + 0.5)) = ln(1 + 1.5/2.5) = 0.470004
打分 = TF × IDF = 3 × 0.470004 = 1.410011   <span class="c">← 与 Qdrant 实测完全吻合</span></pre>
    <p>好处是<b>本地不持有任何全局状态</b>：不必建倒排表、不必存 DF、不必管一致性。</p>
    <div class="note w"><b>⚠ 但 IDF 确实是全局量</b><div>
      实测：N 从 3 变 4，同一块同一词得分从 0.470004 变成 0.693147。
      所以<b>稀疏分不是纯函数</b>，与本系统「同输入同结果」的取向存在张力。<br>
      缓解：语料只增不删时 df 变化缓慢；且<b>向量库本来就不参与时间旅行</b>
      （<code>reindex_chapter</code> 只在人审通过时触发，checkpoint 回退只回退 State 与 TiDB），
      所以「检索结果依赖库状态」这件事本来就存在，IDF 只是让它更明确。
    </div></div>
    <h3 id="sparse-135">⚠ 最关键的设计决定：稀疏<b>只重排</b>，不扩展候选集</h3>
    <p>第一次实现按教科书写法做了 Qdrant 原生融合（<code>prefetch</code> + <code>FusionQuery</code>），实测发现：</p>
    <pre><span class="c"># 8 个块：dense 打 [-0.998, 0.962]，sparse 打 [0, 3.84]</span>
<span class="c"># RRF 融合后（Qdrant 取 k=1）：</span>
  两路都是第 1        1.000
  仅两路之一第 2      0.444
  仅一路第 3          0.250
  仅一路第 8          0.143</pre>
    <div class="note d"><b>✗ 若直接套 <code>rag_min_score = 0.45</code>：8 条里只剩 1 条能过</b><div>
      阈值 0.45 是<b>按 bge-m3 余弦标定</b>的（噪声地板 0.4297 / 真命中 ≥0.5498）。
      RRF 分是<b>纯名次函数</b>，与余弦不同量纲——拿它卡阈值等于把检索几乎关掉，
      而且<b>不报错</b>，只是「检索到的条数变少了」。
    </div></div>
    <p>于是定下三条规则：</p>
    <div class="steps">
      <li><b>候选集仍只由稠密路决定</b><span>稀疏不引入新文档。语义不像的设定块本来就该被 <code>rag_min_score</code> 滤掉，放进来是噪声——这正是阈值当初要卡的东西。</span></li>
      <li><b><code>score</code> 字段仍是余弦相似度</b><span>于是 <code>rag_min_score</code> 的标定值、引用卡里的「相关度」、阈值前 / 后条数语义<b>全部不变</b>，前端零改动。</span></li>
      <li><b>稀疏这一腿不套阈值</b><span>它的分数是 TF×IDF，与余弦不同量纲，套 cosine 阈值没有意义。稀疏本身已经足够稀疏——没有 bigram 交集的文档根本不会出现在结果里。</span></li>
    </div>
    <h4 id="sparse-136">RRF 只改顺序</h4>
    <pre><span class="c"># app/core/rag.py · _rrf_merge() —— 纯函数，在 dense_hits 内重排</span>
fused(d) = Σ_路  1 / (K + rank_路(d))      <span class="c"># 名次从 1 起，缺该路记 0 分</span>
排序键  = (-fused, -score, 原下标)          <span class="c"># 三级：完全确定，可复现</span></pre>
    <div class="note i"><b>💡 首选 RRF 的理由</b><div>
      两路分数量纲完全不同（余弦 −1~1 对 TF×IDF 0~3.8），加权必须先归一化，
      而分母对本次最高分敏感——某一路偶然出个高分，整路就被压扁。
      <b>RRF 只看名次，天然免疫量纲问题</b>；DBSF 用距离比值，对分数扰动更敏感。
      本系统核心诉求是「同输入同结果」，所以选 RRF。
    </div></div>
    <div class="note w"><b>⚠ 第三级 tie-break 是必需的</b><div>
      并列时若没有「原下标」这一级，排序就依赖 sort 的不稳定性——
      而<b>时间旅行回退要求复现同一版上下文</b>，任何不确定性都会让回退失效。
    </div></div>
    <h3 id="sparse-137">存储形态：为什么集合要改名</h3>
    <div class="note d"><b>✗ 客户端不接受 sparse_vectors 字段</b><div>
      <code>qdrant-client 1.19.1</code> 的 <code>PointStruct</code> 只有 <code>['id','vector','payload']</code>，
      传 <code>sparse_vectors=</code> 会报 <code>Extra inputs are not permitted</code>。<br>
      出口在类型定义里：<code>VectorStruct = Union[..., Dict[str, Vector], ...]</code>
      —— 稀疏向量必须<b>混在 <code>vector</code> 字典里当命名向量</b>。
      代价是<b>稠密向量也必须命名</b>。
    </div></div>
    <pre><span class="c"># 关闭（默认，形态与改造前逐字一致）</span>
vectors_config = VectorParams(size=1024, distance=COSINE)      <span class="c"># 单个未命名</span>
query_points(query=[...])                                       <span class="c"># 不传 using</span>
<span class="c"># 开启</span>
vectors_config         = {"text": VectorParams(size=1024, ...)}  <span class="c"># 必须命名</span>
sparse_vectors_config = {"bm25": SparseVectorParams(modifier=Modifier.IDF)}
query_points(query=[...], using="text")  /  (query=sparse, using="bm25")
<span class="c"># 集合名因此必须换：新旧形态不兼容</span>
novel_{pid}__{model}_d1024            <span class="c"># 关闭</span>
novel_{pid}__{model}_d1024__bm25      <span class="c"># 开启</span></pre>
    <p>
      <code>delete_project_collections</code> 匹配的是 <code>novel_{pid}__*</code>，两个形态都会被正确清理。
    </p>
    <div class="note w"><b>⚠ 稀疏配置<b>不能事后补</b></b><div>
      远端 Qdrant 支持 <code>update_collection</code> 追加，但
      <b>qdrant-client 本地模式直接报</b> <code>Vector bm25 does not exist in the collection</code>——
      而 pytest 与 <code>FAKE_LLM=1</code> E2E 都跑本地模式。
      所以形态必须<b>由同一个开关在建集合时定死</b>，否则测试验证不到生产真实路径。
    </div></div>
    <h3 id="sparse-138">两路可独立失败：降级矩阵</h3>
    <p>
      稀疏编码是<b>纯本地计算，不依赖任何外部服务</b>——这是把 IDF 交给服务端换来的好处。
      于是降级矩阵比原来完整了一格：
    </p>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>稠密</th><th>稀疏</th><th>行为</th><th>状态</th></tr></thead>
        <tbody>
          <tr><td>✓</td><td>✓</td><td>融合排序（RRF 重排稠密候选）</td><td style="color:var(--ok)">目标态</td></tr>
          <tr><td>✓</td><td>✗</td><td>退化为纯稠密序（= 改造前行为）</td><td style="color:var(--ok)">向后兼容</td></tr>
          <tr><td>✗</td><td>✓</td><td><b>未实现</b>：<code>search()</code> 在 embedding 失败处直接返回空，稀疏路不接管</td><td style="color:var(--danger)">刻意留空</td></tr>
          <tr><td>✗</td><td>✗</td><td>本次不检索（现有语义，账目标记 <code>embedding: unavailable</code>）</td><td>原样</td></tr>
        </tbody>
      </table>
    </div>
    <p>
      第三行<b>刻意留空</b>，这是「<code>score</code> 必须是余弦」这条不变式的直接后果：
      稀疏单腿拿回来的只有 TF×IDF（实测 0~3.8），<b>没有可用于阈值和展示的余弦分</b>。
      强行返回会让 <code>rag_min_score=0.45</code> 要么把它们全放行（噪声）、要么全滤掉（等于没做），
      而引用卡会向作者显示「相关度 2.41」这种无法解读的数字——那比停摆更糟。
      所以远端 <code>embeddings</code> 进入 <code>_COOLDOWN_S = 60</code> 冷却期、或限流（429）时，
      整个检索<b>仍会停摆</b>。要补这一格，得先解决跨标度的分数归一化问题（见上文三条规则）。
    </p>
    <h3 id="sparse-139">代价与已知短板</h3>
    <div class="grid g2">
      <div class="card warn">
        <span class="ico">⚠️</span><h4 id="sparse-140">1. 单字查询失效</h4>
        <p>bigram 最小单位是 2。只查单字角色名「陆」匹配不到。子查询固定带身份
        （<code>"素世 主角"</code>）已经缓解了这一点，但作者直接搜单字仍会落空。</p>
      </div>
      <div class="card warn">
        <span class="ico">⚠️</span><h4 id="sparse-141">2. 跨字断词</h4>
        <p>原文若写「明 心中学」，产生的 bigram 与「明心中学」不同。取决于作者排版，不可控。</p>
      </div>
      <div class="card warn">
        <span class="ico">⚠️</span><h4 id="sparse-142">3. TF 无饱和</h4>
        <p>实测公式是<b>纯线性 TF × IDF</b>，没有 BM25 原文的 <code>k1</code> 饱和因子——
        一个词在块里出现 50 次，得分是出现 1 次的 <b>50 倍</b>。
        连带效应：设定块的「相关角色：X」前缀在<b>每块</b>都出现（由 <code>_setting_prefix()</code> 统一拼），
        等于给含该角色的块加了个不受控的恒定 boost。</p>
      </div>
      <div class="card warn">
        <span class="ico">⚠️</span><h4 id="sparse-143">4. 长度归一化缺失</h4>
        <p>没有 <code>b</code> 归一化，长块更容易得高分。对本系统影响很小——
        块长已被 <code>CHUNK_SIZE=500</code> 统一（章节 379 + 前缀 ≤120，文档 500），
        这算是「块大小固定」带来的意外好处。</p>
      </div>
    </div>
    <h3 id="sparse-144">性能开销：实测数字</h3>
    <p>
      全部在<b>本地 Qdrant 模式</b>下测得。先说清一件事：<b>本地模式是锁竞争型的，比远端悲观得多</b>
      （<code>QdrantLocal</code> 对存储加全局锁），所以下面第一组数字应视为<b>上界</b>。
    </p>
    <h4 id="sparse-145">① 本地编码：可忽略</h4>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>操作</th><th>实测</th><th>一次写章</th></tr></thead>
        <tbody>
          <tr><td><code>encode_text(379 字块)</code></td><td><b>88.2 μs</b></td><td>14 块 → 1.23 ms</td></tr>
          <tr><td><code>encode_text(20 字子查询)</code></td><td><b>8.4 μs</b></td><td>6 条 → 0.05 ms</td></tr>
          <tr><td colspan="2"><b>合计</b></td><td><b>≈ 1.3 ms</b></td></tr>
        </tbody>
      </table>
    </div>
    <p>纯 CPU、零 IO，不进任何关键路径的可观量级。</p>
    <h4 id="sparse-146">② 写入吞吐：无差异</h4>
    <pre>sparse=False  写 40 块: 352.9 ms  (8.82 ms/块)
sparse=True   写 40 块: 333.3 ms  (8.33 ms/块)   <span class="c"># 差异在噪声内</span></pre>
    <p>
      服务端存储从 <code>+1.7 KB/点</code> 涨到 <code>+2.4 KB/点</code>
      （每块 313 个 distinct bigram × 8 字节），比 1024 维稠密的 4.0 KB <b>还小 0.6 倍</b>。
      60 万字（2060 块）约多占 <b>4.9 MB</b>。
    </p>
    <h4 id="sparse-147">③ 检索延迟：写章路径 +65%（本地，悲观值）</h4>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>路径</th><th>sparse=off</th><th>sparse=on</th><th>增幅</th></tr></thead>
        <tbody>
          <tr>
            <td><b>写章</b> <code>_fetch_per_query</code>（6 子查询）</td>
            <td><b>67.5 ms</b></td><td><b>111.5 ms</b></td><td style="color:var(--warn)"><b>+65%</b></td>
          </tr>
          <tr>
            <td>单条 <code>search_by_embedding</code></td>
            <td>0.85 ms</td><td>2.45 ms</td><td style="color:var(--warn)">+188%</td>
          </tr>
        </tbody>
      </table>
    </div>
    <p>
      两处增幅都来自<b>请求数翻倍</b>：每条子查询从 1 次远程调用变成 2 次
      （稠密 + 稀疏），本地模式下这两次还会在同一把存储锁上排队。
    </p>
    <h4 id="sparse-148">④ 一次踩坑的实测：并发化反而更慢</h4>
    <p>
      第一版把两腿放进<b>嵌套线程池</b>并发（想省掉第二次 RTT），结果：
    </p>
    <div class="vs">
      <div class="card ok">
        <h4 id="sparse-149">串行</h4>
        <p style="font-family:var(--mono);font-size:13px;margin:0">0.578 → 1.152 ms<br><small>（sparse off→on）</small></p>
      </div>
      <div class="mid">→</div>
      <div class="card warn">
        <h4 id="sparse-150">嵌套并发</h4>
        <p style="font-family:var(--mono);font-size:13px;margin:0">0.651 → <b>4.410 ms</b><br><small>恶化 6.8×</small></p>
      </div>
    </div>
    <p>
      本地 Qdrant 的全局存储锁让两条腿<b>互相争锁</b>，线程切换成本（~百微秒级）
      远大于那 0.6 ms 的活。改成<b>复用 <code>_fetch_per_query</code> 外层本来就有的
      6 worker</b>（6 子查询 × 2 腿 = 12 个任务），不再有嵌套。
      <b>教训：没有实测就不要凭直觉优化——"并发省 RTT" 在锁竞争型后端上是负收益。</b>
    </p>
    <h3 id="sparse-151">远端会是多少：诚实的不确定性</h3>
    <p>
      生产走 <b>Qdrant Cloud</b>（HTTP，RTT 主导，<b>无全局锁</b>），本地这组数字<b>不能直接套用</b>。
      能确定的只有<b>请求数</b>与<b>传输量</b>：
    </p>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>项目</th><th>off</th><th>on</th><th>说明</th></tr></thead>
        <tbody>
          <tr><td>每条子查询的远程调用</td><td>1</td><td>2</td><td>稠密 + 稀疏</td></tr>
          <tr><td>两腿是否并发</td><td>—</td><td><b>是</b></td><td>同一个 6 worker 池，<b>关键路径仍 1 次 RTT</b></td></tr>
          <tr><td>并发请求数</td><td>6</td><td>12</td><td>Qdrant Cloud 无锁，可真正并行</td></tr>
          <tr><td>稠密腿候选</td><td><code>PER_SUBQUERY_TOP_K = 3</code></td><td><code>10</code></td><td><code>_SPARSE_LEG_K</code>，多传 ~10 KB/子查询</td></tr>
        </tbody>
      </table>
    </div>
    <p>
      <b>合理推断</b>：远端增量主要是「同样 1 次 RTT 内多打 6 个请求 + 多传 60 KB」，
      预计<b>是个位数百分比</b>，远好于本地测到的 +65%。
      <b>但这是推断，我没有远端实测数据</b>——本地模式复现不出远端的网络行为。
    </p>
    <div class="note w"><b>⚠ 要拿到真实数字，最省事的办法</b><div>
      写一个一次性脚本，对同一个项目分别用 <code>RAG_SPARSE_ENABLED=false/true</code>
      跑一次 <code>rag_retrieve_hits_with_stats</code>，各重复 10 次取中位数：
      它只需要一个能连云端的开发机，<b>不改任何生产代码</b>。要我把这个脚本写出来吗？
    </div></div>
    <h3 id="sparse-152">启用方式与迁移</h3>
    <p>
      开关是 <code>RAG_SPARSE_ENABLED</code>（默认 <code>false</code>）。
      <b>关闭时集合名、写入形态、检索路径全部与改造前逐字一致</b>，可以灰度上线。
    </p>
    <div class="note w"><b>⚠ 启用前必须知道的一件事：老数据在稀疏路等于不存在</b><div>
      点没有 <code>bm25</code> 向量 → 稀疏点积恒为 0 → <b>永远进不了任何一路的候选</b>。
      若只给新数据加稀疏，融合时老章节只能靠稠密吃名次，<b>偏差方向固定（新章节占优）</b>。<br>
      本实现选择<b>换集合名 + 重嵌入</b>，放弃补写。其中<b>唯一必须搬的是 document 域</b>
      （作者上传的设定参考）——它的原文<b>不留存</b>，只存在于旧集合 payload 里，
      <code>reindex</code> 对它是故意「不删不重嵌」的。章节 / 设定 / 伏笔都能重跑。
    </div></div>
    <p>
      好消息：若确需补写，原文与稠密向量都能从 Qdrant 读回来，
      <b>0 次 embedding 调用</b>即可只补稀疏向量（<code>scroll</code> 分页 → 读回
      <code>vector["text"]</code> 与 <code>payload["_text"]</code> → 一并 upsert）。
    </p>
    <h3 id="sparse-153">代码地图</h3>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>文件</th><th>职责</th><th>关键点</th></tr></thead>
        <tbody>
          <tr>
            <td><span class="path">app/core/sparse.py</span></td>
            <td>稀疏编码器（<b>纯函数</b>）</td>
            <td><code>encode_text</code> <code>encode_bigram</code> <code>bigrams</code>；<b>不 import qdrant_client</b>，可脱离 Qdrant 单测</td>
          </tr>
          <tr>
            <td><span class="path">app/core/vector_store.py</span></td>
            <td>命名向量 + 稀疏存取</td>
            <td><code>DENSE_NAME</code> <code>SPARSE_NAME</code> <code>sparse_enabled</code> <code>_to_sparse_vector</code> <code>_points_to_chroma</code> <code>query_sparse</code></td>
          </tr>
          <tr>
            <td><span class="path">app/core/rag.py</span></td>
            <td>编排 + RRF 重排</td>
            <td><code>_hits_from_chroma</code> <code>_rrf_merge</code> <code>_query_sparse</code>；<code>add_documents</code> 同步算两路</td>
          </tr>
          <tr>
            <td><span class="path">app/config.py</span></td>
            <td>开关</td><td><code>rag_sparse_enabled</code>（默认 false）<code>rag_rrf_k</code></td>
          </tr>
          <tr>
            <td><span class="path">tests/test_sparse.py</span></td>
            <td>22 条回归</td>
            <td>编码确定性 / 2 字查询 / 零冲突 / <b>score 仍是余弦</b> / 稀疏不引入新文档 / 默认关闭不变</td>
          </tr>
        </tbody>
      </table>
    </div>
    <div class="note i"><b>💡 这一路教给我们的事</b><div>
      教科书式的混合检索（两路分数归一化后加权）在这套系统里<b>会静默失效</b>——
      根源在<b>它假设两路分数量纲可比</b>，实现本身没有错，而本系统的
      <code>rag_min_score</code>、引用卡「相关度」、检索账目三处都建立在「分数是余弦」这个前提上。
      引入第二条检索路时，必须先确认<b>下游对分数的假设有没有被写死</b>。
    </div></div>
  </div>
</section>
<!-- ===================== 20 结构化优先 ===================== -->
<section id="structured-first">
  <div class="wrap">
    <div class="eyebrow">20 · Structure Before Vectors</div>
    <h2 id="structured-first">能结构化的，别丢给向量检索</h2>
    <p class="lead">
      一条容易被当成教条的原则：<b>能结构化存储与过滤的实体，尽量不要塞进向量</b>。
      但真正该做的只有一件事：<b>把永不出现在查询里的结构化搬走</b>。这一节记录按这条判据做的审计与修复。
    </p>
    <h3 id="structured-first-155">判据：它会出现在查询里吗</h3>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>字段</th><th>出现在查询里？</th><th>处置</th></tr></thead>
        <tbody>
          <tr>
            <td>伏笔 <code>status</code> / <code>planted_chapter_index</code></td>
            <td style="color:var(--danger)"><b>从不</b>（子查询只用 <code>description</code>）</td>
            <td style="color:var(--ok)"><b>移出向量</b>，只留 payload</td>
          </tr>
          <tr>
            <td>角色名 / 章名（身份标识）</td>
            <td style="color:var(--ok)"><b>必须出现</b>（查询里就是它）</td>
            <td>留在向量，且<b>每块都要有</b></td>
          </tr>
          <tr>
            <td>章纲 <code>outline_summary</code></td>
            <td style="color:var(--ok)"><b>就是查询本身</b>（<code>build_story_queries</code> 用 title+summary）</td>
            <td>留在向量（去掉会削弱召回）</td>
          </tr>
          <tr>
            <td><code>tier</code> / <code>gender</code> / <code>age</code></td>
            <td style="color:var(--danger)">从不，且是枚举值</td>
            <td>只留 payload，不进文本</td>
          </tr>
          <tr>
            <td><code>appearance</code> / <code>speech_style</code></td>
            <td style="color:var(--ok)">可能（"说话方式很温柔的角"）</td>
            <td><b>补进</b>向量（此前漏了）</td>
          </tr>
        </tbody>
      </table>
    </div>
    <h3 id="structured-first-156">修掉的四个问题</h3>
    <h4 id="structured-first-157">① 设定块切块后失去归属（真实缺陷）</h4>
    <p>
      此前身份头（<code>角色-素世(主角):</code>）只在文本开头，被 <code>chunk_text</code> 切走后就
      只留在第 0 块。实测一段 615 字的角色设定切 2 块后：
    </p>
    <pre>块0: 含角色名=True   '角色-苏素世(主角): 性格=她站在走廊尽头…'
块1: 含角色名=False  '她站在走廊尽头，指尖还沾着未干的血迹…'
⚠ 搜「苏素世」召不回: [1] / 共 2 块</pre>
    <p>
      <code>index_chapter</code> 早就靠「每块都加章纲前缀」规避了这个问题（见 §5），
      设定块一直没有。<b>写得越细的角色，块越多，丢的块越多。</b>
    </p>
    <div class="note g"><b>✓ 修法</b><div>
      身份前缀与「相关角色」<b>逐块拼</b>，并共用同一份 <code>ENRICH_RESERVE</code>(120) 预算——
      正文预算相应缩减，保证「前缀 + 正文 ≤ <code>CHUNK_SIZE</code>」这条不变量①不被破坏。
    </div></div>
    <h4 id="structured-first-158">② 伏笔的状态与埋于章号进了向量，却永远匹配不到</h4>
    <pre>入库文本 = '伏笔-f07: &lt;描述&gt; (状态: pending, 埋于: 第7章)'
子查询   = '&lt;描述&gt;'            <span class="c">← 不含「状态」「埋于」</span></pre>
    <p>
      这 22 字每次状态变更都逼着重新 embedding，却<b>匹配不到任何 query</b>。
      现在 <code>status</code> / <code>chapter_index</code> 只进 payload（仍可过滤与展示）。
    </p>
    <h4 id="structured-first-159">③ 因此多出来的收益：伏笔重建不必全量重嵌入</h4>
    <p>
      把结构化字段挪出去之后，「哪些伏笔需要重算」就能靠<b>描述是否变化</b>精确判断了。
      此前删一章要「删掉全部伏笔向量 + 全部重新嵌入」：
    </p>
    <div class="tbl-wrap">
      <table>
        <thead><tr><th>规模</th><th>此前</th><th>现在</th></tr></thead>
        <tbody>
          <tr><td>50 条伏笔，删 1 条</td><td><b>49 次</b> embedding</td><td style="color:var(--ok)"><b>1 次</b></td></tr>
        </tbody>
      </table>
    </div>
    <p>
      由 <code>foreshadow_changed_ids(before, after)</code> 计算，陈旧块清理仍按<b>全量</b> alive 做，
      所以跳过嵌入不会留下孤儿。<b>只改状态不重嵌入</b>——这正是 ② 的直接回报。
    </p>
    <h4 id="structured-first-160">④ 角色设定块漏了两个散文型字段</h4>
    <p>
      <code>appearance</code>（外貌）与 <code>speech_style</code>（说话方式）在
      <code>_character_block</code> 直塞里<b>有</b>（写作 prompt 看得到），
      但此前<b>不在向量文本里</b> —— 搜"说话方式"召不回设定块。现已补上。
      而 <code>tier</code>/<code>gender</code>/<code>age</code> 是枚举值，进文本只是噪声，仍只留 payload。
    </p>
    <h3 id="structured-first-161">顺带修掉的两条路径不一致</h3>
    <p>
      <code>index_foreshadow</code> 曾用 <code>chunk_text</code> 的<b>默认 500</b>，
      而 <code>index_settings</code> 用 <code>CONTENT_BUDGET</code>(379)——
      两条路径块数不同，于是<b>各自把对方的块当成陈旧块删除</b>，删章时来回拉锯。
      现在两者共用 <code>_setting_prefix()</code> 与 <code>_body_budget()</code>，规则只有一份。
    </p>
    <p>
      同样地，设定块的「相关角色」前缀原本由 <code>_enrich_entries</code> 在切块<b>之后</b>追加，
      与新的身份前缀叠加会突破 120 字预算。该函数已删除，逻辑并入 <code>add_chunks</code>：
      两个前缀在<b>切块前</b>一次性拼好、按同一份预算 clip。
    </p>
    <h3 id="structured-first-162">一个更隐蔽的回归（值得单列）</h3>
    <p>
      做实体归一化时把 <code>index_settings</code> 的迭代源从 <code>state["character_settings"]</code>
      换成了 <code>_char_entries()</code>，而后者只归一化「怎么称呼这个角色」
      （id/name/role/aliases），<b>丢掉了 prose 字段</b>。于是角色块文本变成
      <code>角色-苏素世(主角):性格=, 背景=, 目标=</code>——
      <b>设定块被索引成空壳，而检索照样返回它，不报任何错</b>。
    </p>
    <div class="note d"><b>✗ 为什么测试没抓住</b><div>
      当时的用例只断言了别名部分（<code>别名=…</code> 存在），没断言字段值本身。
      教训：<b>断言要检查「内容对不对」，只查「字段在不在」不够</b>。
      现在 <code>_char_entries</code> 带上 <code>raw</code> 原字典，并有两条用例锁死它。
    </div></div>
    <h3 id="structured-first-163">什么时候该破例</h3>
    <p>
      判据是「<b>查询会不会用到它</b>」。
      章纲 <code>summary</code> 是结构化的（存在 State 里），但<b>它就是查询本身</b>，
      所以必须留在向量里；身份前缀同理。反过来 <code>status</code> 存在 State 里、
      却从不出现在查询里，那就该走 payload。
    </p>
    <p>
      一句话：<b>能过滤的不进向量，能被查询到的必须进向量，两者重合时看哪个更便宜。</b>
    </p>
  </div>
</section>
</div>
