---
title: nano-graphrag 从入门到理解
description: 面向初学者的 nano-graphrag 教程：从大模型的局限讲到 GraphRAG 的写入与查询全流程，共 20 讲。
outline: [2, 3]
---

# nano-graphrag 从入门到理解

<p class="mini">一份写给初学者的教程 · 前置要求：会一点 Python，不需要懂 RAG / 图算法 · <a href="/graphrag/nano-graphrag-tutorial-mindmap">思维脑图</a></p>
<!-- ==================== 第一部分 ==================== -->
<div class="part">
  <div class="pno">Part 1</div>
  <h2 id="为什么需要-nano-graphrag">为什么需要 nano-graphrag</h2>
  <p>这一部分不写代码。先把问题讲清楚：大模型缺什么、普通 RAG 补了什么、还差什么，最后才引出 GraphRAG。</p>
</div>
<section class="lesson" id="l1">
  <div class="lhead"><div class="lno">01</div><h3 id="l1">大模型回答不了的两个问题</h3><span class="ldiff">入门</span></div>
  <div class="lbody">
    <p>假设你手里有一批公司内部文档，你想让 AI 帮你回答问题。会遇到两类麻烦：</p>
    <div class="box ex"><b class="hd">问题一 · 资料太长，塞不进去</b>
      你问大模型（LLM）一个关于公司制度的问题，但制度文件有 200 页。模型的<span class="term" title="上下文窗口：模型一次能&quot;看见&quot;的最大文字量，比如 8000 词、128k token">上下文窗口</span>有限，塞不下，而且直接塞进去又贵又慢。那怎么办？——先帮用户把相关的几段找出来，再让模型只读这几段来回答。这就是下一篇要讲的 RAG。</div>
    <div class="box ex"><b class="hd">问题二 · 问题需要"串起来"看</b>
      看这个具体例子，本文档从头到尾都会用它：<br><br>
      <strong>文档 A</strong>：「小李在杭州的<strong>茶百道</strong>工作，负责新茶饮研发。」<br>
      <strong>文档 B</strong>：「<strong>茶百道</strong>是一家 2008 年成立于成都的奶茶连锁品牌。」<br><br>
      你问：<em>「小李的公司成立于哪一年？」</em><br><br>
      答案是 2008 年，但必须经过两步：<span class="term" title="跨文档、跨段落需要多次推理才能得到答案">多跳推理</span>——先由「小李的公司」推出是「茶百道」，再由「茶百道」查到「2008 年」。<strong>单独任何一段文字里都没有完整答案</strong>。如果你的搜索只返回了文档 A，模型就会答"不知道"。</div>
    <div class="box sn"><b class="hd">顺带一提</b>
      还有第二种问法：<em>「这些文档里的公司整体发展情况如何？」</em>——这需要<strong>通读全部资料做归纳</strong>，光靠"找几段"解决不了。后面我们会看到 GraphRAG 对这两类问题各给了一套答案。</div>
    <div class="box kp"><b class="hd">本课要点</b>
      LLM 有两个短板：①看不见窗口外的资料；②不擅长跨段落串线索。整篇教程要解决的就是这两个短板。</div>
  </div>
</section>
<section class="lesson" id="l2">
  <div class="lhead"><div class="lno">02</div><h3 id="l2">检索增强生成（RAG）：先查再答</h3><span class="ldiff">入门</span></div>
  <div class="lbody">
    <p><strong>RAG（Retrieval-Augmented Generation，检索增强生成）</strong>的思路一句话就能说完：</p>
    <div class="box an"><b class="hd">类比：开卷考试</b>
      闭卷考试 = 让模型靠记忆回答（容易编造，且不知道你的私有资料）。<br>
      开卷考试 = 允许翻书，但<strong>先把最相关的几页翻出来</strong>，再基于翻出来的页作答。<br>
      RAG 就是"开卷考试"里的<strong>翻书动作</strong>（检索）+ <strong>作答动作</strong>（生成）。</div>
    <p>完整流程分两个阶段：</p>
    <div class="flow">
      <div class="fbox f1">离线准备<small>把资料切成小块<br>存进检索库</small></div>
      <div class="arr">→</div>
      <div class="fbox f2">在线提问<small>把问题也转成同样形式<br>找出最相关的几块</small></div>
      <div class="arr">→</div>
      <div class="fbox f3">拼进提示词<small>问题 + 找到的几块<br>一起交给 LLM</small></div>
      <div class="arr">→</div>
      <div class="fbox f4">得到回答<small>模型基于资料作答<br>大幅减少编造</small></div>
    </div>
    <p>被切成的每一小块叫一个 <strong><span class="term" title="chunk：被切出来的文字片段，RAG 的基本存储单位">分块（chunk）</span></strong>。为什么按块存？因为检索时"粒度"要小——一篇 5000 字的文章里可能只有 200 字和你的问题相关，返回整篇既浪费又会淹没重点。</p>
    <p>那么"找出最相关的几块"具体怎么实现？这就引出下一课的<span class="term" title="embedding：把文字转换成一串数字（向量），语义相近的文字坐标也相近">向量检索</span>。</p>
    <div class="box kp"><b class="hd">本课要点</b>
      RAG = 检索 + 生成。资料先切成 chunk 存起来；提问时找出最相关的几块，连同问题一起给 LLM。它解决了"问题一（资料太长）"，但还没解决"问题二（多跳推理）"。</div>
  </div>
</section>
<section class="lesson" id="l3">
  <div class="lhead"><div class="lno">03</div><h3 id="l3">向量检索：让机器"读懂"语义</h3><span class="ldiff">入门</span></div>
  <div class="lbody">
    <p>怎么判断"哪几块和问题相关"？最朴素的办法是关键词匹配——搜"奶茶"就找含"奶茶"的块。但"开奶茶店"和"经营饮品连锁"没有共同关键词，语义上却是近义的。</p>
    <p><strong><span class="term" title="embedding / 向量化：用一个模型把任意文字映射成固定长度的数字数组">Embedding（向量化）</span></strong>解决这个问题：用一个专门的模型把文字变成一串数字（一个坐标点），规则是——<strong>意思越接近的文字，坐标离得越近</strong>。</p>
    <div class="box an"><b class="hd">类比：地图上的城市</b>
      把每段文字想成地图上的一个城市。<br>
      「开奶茶店」和「经营饮品连锁」是两座挨得很近的城市；<br>
      「光伏板清洗」是十万八千里外的另一座城市。<br>
      所谓检索，就是<strong>以"问题"这座城为圆心，找最近的几座城</strong>。</div>
    <p>存这些坐标的地方叫<span class="term" title="向量数据库：专门存储向量并高效计算&quot;谁离我最近&quot;的数据库">向量数据库</span>（向量库）。查询时：把问题也转成坐标 → 计算距离 → 返回最近的 top-k 块。距离常用<span class="term" title="余弦相似度：只看两个向量方向是否一致，范围 -1~1，1 为最相似">余弦相似度</span>衡量。</p>
    <div class="box sn"><b class="hd">对应到本项目</b>
      nano-graphrag 默认用一个叫 <code>nano-vectordb</code> 的超轻量向量库（作者自己写的），数据就是一个 JSON 文件，开箱即用——初学者不用装任何数据库服务。</div>
    <div class="box kp"><b class="hd">本课要点</b>
      Embedding 把文字变坐标，向量库按"距离最近"返回 top-k。这一步让检索从"关键词匹配"升级为"语义匹配"。</div>
  </div>
</section>
<section class="lesson" id="l4">
  <div class="lhead"><div class="lno">04</div><h3 id="传统-rag-的三个短板">传统 RAG 的三个短板</h3><span class="ldiff">入门</span></div>
  <div class="lbody">
    <p>普通 RAG（切块 → 向量检索）很好用，但有三个天然短板，正好对应第一课的两个问题：</p>
    <table>
      <tr><th>短板</th><th>用茶百道例子说明</th><th>本质原因</th></tr>
      <tr>
        <td><strong>① 链条断裂</strong></td>
        <td>问「小李的公司成立于哪年」，系统只召回文档 A（提到小李和茶百道），<strong>答案所在的文档 B 没被召回</strong>，模型答不出 2008。</td>
        <td>检索是"一步到位"的，不会顺着线索再查第二步。</td>
      </tr>
      <tr>
        <td><strong>② 全局失明</strong></td>
        <td>问「这批文档里的公司整体情况如何」，只能返回 top-10 个碎片，<strong>谁也代表不了全貌</strong>。</td>
        <td>top-k 天然只给局部，无法回答"整体怎么样"。</td>
      </tr>
      <tr>
        <td><strong>③ 信息孤岛</strong></td>
        <td>同一个实体「茶百道」在 5 个文档里各有一段描述，检索时可能只命中其中 1 段，<strong>其他 4 段白白浪费</strong>。</td>
        <td>块与块之间是割裂的，没有"这些块说的是同一件事"的概念。</td>
      </tr>
    </table>
    <div class="box wa"><b class="hd">一句话总结病症</b>
      传统 RAG 把资料看成<strong>一堆互不相干的纸片</strong>，而真实世界的知识是<strong>一张互相连接的网</strong>。要治本，就得让系统真正拥有那张"网"。</div>
    <div class="box kp"><b class="hd">本课要点</b>
      多跳问题答不了、全局问题答不了、同实体信息不聚合——三者的共同根源是"没有建模事物之间的关系"。</div>
  </div>
</section>
<section class="lesson" id="l5">
  <div class="lhead"><div class="lno">05</div><h3 id="知识图谱与-graphrag-思路">知识图谱与 GraphRAG 思路</h3><span class="ldiff">入门</span></div>
  <div class="lbody">
    <p><strong><span class="term" title="Knowledge Graph：用&quot;节点=事物，边=关系&quot;的方式组织知识的数据结构">知识图谱</span></strong>（Knowledge Graph）就是上一课说的那张"网"：</p>
    <ul>
      <li><strong>节点（Node）= 实体</strong>：人、公司、地点、事件…… 如「小李」「茶百道」「杭州」</li>
      <li><strong>边（Edge）= 关系</strong>：两个实体之间有联系。如 小李 —<em>就职于</em>→ 茶百道</li>
      <li>每个节点/边上还可以挂一段<strong>描述文字</strong>和一个<strong>权重</strong>（关系多强）</li>
    </ul>
    <p>用例子画出来是这样：</p>
    <pre>
[小李] ──就职于(权重8)──▶ [茶百道] ──成立于2008──▶ [成都]
  │                         │
  └──位于──[杭州]        ──总部位于──[成都]
问题「小李的公司成立于哪年？」在图上就是走两步：
   小李 ──就职于──▶ 茶百道 ──成立于──▶ 2008   ✔ 两个块的信息被边"串"起来了</pre>
    <p><strong>GraphRAG 的完整思路</strong>（微软 2024 年提出，nano-graphrag 是它的极简实现）分两个阶段：</p>
    <div class="flow">
      <div class="fbox f1">阶段一 · 建索引<small>读完所有文档<br>让 LLM 抽出实体关系<br>拼成知识图谱</small></div>
      <div class="arr">＋</div>
      <div class="fbox f4">阶段一 · 写报告<small>把图分成若干"社区"<br>给每个社区生成<br>一份摘要报告</small></div>
      <div class="arr">＝</div>
      <div class="fbox f2">阶段二 · 查询<small>沿着图找线索（治①③）<br>读社区报告（治②）</small></div>
    </div>
    <p>三个短板与解法一一对应：</p>
    <table>
      <tr><th>短板</th><th>GraphRAG 的解法</th></tr>
      <tr><td>链条断裂</td><td>答案相关的实体和关系被<strong>边</strong>连着，检索时沿着边走一步、两步，把断开的链条接上</td></tr>
      <tr><td>全局失明</td><td>提前为每个<strong>社区</strong>写好摘要报告，查询时读的是现成报告，不必拼碎片</td></tr>
      <tr><td>信息孤岛</td><td>同一实体在图里是<strong>同一个节点</strong>，所有文档里的描述都合并挂在这个节点上</td></tr>
    </table>
    <div class="box kp"><b class="hd">本课要点 · 第一部分收尾</b>
      GraphRAG = 先用 LLM 把语料"读薄"成知识图谱 + 社区报告，再基于图回答问题。nano-graphrag 就是这条路线的最小完整版（官方 README 口径约 1100 行、不含测试与 Prompt；按当前源码实测核心约 2900 行，见参考手册第 1 章）。<strong>接下来五课先看全景，再逐站拆解。</strong></div>
  </div>
</section>
<!-- ==================== 第二部分 ==================== -->
<div class="part">
  <div class="pno">Part 2</div>
  <h2 id="先看全景一次写入一次查询">先看全景：一次写入、一次查询</h2>
  <p>先不纠结细节，把整个系统的"输入 → 中间产物 → 输出"走一遍，建立地图感。后面第三、四部分再逐站深入。</p>
</div>
<section class="lesson" id="l6">
  <div class="lhead"><div class="lno">06</div><h3 id="l6">insert：把文章变成知识</h3><span class="ldiff">入门</span></div>
  <div class="lbody">
    <p>使用这个库只有两个动作，这是第一个。你写代码时它长这样：</p>
    <pre><span class="k">from</span> nano_graphrag <span class="k">import</span> GraphRAG
graph = GraphRAG(working_dir=<span class="s">"./my_kg"</span>)
graph.insert(<span class="s">"小李在杭州的茶百道工作……"</span>)   <span class="cm"># 把文档喂进去</span></pre>
    <h4 id="l6-run">先跑通一次：完整脚本与预期输出</h4>
    <p>光看这三行不知道跑起来是什么样。下面是一份<strong>可以直接复制运行</strong>的最小脚本（面向 OpenAI 官方接口）：</p>
    <pre><span class="cm"># 1. 装依赖（Python 3.9+）：pip install nano-graphrag</span>
<span class="cm"># 2. 设密钥（必填，默认用 OpenAI 的模型和 embedding）：export OPENAI_API_KEY="sk-..."</span>
<span class="cm"># 3. 存成 run.py 后执行：python run.py</span>
<span class="k">from</span> nano_graphrag <span class="k">import</span> GraphRAG, QueryParam
graph = GraphRAG(working_dir=<span class="s">"./my_kg"</span>)
docs = [
    <span class="s">"小李在杭州的茶百道工作，负责新茶饮研发。"</span>,
    <span class="s">"茶百道是一家 2008 年成立于成都的奶茶连锁品牌，总部位于成都。"</span>,
]
graph.insert(docs)   <span class="cm"># 这一步会调用 LLM 抽取实体关系，是全程最慢最花钱的一步</span>
print(graph.query(<span class="s">"小李的公司成立于哪一年？"</span>, QueryParam(mode=<span class="s">"local"</span>)))</pre>
    <p>预期输出（示意——文字会因模型而异，但<strong>类型一定是字符串、且能推出 2008</strong>）：</p>
    <div class="box ex"><b class="hd">控制台看到的内容</b>
      <pre>根据提供的资料，小李就职于茶百道；茶百道于 2008 年在成都成立。因此，小李的公司成立于 <strong>2008 年</strong>。</pre>
      注意两点：<code>graph.query(...)</code> 返回的是<strong>一段字符串</strong>；<code>graph.insert(...)</code> 期间屏幕会打出大量日志（分块、抽取、聚类、写报告各阶段的 INFO），属于正常现象。</div>
    <div class="box sn"><b class="hd">没有 API key 怎么办</b>
      仓库自带 <code>examples/no_openai_key_at_all.py</code>，用 Ollama 跑本地模型即可完整体验流程（质量差些，但产物结构一模一样。拿 DeepSeek 等 OpenAI 兼容服务也行：改 <code>best_model_func</code> / <code>embedding_func</code> 指向自家接口，见第 8 课地图里的 <code>_llm.py</code>）。</div>
    <p>这一行 <code>insert</code> 背后发生了 6 件事，每件都在磁盘 <code>./my_kg/</code> 留下产物：</p>
    <div class="flow" style="flex-direction:column">
      <div class="fbox f5">① 切块：长文按 1200 token 切成小块，每块算一个 MD5 编号（重复内容自动跳过）<small>产物：kv_store_text_chunks.json</small></div>
      <div class="arr">↓</div>
      <div class="fbox f3">② 抽取：把每块喂给 LLM，让它输出这段里的实体和关系<small>LLM 调用 · 最花钱的一步</small></div>
      <div class="arr">↓</div>
      <div class="fbox f2">③ 合并：多篇文档提到的同一实体合并成一个节点，描述拼接（太长就让 LLM 压缩）<small>产物：graph_chunk_entity_relation.graphml</small></div>
      <div class="arr">↓</div>
      <div class="fbox f4">④ 分组：用聚类算法把图分成一个个"社区"（互相紧密的一簇节点）<small>每个节点记下自己属于哪个社区</small></div>
      <div class="arr">↓</div>
      <div class="fbox f1">⑤ 报告：给每个社区让 LLM 写一份摘要报告（含 0-10 评分）<small>产物：kv_store_community_reports.json</small></div>
      <div class="arr">↓</div>
      <div class="fbox f2">⑥ 索引：把所有实体名+描述向量化，存入向量库<small>产物：vdb_entities.json</small></div>
    </div>
    <div class="box sn"><b class="hd">提示</b>
      你不需要记住这 6 步的细节——但要记住它们的<strong>顺序</strong>：切块 → 抽取 → 合并 → 分组 → 报告 → 索引。第三部分（第 9~13 课）就是按这个顺序逐个展开的。</div>
    <h4 id="l6-files">磁盘上的产物长什么样</h4>
    <p>跑完那次最小脚本，<code>./my_kg/</code> 里会多出 5 个文件。用文本编辑器打开，能看到这类内容（字段与源码 <code>base.py</code> 的 Schema 一一对应）：</p>
    <div class="box ex"><b class="hd">kv_store_text_chunks.json（切块 + 文档原文）</b>
      <pre>{
  "chunk-3f2a…": {
    "tokens": 96,                                  <span class="cm"># 这块有多少 token</span>
    "content": "小李在杭州的茶百道工作，负责新茶饮研发。",
    "full_doc_id": "doc-8b1c…",                   <span class="cm"># 属于哪篇文档</span>
    "chunk_order_index": 0                        <span class="cm"># 在文档中的序号</span>
  }
}</pre></div>
    <div class="box ex"><b class="hd">kv_store_community_reports.json（社区报告，查询时读它）</b>
      <pre>{
  "0": {
    "level": 0, "title": "茶百道公司与人员社区",
    "nodes": ["小李","茶百道","杭州"],
    "edges": [["小李","茶百道"],["茶百道","成都"]],
    "chunk_ids": ["chunk-3f2a…","chunk-91dd…"],
    "occurrence": 1.0,                            <span class="cm"># 覆盖原文块数 ÷ 最大社区的块数</span>
    "sub_communities": [],
    "report_json": {"title": "…", "summary": "…",
                    "rating": 7, "findings": [{"summary": "…", "explanation": "…"}]}
  }
}</pre></div>
    <div class="box ex"><b class="hd">graph_chunk_entity_relation.graphml（图 + 社区归属）</b>
      <pre>&lt;node id="茶百道"&gt;
  &lt;data key="clusters"&gt;[{"level":0,"cluster":0}]&lt;/data&gt;   <span class="cm"># 这个节点属于哪层哪个社区</span>
  &lt;data key="source_id"&gt;chunk-3f2a…,chunk-91dd…&lt;/data&gt;    <span class="cm"># 哪些块提到了它</span>
&lt;/node&gt;</pre>
      图结构（谁连谁）以边的形式存在同一文件里；社区归属被塞进节点属性 <code>clusters</code>，这就是"图和社区天然一体"的含义。</div>
    <div class="box kp"><b class="hd">本课要点</b>
      insert 是离线的"读书"过程：文字 → 实体关系图 → 社区 → 社区报告 → 向量索引。所有产物都落在一个工作目录里，删掉目录 = 全部重来。</div>
  </div>
</section>
<section class="lesson" id="l7">
  <div class="lhead"><div class="lno">07</div><h3 id="l7">query：三种提问方式</h3><span class="ldiff">入门</span></div>
  <div class="lbody">
    <p>第二个动作是提问，通过 <code>QueryParam(mode=...)</code> 选三种模式之一：</p>
    <pre><span class="k">from</span> nano_graphrag <span class="k">import</span> QueryParam
graph.query(<span class="s">"小李的公司成立于哪一年？"</span>, QueryParam(mode=<span class="s">"local"</span>))   <span class="cm"># 问细节</span>
graph.query(<span class="s">"这批公司整体发展如何？"</span>,     QueryParam(mode=<span class="s">"global"</span>))  <span class="cm"># 问全局</span>
graph.query(<span class="s">"茶百道总部在哪？"</span>,           QueryParam(mode=<span class="s">"naive"</span>))   <span class="cm"># 翻原文</span></pre>
    <table>
      <tr><th>模式</th><th>适用提问</th><th>直觉类比</th><th>数据来源</th></tr>
      <tr>
        <td><strong>local</strong><br><span class="mini">本地/局部检索</span></td>
        <td>关于某个实体的具体事实，需要串线索</td>
        <td><strong>顺着人脉查</strong>：先找到当事人，再问他的同事、他的事迹、相关的会议纪要</td>
        <td>向量库找回实体 → 沿图扩展 → 报告＋原文</td>
      </tr>
      <tr>
        <td><strong>global</strong><br><span class="mini">全局检索</span></td>
        <td>整体情况、主题归纳、跨社区的大问题</td>
        <td><strong>开总结大会</strong>：每个小组（社区）先交一份发言稿，再把所有发言稿汇总成最终报告</td>
        <td>全部社区报告的 Map-Reduce</td>
      </tr>
      <tr>
        <td><strong>naive</strong><br><span class="mini">朴素 RAG</span></td>
        <td>简单事实、或想对比"不用图"的效果</td>
        <td><strong>直接翻书</strong>：不查人脉不看报告，向量搜原文照读</td>
        <td>分块向量库 top-k 原文</td>
      </tr>
    </table>
    <div class="box an"><b class="hd">为什么要有 naive？</b>
      它是<strong>对照组</strong>。同一语料下，local/global 比 naive 好多少，就是"建图"带来的价值。做实验、写报告时非常有用——这也是 nano-graphrag 特意保留它的原因。</div>
    <h4 id="l7-output">三种模式的预期输出（示意）</h4>
    <p>同一份语料（第 6 课那两段），三种模式各问一次，打印结果分别长这样（文字是示意，<strong>结构和信息粒度是真实的</strong>）：</p>
    <div class="box ex"><b class="hd">local —— 问"小李的公司成立于哪一年？"</b>
      <pre>根据资料，小李就职于茶百道；茶百道于 2008 年在成都成立，因此答案是 2008 年。</pre>
      短、直接、带出处链条——典型的事实问答。</div>
    <div class="box ex"><b class="hd">global —— 问"这批文档整体讲了什么？"</b>
      <pre>这批文档围绕"茶百道"这一新茶饮品牌展开：介绍了其总部所在地（成都）、成立时间（2008 年），
以及一名在杭州研发岗位工作的员工小李。整体呈现"公司概况 + 人员构成"两类信息。</pre>
      长、概括、跨社区——典型的主题综述。它<strong>不引用单个实体</strong>，把各社区报告的要点融成一段。</div>
    <div class="box ex"><b class="hd">naive —— 问"茶百道总部在哪？"</b>
      <pre>茶百道的总部位于成都（另有资料提到其成立于 2008 年）。</pre>
      朴素 RAG 的口吻：直接复述检索到的原文块，不做跨块推理。</div>
    <p>三个输出对比着看，"顺着人脉查 / 开总结大会 / 直接翻书"的差别就具体了。</p>
    <div class="box kp"><b class="hd">本课要点</b>
      local 问细节（沿图找）、global 问全局（读报告）、naive 兜底对照（翻原文）。第四部分（第 14~16 课）逐一拆解。</div>
  </div>
</section>
<section class="lesson" id="l8">
  <div class="lhead"><div class="lno">08</div><h3 id="l8">项目文件地图：每个文件管什么</h3><span class="ldiff">入门</span></div>
  <div class="lbody">
    <p>clone 下来的项目长这样（只看核心目录 <code>nano_graphrag/</code>）：</p>
    <table>
      <tr><th>文件</th><th>用大白话说它干嘛的</th><th>何时会细读</th></tr>
      <tr><td><code>graphrag.py</code></td><td><strong>总指挥</strong>：定义所有配置项，串起 insert/query 的每一步</td><td>第一站（第 6、7 课的流程都在这）</td></tr>
      <tr><td><code>_op.py</code></td><td><strong>加工厂</strong>：切块、抽取、合并、写报告、三种查询的全部算法</td><td>第三、四部分的主体</td></tr>
      <tr><td><code>base.py</code></td><td><strong>零件接口图</strong>：定义"一个存储零件必须有哪些方法"</td><td>第 19 课</td></tr>
      <tr><td><code>_storage/</code></td><td><strong>仓库</strong>：接口的具体实现（JSON 文件版、图数据库版……）</td><td>第 19 课</td></tr>
      <tr><td><code>_llm.py</code></td><td><strong>话务员</strong>：怎么调 OpenAI/Azure 等接口，怎么重试、怎么缓存</td><td>第 18 课</td></tr>
      <tr><td><code>_utils.py</code></td><td><strong>工具抽屉</strong>：数 token、算 MD5、限并发、容错解析 JSON 等小工具</td><td>第 17、18 课</td></tr>
      <tr><td><code>prompt.py</code></td><td><strong>话术本</strong>：所有发给 LLM 的提示词都存在这一个字典里</td><td>第 10、13 课</td></tr>
      <tr><td><code>_splitter.py</code></td><td>按标点符号切块的备选切法</td><td>第 9 课顺带看</td></tr>
    </table>
    <div class="box kp"><b class="hd">本课要点</b>
      记住三个主干文件的分工：<strong>graphrag.py 指挥、_op.py 干活、_storage/ 存东西</strong>。接下来我们按 insert 的顺序走进 _op.py。</div>
  </div>
</section>
<!-- ==================== 第三部分 ==================== -->
<div class="part">
  <div class="pno">Part 3</div>
  <h2 id="写入流程逐步拆解">写入流程逐步拆解</h2>
  <p>对应 insert 的第 ②~⑥ 步（第 9~13 课）。每课结构固定：做什么 → 为什么 → 例子走一遍 → 对应源码在哪。</p>
</div>
<section class="lesson" id="l9">
  <div class="lhead"><div class="lno">09</div><h3 id="l9">第一步：切块与去重</h3><span class="ldiff">基础</span></div>
  <div class="lbody">
    <h4 id="l9-12">做什么</h4>
    <p>把文档切成小块（chunk）。默认策略是<strong>按 token 数滑动窗口硬切</strong>：每块最多 1200 个 <span class="term" title="token：模型计费和限长的单位。1 个汉字通常约 1~2 个 token">token</span>，相邻块重叠 100 个 token。</p>
    <div class="box an"><b class="hd">为什么要重叠？</b>
      想象把一本书每 20 页装订一份复印件。如果切口正好落在一句话中间，这句话两边的块都"看不全"它。留 100 token 重叠，等于<strong>每个切口附近都有两份拷贝</strong>，关键信息不至于被切丢。</div>
    <div class="box ex"><b class="hd">例子走一遍</b>
      文档 A（约 100 token）完整装进一个块，块编号 = <code>chunk-3f2a…</code>（内容的 MD5）。<br>
      如果 5 天后你又 insert 了一次完全相同的文档 A → 系统算出的编号一模一样 → 查库发现已存在 → <strong>直接跳过，不花一分钱 LLM 调用</strong>。这就是"幂等去重"。</div>
    <h4 id="为什么要-md5-编号">为什么要 MD5 编号？</h4>
    <p>MD5 是把任意内容压缩成固定长度指纹的函数：<strong>内容相同 → 指纹必然相同；内容差一个字 → 指纹完全不同</strong>。用指纹当主键，去重、增量更新、"只处理新内容"全都免费获得了。</p>
    <h4 id="两种切法">两种切法</h4>
    <table>
      <tr><th>策略</th><th>做法</th><th>特点</th></tr>
      <tr><td><code>chunking_by_token_size</code><br><span class="mini">默认</span></td><td>无视语义，每 1200 token 一刀</td><td>简单可预测，什么语料都能用</td></tr>
      <tr><td><code>chunking_by_seperators</code></td><td>先按段落→换行→中英文句号→空格的优先级切开，再拼到 1200 以内</td><td>切口落在自然边界，句子完整，对后续 LLM 抽取更友好</td></tr>
    </table>
    <h4 id="对应源码">对应源码</h4>
    <p class="mini"><span class="fileref">_op.py:31 chunking_by_token_size</span> · <span class="fileref">_op.py:94 get_chunks</span> · <span class="fileref">_utils.py:186 compute_mdhash_id</span></p>
    <pre><span class="cm"># _op.py 滑动窗口，就 3 行核心逻辑：</span>
for start in range(0, len(tokens), max_token_size - overlap_token_size):
    chunk_token.append(tokens[start : start + max_token_size])   <span class="cm"># 每次前进 1100，取 1200</span></pre>
    <div class="box kp"><b class="hd">本课要点</b>
      切块 = 定检索粒度；重叠 = 防止信息被切丢；MD5 编号 = 内容寻址去重。这三件事是后面一切"增量、省钱"的地基。</div>
  </div>
</section>
<section class="lesson" id="l10">
  <div class="lhead"><div class="lno">10</div><h3 id="第二步让-llm-圈出实体">第二步：让 LLM 圈出实体</h3><span class="ldiff">基础</span></div>
  <div class="lbody">
    <h4 id="做什么">做什么</h4>
    <p>把每个块发给 LLM，让它按照固定话术，输出这段文字里的<strong>实体</strong>（是什么）和<strong>关系</strong>（谁和谁怎么样）。这是整个系统<strong>最花钱</strong>的一步，所有块并发进行（同时发很多请求）。</p>
    <h4 id="发给-llm-的提示词长什么样">发给 LLM 的提示词长什么样</h4>
    <p>提示词存在 <code>prompt.py</code>，简化后核心是这样：</p>
    <pre>识别文中所有实体，格式：("entity" &lt;|&gt; 实体名 &lt;|&gt; 类型 &lt;|&gt; 描述)
识别实体间关系，格式：("relationship" &lt;|&gt; 源 &lt;|&gt; 目标 &lt;|&gt; 描述 &lt;|&gt; 强度)
用 ## 分隔每条记录，全部完成后输出 &lt;|COMPLETE|&gt;
--- 示例（few-shot）---
("entity" &lt;|&gt; "Alex" &lt;|&gt; "person" &lt;|&gt; "Alex 是个观察力敏锐的角色……")##
("relationship" &lt;|&gt; "Alex" &lt;|&gt; "Taylor" &lt;|&gt; "Alex 受 Taylor 影响" &lt;|&gt; 7)
--- 真实数据 ---
Text: {你切好的那个块}</pre>
    <div class="box ex"><b class="hd">例子：块内容与返回</b>
      输入块：「小李在杭州的茶百道工作，负责新茶饮研发。」<br><br>
      LLM 返回：<br>
      <code>("entity" &lt;|&gt; "小李" &lt;|&gt; "person" &lt;|&gt; "小李是茶百道的研发人员")</code> <br>
      <code>("entity" &lt;|&gt; "茶百道" &lt;|&gt; "organization" &lt;|&gt; "茶百道是小李就职的公司")</code> <br>
      <code>("entity" &lt;|&gt; "杭州" &lt;|&gt; "geo" &lt;|&gt; "杭州是小李工作的城市")</code> <br>
      <code>("relationship" &lt;|&gt; "小李" &lt;|&gt; "茶百道" &lt;|&gt; "小李就职于茶百道" &lt;|&gt; 8)</code></div>
    <div class="box an"><b class="hd">为什么不用 JSON？用这套奇怪的 &lt;|&gt; 分隔符？</b>
      JSON 对"手写"它很不友好：模型写到一半被截断，或漏一个逗号，整个结构就废了，只能整段丢弃。<br>
      而这种<strong>分隔符协议</strong>非常皮实：<code>##</code> 切成一条条记录，<code>&lt;|&gt;</code> 切开一条记录的字段——<strong>某一条坏了只丢那一条</strong>，解析用一个正则就够。对能力较弱的开源模型尤其友好。</div>
    <h4 id="gleaning追问还有漏的吗">Gleaning：追问"还有漏的吗？"</h4>
    <p>第一次抽取后，系统会再发一句 <em>"MANY entities were missed in the last extraction. Add them below…"</em>（上次漏了很多，补上），让模型补充；再问一句"还有吗？YES/NO"决定是否继续。这叫 <strong>gleaning（打谷扬场式的复查）</strong>，就像写完作文后再检查一遍错别字。<code>entity_extract_max_gleaning</code> 控制最多复查几轮（默认 1 轮）。</p>
    <div class="box kp"><b class="hd">本课要点</b>
      抽取 = LLM 按固定格式吐出实体/关系记录；分隔符协议比 JSON 抗造；gleaning 是复查补漏；此步并发执行、由 best_model（较强的模型）承担。</div>
  </div>
</section>
<section class="lesson" id="l11">
  <div class="lhead"><div class="lno">11</div><h3 id="第三步合并成一张图">第三步：合并成一张图</h3><span class="ldiff">基础</span></div>
  <div class="lbody">
    <h4 id="做什么-21">做什么</h4>
    <p>每个块各自抽出了实体，现在要把全库结果<strong>汇成一张图</strong>。核心问题是：<strong>10 个块都提到了"茶百道"，图里应该有 10 个节点还是 1 个？</strong>——1 个。同名实体合并为同一节点。</p>
    <h4 id="合并时三个字段怎么处理">合并时三个字段怎么处理</h4>
    <table>
      <tr><th>字段</th><th>合并策略</th><th>为什么这么设计</th></tr>
      <tr><td>类型 entity_type</td><td><strong>投票</strong>：谁票多算谁<br>（5 次说 organization，1 次说 company → 取 organization）</td><td>不同块对同一实体的判断可能不一致，众数最稳</td></tr>
      <tr><td>描述 description</td><td><strong>去重后字典序拼接</strong>，用 <code>&lt;SEP&gt;</code> 连起来</td><td>每块贡献的信息都要保留，字典序保证结果确定</td></tr>
      <tr><td>来源 source_id</td><td>并集拼接：记录"这个节点被哪些块提到"</td><td>后面查询时靠它反查原文（第 14 课会用到）</td></tr>
    </table>
    <div class="box wa"><b class="hd">描述无限膨胀怎么办？</b>
      「茶百道」被 200 个块提到，描述拼起来可能几千 token。系统设了阈值（默认 500 token）：<strong>超过就把全部描述丢给便宜的模型（cheap_model）压成一段摘要</strong>，再存回去。注意分工——合并摘要这种"体力活"用便宜模型，抽取报告这种"技术活"用贵模型，省钱的关键就在这。</div>
    <p>边（关系）合并同理，两点差异：</p>
    <ul>
      <li><strong>权重累加</strong>：两个实体在不同块里反复共同出现 → weight 相加，说明关系越铁</li>
      <li><strong>图是无向的</strong>：(A,B) 和 (B,A) 是同一条边，聚合前统一按字母序排好</li>
    </ul>
    <p>合并完成后，每个实体（名称＋描述）会被<strong>向量化存进实体向量库</strong>——这就是第 6 课流程里的最后一步⑥，local 查询正是靠它找回相关实体的。</p>
    <div class="box ex"><b class="hd">例子走完后的图</b>
      文档 A+B 都处理完，图里是：<br>
      [小李] —就职于(8)→ [茶百道] —成立于(?)→ [成都]，[茶百道] 旁边挂"总部：成都"，[小李] 旁边挂"工作地：杭州"。<br>
      <strong>跨文档的链条已经连上了</strong>——这正是第 4 课病历里"链条断裂"的治愈现场。</div>
    <p class="mini"><span class="fileref">_op.py:182 _merge_nodes_then_upsert</span> · <span class="fileref">_op.py:230 _merge_edges_then_upsert</span> · <span class="fileref">_op.py:111 描述超长摘要</span></p>
  </div>
</section>
<section class="lesson" id="l12">
  <div class="lhead"><div class="lno">12</div><h3 id="第四步社区给图分组">第四步：社区——给图分组</h3><span class="ldiff">进阶</span></div>
  <div class="lbody">
    <h4 id="做什么-24">做什么</h4>
    <p>图建好后，可能有成千上万个节点。把<strong>互相连接紧密的一簇节点</strong>划成一组，一个组就叫一个<strong>社区（community）</strong>。这一步由聚类算法完成，nano-graphrag 用的是 <strong>Leiden 算法</strong>。</p>
    <div class="box an"><b class="hd">类比：社交圈</b>
      你的微信好友几千人，但自然分成一个个圈子：大学室友圈、公司同事圈、家人圈。<strong>圈子内部联系密，圈子之间联系疏</strong>——这正是社区发现算法在图上做的事。Leiden 就是"自动画圈"的算法，且质量高、速度快（它也是微软 GraphRAG 用的算法，保持了方法论一致）。</div>
    <h4 id="为什么要层级">为什么要"层级"？</h4>
    <p>圈子可以套圈子：「茶百道-研发圈」内部又分「小李-小王-小张」小组。Leiden 输出的就是<strong>多层</strong>结果（level 0、1、2……）：<strong>层数字越小圈越大</strong>（level 0 ≈ 全公司大部门，level 2 ≈ 项目小组）。同一节点可以同时属于多个层的社区。</p>
    <pre>level 0:  [====== 一个大社区（100 人）======]
level 1:     [== 社区A（30人）==]   [== 社区B（40人）==]
level 2:        [小组A1] [小组A2]      [小组B1] [小组B2]
代码里每个节点存一份归属记录：
"clusters": [{"level":0,"cluster":5}, {"level":1,"cluster":12}, ...]</pre>
    <h4 id="occurrence出现度是什么">occurrence（出现度）是什么？</h4>
    <p>每个社区会算一个 0~1 的值：<strong>该社区覆盖的文本块数 ÷ 全库最大社区的文本块数</strong>。直觉上，<strong>覆盖原文越多的社区，越"有料"</strong>——后面查询排序时会用到它。</p>
    <div class="box kp"><b class="hd">本课要点</b>
      社区 = 图上的"圈子"；Leiden 自动画圈；圈分层级（大圈套小圈）；occurrence 衡量圈子覆盖了多少原文。为什么要画圈？——为了下一课<strong>给每个圈子写一份报告</strong>，这是解决"全局失明"的关键。</div>
    <p class="mini"><span class="fileref">_storage/gdb_networkx.py:230 _leiden_clustering</span> · <span class="fileref">_storage/gdb_networkx.py:170 community_schema</span></p>
  </div>
</section>
<section class="lesson" id="l13">
  <div class="lhead"><div class="lno">13</div><h3 id="第五步给社区写报告">第五步：给社区写报告</h3><span class="ldiff">进阶</span></div>
  <div class="lbody">
    <h4 id="做什么--为什么">做什么 & 为什么</h4>
    <p>对每个社区，把它内部的实体、关系打包，让 LLM 写一份<strong>结构化摘要报告</strong>。这一步是在为"全局问题"预存答案：</p>
    <div class="box an"><b class="hd">类比：公司的年报</b>
      老板不可能亲自读完全公司 1 万封邮件（=全局问题没法靠翻碎片解决）。于是每个部门写一份<strong>部门年报</strong>，老板只读几十份年报就掌握全局。社区报告就是"部门年报"，<strong>写年报的成本花在建索引时，查询时免费复用</strong>。</div>
    <h4 id="报告里有什么">报告里有什么</h4>
    <p>LLM 被要求返回一个 JSON（提示词在 <code>prompt.py</code> 的 <code>community_report</code>）：</p>
    <pre>{
  <span class="c">"title"</span>: <span class="s">"茶百道研发与成都总部社区"</span>,
  <span class="c">"summary"</span>: <span class="s">"该社区围绕茶百道展开，包含其成都总部、杭州研发中心及人员……"</span>,
  <span class="c">"rating"</span>: <span class="n">6.5</span>,                    <span class="cm">// 0~10 分：这个圈子的重要程度</span>
  <span class="c">"rating_explanation"</span>: <span class="s">"涉及核心业务实体，影响中等偏上"</span>,
  <span class="c">"findings"</span>: [                       <span class="cm">// 5~10 条要点，每条=标题+展开</span>
    {<span class="c">"summary"</span>:<span class="s">"茶百道的双城布局"</span>, <span class="c">"explanation"</span>:<span class="s">"成都总部与杭州研发……"</span>},
    ...
  ]
}</pre>
    <p>报告会存成<strong>两份</strong>：JSON（保留 rating 等结构化字段，供排序过滤用）和 Markdown 文本（供直接阅读/拼进提示词）。</p>
    <h4 id="怎么保证不超模型窗口打包预算">怎么保证不超模型窗口：打包预算</h4>
    <p>一个社区可能有几百个节点，全塞进提示词会爆窗口。系统有一套打包策略（<code>_pack_single_community_describe</code>）：</p>
    <div class="flow">
      <div class="fbox f4">① 大社区优先用子报告<small>圈太大时，直接引用已写好的子社区报告摘要</small></div>
      <div class="arr">→</div>
      <div class="fbox f3">② 按重要性排序<small>节点按度数（朋友数）排，
      关系按两端度数和排——重要的排前面</small></div>
      <div class="arr">→</div>
      <div class="fbox f1">③ 按 token 预算截断<small>剩下的空间按比例分给
      实体表和关系表，装不下的丢掉</small></div>
    </div>
    <div class="box an"><b class="hd">"排序后截断"这个技巧后面到处都是</b>
      先把最重要的排到前面，再"从头开始装，装满为止"——<strong>被丢掉的永远是最不重要的尾部</strong>。这是整个项目治理上下文长度的核心手法，第 17 课会再总结。</div>
    <div class="box wa"><b class="hd">成本提醒</b>
      写报告用的是 best_model（贵模型），且每次 insert 会重建全部报告。不过第 18 课会讲到有"LLM 缓存"兜底：内容没变的报告第二次不会重复计费。建议：先小语料试跑，算清账再上量。</div>
    <p class="mini"><span class="fileref">_op.py:625 generate_community_report</span> · <span class="fileref">_op.py:464 打包预算逻辑</span></p>
  </div>
</section>
<!-- ==================== 第四部分 ==================== -->
<div class="part">
  <div class="pno">Part 4</div>
  <h2 id="查询流程逐步拆解">查询流程逐步拆解</h2>
  <p>insert 之后知识就备好了。这一部分回答：三种模式各自怎么把问题变成答案？</p>
</div>
<section class="lesson" id="l14">
  <div class="lhead"><div class="lno">14</div><h3 id="local刨根问底式提问">local：刨根问底式提问</h3><span class="ldiff">基础</span></div>
  <div class="lbody">
    <h4 id="它怎么回答小李的公司成立于哪一年">它怎么回答"小李的公司成立于哪一年？"</h4>
    <p>五步走，全部发生在 <code>_build_local_query_context</code> 里：</p>
    <div class="flow" style="flex-direction:column">
      <div class="fbox f1">① 用问题去实体向量库检索 → 找回最相关的 20 个实体<small>「小李」「茶百道」…被召回，同时拿到每个节点的度数（朋友数）</small></div>
      <div class="arr">↓</div>
      <div class="fbox f4">② 顺着图扩展，收集三类证据<small>· 相关社区的报告 · 这些实体之间的边 · 它们提到过的原文分块</small></div>
      <div class="arr">↓</div>
      <div class="fbox f3">③ 各类证据按重要性排序 + 按 token 预算截断<small>报告：命中次数多的优先；边：度数和大的优先；原文：被多方共同佐证的优先</small></div>
      <div class="arr">↓</div>
      <div class="fbox f5">④ 拼成 4 段 CSV，塞进系统提示词<small>-----Reports----- / -----Entities----- / -----Relationships----- / -----Sources-----</small></div>
      <div class="arr">↓</div>
      <div class="fbox f2">⑤ LLM 读着上下文作答<small>回答被约束"不许编造，只依据提供的资料"</small></div>
    </div>
    <div class="box ex"><b class="hd">例子：链条怎么接上的</b>
      ①向量召回「小李」「茶百道」 → ②图上看到 小李—就职于→茶百道，且茶百道节点挂的 source_id 指向文档 B 的分块 → ③文档 B 原文「成立于2008年」进入 Sources 表 → ⑤模型答：<strong>2008 年</strong>。<br><br>
      注意第②步：召回的实体可能只在文档 A 出现，但<strong>顺着一条边就把文档 B 拽出来了</strong>——这就是"沿图扩展"对第 4 课病历①的治愈。</div>
    <div class="box sn"><b class="hd">三个证据来源的排序诀窍（记住直觉即可）</b>
      <ul style="margin:6px 0 0">
        <li><strong>报告</strong>：被越多召回实体指向的社区越相关，评分高的优先</li>
        <li><strong>边</strong>：两端都是"社交达人"（度数高）且 weight 大的边更重要</li>
        <li><strong>原文</strong>：不只看"是不是召回实体写的"，还看"有多少邻居共同提到它"——被多方佐证的原文更可信</li>
      </ul></div>
    <p class="mini"><span class="fileref">_op.py:844 _build_local_query_context</span> · <span class="fileref">_op.py:935 local_query</span></p>
    <div class="box kp"><b class="hd">本课要点</b>
      local = 向量找实体 → 沿图扩边/报告/原文 → 排序截断拼 CSV → LLM 作答。四路证据各有一种"重要性"排序，都受 token 预算约束。</div>
  </div>
</section>
<section class="lesson" id="l15">
  <div class="lhead"><div class="lno">15</div><h3 id="global我要的是全局">global：我要的是全局</h3><span class="ldiff">进阶</span></div>
  <div class="lbody">
    <h4 id="它完全不走实体向量只读年报">它完全不走实体向量，只读"年报"</h4>
    <p>问「这批文档里的公司整体发展如何？」——没有任何单个实体能回答这个问题。global 的策略是把第 13 课写好的<strong>所有社区报告</strong>拿来，走一轮 <span class="term" title="Map-Reduce：先分头处理（Map），再汇总结果（Reduce）">Map-Reduce</span>：</p>
    <div class="flow" style="flex-direction:column">
      <div class="fbox f4">① 筛选：挑出要读的报告<small>层级 ≤ level、按 occurrence 排序取前 512 个、评分低于阈值的丢掉</small></div>
      <div class="arr">↓</div>
      <div class="fbox f3">② Map：报告按 token 预算分成若干组，每组一次 LLM 调用<small>每组像一位"分析师"，产出带 0~100 重要性评分的要点列表</small></div>
      <div class="arr">↓</div>
      <div class="fbox f1">③ 汇总所有要点：过滤 0 分，按分数从高到低，按预算截断<small>留下的都是各组认为最重要的</small></div>
      <div class="arr">↓</div>
      <div class="fbox f2">④ Reduce：最后一次 LLM 调用，把要点融成最终回答<small>"分析师报告已按重要性排序，请综合成一段回答"</small></div>
    </div>
    <div class="box an"><b class="hd">类比：开总结大会</b>
      报告太多，老板一个人读不完 → <strong>分组</strong>：每人发一摞报告，各自提炼 10 条要点并打分（=Map）→ 把所有人交上来的要点汇总、按分数排序（=汇总）→ 最后一个人把精华写成总报告（=Reduce）。<br>注意：<strong>分组时发出去的是一摞报告</strong>，它能装下更多 token——分组本身就是控制长度的手段。</div>
    <p>对比 local，二者的分工非常清晰：</p>
    <table>
      <tr><th></th><th>local</th><th>global</th></tr>
      <tr><td>读什么</td><td>实体 + 边 + 原文 + 少量报告</td><td><strong>只读社区报告</strong></td></tr>
      <tr><td>LLM 调用</td><td>1 次</td><td>分组数 + 1 次</td></tr>
      <tr><td>擅长</td><td>"X 的 Y 是多少"（细节、多跳）</td><td>"整体怎么样"（归纳、主题）</td></tr>
    </table>
    <p class="mini"><span class="fileref">_op.py:1017 global_query</span> · <span class="fileref">_op.py:970 _map_global_communities</span></p>
  </div>
</section>
<section class="lesson" id="l16">
  <div class="lhead"><div class="lno">16</div><h3 id="l16">naive：不看图直接翻书</h3><span class="ldiff">入门</span></div>
  <div class="lbody">
    <p>最简单的一个模式，四步：</p>
    <div class="flow">
      <div class="fbox f1">问题向量化<small>去<strong>分块</strong>向量库检索</small></div>
      <div class="arr">→</div>
      <div class="fbox f2">取回 top-k 分块原文<small>按 token 预算截断</small></div>
      <div class="arr">→</div>
      <div class="fbox f3">拼进朴素提示词<small>“以下是已知信息……”</small></div>
      <div class="arr">→</div>
      <div class="fbox f4">LLM 回答<small>等于普通 RAG</small></div>
    </div>
    <p>它与 local 的区别只有一个开关：<code>enable_naive_rag=True</code> 时才会额外建一个<strong>分块向量库</strong>（local 用的是<strong>实体向量库</strong>，两者是不同的库）。</p>
    <div class="box kp"><b class="hd">本课要点 · 第四部分收尾</b>
      local 沿图查细节（1 次 LLM）、global 读报告做归纳（多次 LLM）、naive 翻原文当基线。<strong>选模式的口诀：问具体的人和事用 local，问整体用 global，做对比实验用 naive。</strong></div>
  </div>
</section>
<!-- ==================== 第五部分 ==================== -->
<div class="part">
  <div class="pno">Part 5</div>
  <h2 id="底层支撑机制">底层支撑机制</h2>
  <p>前几课反复出现的几个"配角"——token 预算、缓存、限流、存储接口——单独拎出来讲透。懂了这四课，你就理解了这个项目 80% 的代码细节。</p>
</div>
<section class="lesson" id="l17">
  <div class="lhead"><div class="lno">17</div><h3 id="l17">token 与预算：为什么到处截断</h3><span class="ldiff">基础</span></div>
  <div class="lbody">
    <h4 id="l17-39">先说 token</h4>
    <p><strong>token</strong> 是 LLM 的"字数单位"：模型有上下文窗口上限（如 128k token），API 按 token 计费。项目里所有"1200"、"500"、"16384"之类的数字都是 token 数。项目用一个叫 <code>TokenizerWrapper</code> 的工具把文字数成 token（底层是 tiktoken），<strong>全项目数 token 只走这一个口</strong>，换成别的分词器也不影响别处。</p>
    <h4 id="l17-40">核心矛盾</h4>
    <div class="box wa"><b class="hd">想给模型的 vs 模型装得下的</b>
      想给：全部相关实体、全部边、全部报告、全部原文……<br>
      装得下：固定的上下文窗口。<br>
      解法只有一个：<strong>排序 + 截断</strong>——先把重要的排前面，再按预算从头装。</div>
    <h4 id="l17-41">全项目的统一工具：truncate_list_by_token_size</h4>
    <pre><span class="k">def</span> truncate_list_by_token_size(list_data, key, max_token_size, tokenizer):
    tokens = <span class="n">0</span>
    <span class="k">for</span> i, data <span class="k">in</span> enumerate(list_data):        <span class="cm"># 按顺序累加</span>
        tokens += len(tokenizer.encode(key(data))) + <span class="n">1</span>
        <span class="k">if</span> tokens > max_token_size:
            <span class="k">return</span> list_data[:i]                  <span class="cm"># 装满就停，返回前缀</span>
    <span class="k">return</span> list_data</pre>
    <p>它在源码里出现了十余处（`_op.py` 中 10 处调用），每次调用前<strong>列表都已经排好序</strong>，所以"返回前缀"＝"保留最重要的"。这就是前面各课反复看到的"预算 4000 tokens""按评分截断"背后的同一行代码。</p>
    <div class="box sn"><b class="hd">预算从哪来？</b>
      写入侧：预算 = 模型窗口 − 提示词模板开销（<code>best_model_max_token_size</code> 减去模板长度）。<br>
      查询侧：预算写死在 <code>QueryParam</code> 里（local 三路 4000+4800+3200，global 16384），你可以按自己模型的窗口改这几个数。</div>
    <div class="box kp"><b class="hd">本课要点</b>
      token 是窗口与计费单位；窗口有限所以必须截断；截断前必须排序；排序+截断由 <code>truncate_list_by_token_size</code> 一处实现，全局复用。</div>
  </div>
</section>
<section class="lesson" id="l18">
  <div class="lhead"><div class="lno">18</div><h3 id="l18">调用 LLM 的三件保险</h3><span class="ldiff">基础</span></div>
  <div class="lbody">
    <p>LLM API 会限流、会抖动、会重复计费。<code>_llm.py</code> 给每次调用上了三道保险：</p>
    <h4 id="l18-43">保险一 · 重试（摔倒了爬起来）</h4>
    <p>遇到限流错误（RateLimitError）或连接错误时，<strong>最多再试 5 次，间隔 4→10 秒指数变长</strong>。用的是 <code>tenacity</code> 库的 <code>@retry</code> 装饰器，套在每个调用函数外面，调用方无感知。</p>
    <h4 id="l18-44">保险二 · 缓存（同一道题不答两次）</h4>
    <div class="box ex"><b class="hd">工作方式</b>
      ① 把「模型名 + 完整的消息列表」做 MD5，得到一个指纹；<br>
      ② 先查缓存：这个指纹见过吗？<strong>见过 → 直接返回上次的答案，一分钱不花</strong>；<br>
      ③ 没见过 → 调 API → 把答案连同指纹存进 <code>kv_store_llm_response_cache.json</code>，并立刻落盘。<br><br>
      实际效果：重建社区报告时，只要社区内容没变，提示词就一样，<strong>第二次全部命中缓存</strong>。中途失败重跑 insert，也不用为已完成的部分再付一次钱。</div>
    <p class="mini"><span class="fileref">_llm.py:50 openai_complete_if_cache</span> · <span class="fileref">_utils.py:220 compute_args_hash</span></p>
    <h4 id="l18-45">保险三 · 限流（进闸门先排队）</h4>
    <p>抽取几百个块时会同时发几百个请求，API 必然报错。系统给每个 LLM/Embedding 函数外面套了一层<strong>并发闸门</strong>（<code>limit_async_func_call</code>）：同时最多 16 个在飞（可配），第 17 个请求必须等前面有人完成才放行。</p>
    <div class="box an"><b class="hd">类比：景区闸机</b>
      闸机同时只放 16 人，第 17 人在黄线外等——只是排队，不算拒绝。这样把"同时几百个请求"变成"稳定的每秒十几个请求"，限流错误自然就少了。</div>
    <p class="mini"><span class="fileref">_utils.py:276 limit_async_func_call</span></p>
    <div class="box kp"><b class="hd">本课要点</b>
      重试治"网络抖动"，缓存治"重复花钱"，限流治"并发过猛"。三道保险让大规模文档的抽取既稳又省。</div>
  </div>
</section>
<section class="lesson" id="l19">
  <div class="lhead"><div class="lno">19</div><h3 id="l19">三类存储与"可插拔"</h3><span class="ldiff">基础</span></div>
  <div class="lbody">
    <h4 id="l19-47">系统里的数据其实分三种形态</h4>
    <table>
      <tr><th>形态</th><th>例子</th><th>对应接口</th><th>默认实现</th></tr>
      <tr>
        <td><strong>键值对</strong><br><span class="mini">id → 记录</span></td>
        <td>文档、分块、LLM 缓存、社区报告</td>
        <td><code>BaseKVStorage</code></td>
        <td>JsonKVStorage<br><span class="mini">一个 JSON 文件</span></td>
      </tr>
      <tr>
        <td><strong>向量</strong><br><span class="mini">文字 → 坐标</span></td>
        <td>实体库（local 用）、分块库（naive 用）</td>
        <td><code>BaseVectorStorage</code></td>
        <td>NanoVectorDBStorage<br><span class="mini">JSON + 暴力算距离</span></td>
      </tr>
      <tr>
        <td><strong>图</strong><br><span class="mini">节点 + 边</span></td>
        <td>实体关系图 + 社区归属</td>
        <td><code>BaseGraphStorage</code></td>
        <td>NetworkXStorage<br><span class="mini">内存图 → graphml 文件</span></td>
      </tr>
    </table>
    <h4 id="l19-48">"可插拔"是怎么实现的？</h4>
    <p><code>base.py</code> 只定义<strong>接口</strong>（一堆 <code>raise NotImplementedError</code> 的方法声明），不关心后面是谁。具体实现放在 <code>_storage/</code> 里。想换零件？改一个字段：</p>
    <pre><span class="k">from</span> nano_graphrag._storage.gdb_neo4j <span class="k">import</span> Neo4jStorage
graph = GraphRAG(
    graph_storage_cls=Neo4jStorage,          <span class="cm"># 图存储从 NetworkX 换成 Neo4j，就这一行</span>
    vector_db_storage_cls=HNSWVectorStorage, <span class="cm"># 向量库同理</span>
)</pre>
    <div class="box an"><b class="hd">类比：换电池</b>
      接口像"5 号电池仓"：仓的规格（正负极、直径）是固定的，电池品牌随便换。GraphRAG 主流程只认"仓"，不知道里面装的是谁——所以它才敢在 <code>__post_init__</code> 里写 <code>self.graph_storage_cls(...)</code> 也不关心具体类。</div>
    <h4 id="l19-49">还有个容易忽略的设计：统一的落盘时机</h4>
    <p>所有存储都继承同一个基类，带三个钩子函数：<code>index_start_callback</code>（开始写入前调用）、<code>index_done_callback</code>（全部写完后调用）。默认实现是"整个 insert 过程都在内存里改，<strong>最后一次性把 JSON/graphml/向量库写到磁盘</strong>"——避免写一半崩了留下脏数据。</p>
    <p class="mini"><span class="fileref">base.py:59-186 接口定义</span> · <span class="fileref">graphrag.py:360 _insert_done 统一落盘</span></p>
    <div class="box kp"><b class="hd">本课要点</b>
      三类数据 → 三个接口 → 各自的实现类；换后端只改一个字段；改数据和写磁盘分离，结束时统一提交。这就是"小而可扩展"的实现方式。</div>
  </div>
</section>
<section class="lesson" id="l20">
  <div class="lhead"><div class="lno">20</div><h3 id="l20">动手路线与下一步</h3><span class="ldiff">实践</span></div>
  <div class="lbody">
    <h4 id="l20-51">建议的上手顺序（由浅入深，每步都有反馈）</h4>
    <div class="steps" style="margin:14px 0">
      <div class="box sn" style="margin:8px 0"><b class="hd">第 1 步 · 跑通最小例子（30 分钟）</b>
        装好依赖后，用 <code>examples/no_openai_key_at_all.py</code> 或接自己的 LLM（OpenAI/DeepSeek/Ollama 都行），对一段几百字文本执行一次 <code>insert</code> + 三种 <code>query</code>。目标：见到真实回答。</div>
      <div class="box sn" style="margin:8px 0"><b class="hd">第 2 步 · 打开工作目录看产物（20 分钟）</b>
        看 <code>working_dir</code> 下的 5 个文件：kv_store_*.json 里翻几条 chunk 和社区报告；graphml 文件用文本编辑器搜 <code>clusters</code>。把"第 6 课的 6 步流程"和磁盘文件对上号。</div>
      <div class="box sn" style="margin:8px 0"><b class="hd">第 3 步 · 打印中间上下文（30 分钟）</b>
         查询时加 <code>QueryParam(mode="local", only_need_context=True)</code>——直接输出检索到的 CSV 上下文，不经过 LLM。你会亲眼看到四路证据长什么样、排序截断的效果，这是理解检索质量最快的途径。返回的上下文形如：<pre style="margin:8px 0 0">-----Reports-----
id,	content
0,	# 茶百道公司与人员社区\\nThe community centers on…
-----Entities-----
id,	entity_type,	description
小李,	person,	小李是茶百道的研发人员
茶百道,	organization,	茶百道是一家 2008 年成立于成都的奶茶连锁品牌
-----Relationships-----
id,	source,	target,	description,	weight
1,	小李,	茶百道,	小李就职于茶百道,	8
-----Sources-----
id,	content
chunk-3f2a…,	小李在杭州的茶百道工作，负责新茶饮研发。</pre>
         四个段落的顺序和内容，就是 local 查询真正喂给 LLM 的"证据清单"——检索好不好，一眼看穿。</div>
      <div class="box sn" style="margin:8px 0"><b class="hd">第 4 步 · 改一个东西试试（1 小时）</b>
        任选其一：① 改 <code>prompt.py</code> 里的 <code>DEFAULT_ENTITY_TYPES</code>，让抽取适配你的领域（如法律/医疗）；② 调 QueryParam 里的预算数字；③ 把 chunk_token_size 从 1200 改成 600 观察差异。<strong>改完跑对比，才算真学会。</strong></div>
      <div class="box sn" style="margin:8px 0"><b class="hd">第 5 步 · 带着问题读源码</b>
        按第 8 课地图顺序：graphrag.py（ainsert 全流程）→ _op.py 的 extract_entities → 两个 merge → local_query → generate_community_report。每读一个函数，问自己"这一步在六步流程的第几步？"</div>
    </div>
    <h4 id="l20-52">可以继续学的概念（按性价比排序）</h4>
    <table>
      <tr><th>方向</th><th>要学什么</th><th>解决什么</th></tr>
      <tr><td>GraphRAG 方法论本身</td><td>微软 GraphRAG 原版论文（GraphRAG: From Local to Global）</td><td>nano 删掉的 covariates、原版 map-reduce 设计</td></tr>
      <tr><td>图算法</td><td>社区发现（Leiden/Louvain）、节点度数、连通分量</td><td>第 12 课背后的数学在做什么</td></tr>
      <tr><td>检索质量</td><td>召回率/精确率评测、rerank 重排</td><td>如何科学判断"检索得好不好"</td></tr>
      <tr><td>工程扩展</td><td>把 JsonKV/NanoVectorDB 换成 SQLite/Qdrant 等生产级存储</td><td>大规模语料下的性能与并发</td></tr>
      <tr><td>同系项目</td><td>LightRAG（HKUDS）、微软 GraphRAG 原版</td><td>对照阅读，理解不同取舍</td></tr>
    </table>
    <div class="box kp"><b class="hd">全教程一句话总结</b>
      nano-graphrag 做的事：<strong>用 LLM 把一堆文档读成一张"实体关系图"和一摞"社区报告"（insert），再沿图找线索、读报告答问题（query）</strong>——中间所有工程细节（MD5 去重、token 预算、缓存、限流、可插拔存储）都是为了让这个过程<strong>省钱、稳定、可换零件</strong>。</div>
  </div>
</section>
<!-- ==================== 附录 ==================== -->
<section class="lesson" id="gl">
  <div class="lhead"><div class="lno">词</div><h3 id="gl">附录 · 术语速查表</h3><span class="ldiff">随查随用</span></div>
  <div class="lbody">
    <table>
      <tr><th>术语</th><th>一句话解释</th><th>首见于</th></tr>
      <tr><td><strong>LLM</strong></td><td>大语言模型，如 GPT、Claude、DeepSeek、通义等</td><td>01</td></tr>
      <tr><td><strong>上下文窗口</strong></td><td>模型一次能"看见"的最大文字量</td><td>01</td></tr>
      <tr><td><strong>多跳推理</strong></td><td>需要连续串起 2+ 条线索才能得出的答案</td><td>01</td></tr>
      <tr><td><strong>RAG</strong></td><td>检索增强生成：先查资料再让模型作答</td><td>02</td></tr>
      <tr><td><strong>chunk（分块）</strong></td><td>被切出来的文字片段，检索的基本单位</td><td>02</td></tr>
      <tr><td><strong>embedding（向量化）</strong></td><td>把文字变成坐标，语义近则坐标近</td><td>03</td></tr>
      <tr><td><strong>向量库</strong></td><td>存坐标、按"谁离我最近"检索的数据库</td><td>03</td></tr>
      <tr><td><strong>余弦相似度</strong></td><td>衡量两个向量方向接近程度的指标，1 为最像</td><td>03</td></tr>
      <tr><td><strong>知识图谱</strong></td><td>节点=实体、边=关系的知识组织方式</td><td>05</td></tr>
      <tr><td><strong>GraphRAG</strong></td><td>先建知识图谱再检索回答的 RAG 范式</td><td>05</td></tr>
      <tr><td><strong>实体 / 关系</strong></td><td>图中的节点 / 连接节点的边</td><td>05</td></tr>
      <tr><td><strong>社区（community）</strong></td><td>图上互相连接紧密的一簇节点，即"圈子"</td><td>12</td></tr>
      <tr><td><strong>Leiden</strong></td><td>一种自动给图分圈的聚类算法，支持层级</td><td>12</td></tr>
      <tr><td><strong>层级（level）</strong></td><td>社区的嵌套深度，数字越小圈越大</td><td>12</td></tr>
      <tr><td><strong>occurrence</strong></td><td>社区覆盖的原文块占比，衡量"有料程度"</td><td>12</td></tr>
      <tr><td><strong>社区报告</strong></td><td>让 LLM 给每个社区写的摘要，含评分</td><td>13</td></tr>
      <tr><td><strong>Map-Reduce</strong></td><td>先分头处理再汇总的两阶段模式</td><td>15</td></tr>
      <tr><td><strong>token</strong></td><td>模型的计字/计费单位</td><td>17</td></tr>
      <tr><td><strong>预算截断</strong></td><td>排序后按 token 上限保留前缀的通用手法</td><td>17</td></tr>
      <tr><td><strong>LLM 缓存</strong></td><td>相同提问直接返回上次答案，避免重复计费</td><td>18</td></tr>
      <tr><td><strong>并发限流</strong></td><td>同时最多 N 个请求在飞，多的排队</td><td>18</td></tr>
      <tr><td><strong>可插拔</strong></td><td>定义接口+注入实现，换零件不动主流程</td><td>19</td></tr>
      <tr><td><strong>幂等 / 去重</strong></td><td>重复执行不产生副作用，靠内容 MD5 实现</td><td>09</td></tr>
      <tr><td><strong>gleaning</strong></td><td>抽取后再追问"还有漏的吗"的补漏机制</td><td>10</td></tr>
      <tr><td><strong>best/cheap 双模型</strong></td><td>重要任务用贵模型、体力活用便宜模型的分工</td><td>11</td></tr>
    </table>
  </div>
</section>
