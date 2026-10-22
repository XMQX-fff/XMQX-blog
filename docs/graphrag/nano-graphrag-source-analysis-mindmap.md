---
title: nano-graphrag 源码深度解析 · 思维脑图
description: nano-graphrag 源码解析手册的整页脑图：十二章的主题结构、每章关键机制与它们之间的关系。
outline: [2, 3]
aside: false
pageClass: mindmap-page
---

# nano-graphrag 源码深度解析 · 思维脑图

<p class="mini">一张图看完整本手册的结构 · 对应正文：<a href="/graphrag/nano-graphrag-source-analysis">源码深度解析（参考手册）</a></p>

<p class="mmap-hint">图比正文宽，可以左右拖动看全貌。</p>

<p class="mini">本页导览：<a href="#怎么看这张图">怎么看这张图</a> · <a href="#一句话架构">一句话架构</a> · <a href="#源码文件与章节对照">源码文件与章节对照</a> · <a href="#八根支柱">八根支柱</a> · <a href="#下一步">下一步</a></p>

<div class="mmap-wrap">
<div class="mmap">
  <div class="mmap-forest">
    <div class="mmap-branch mm-b1">
      <div class="mmap-part"><span class="mmap-pno">01–02</span>概览与架构</div>
      <div class="mmap-kids">
        <div class="mmap-node">
          <div class="mmap-box"><span class="mmap-no">01</span>项目概览与设计哲学</div>
          <ul class="mmap-leaves">
            <li>小而完整，约 2900 行</li>
            <li>全组件可插拔</li>
            <li>异步优先</li>
            <li>零外部服务依赖</li>
            <li>幂等增量写入</li>
            <li>预算感知</li>
          </ul>
        </div>
        <div class="mmap-node">
          <div class="mmap-box"><span class="mmap-no">02</span>整体架构</div>
          <ul class="mmap-leaves">
            <li>分层：应用 → 管线 → 抽象 → 实现</li>
            <li>两类存储 + 两条管线</li>
            <li>源码地图：9 个文件</li>
          </ul>
        </div>
      </div>
    </div>
    <div class="mmap-branch mm-b2">
      <div class="mmap-part"><span class="mmap-pno">03–04</span>骨架：主类与存储抽象</div>
      <div class="mmap-kids">
        <div class="mmap-node">
          <div class="mmap-box"><span class="mmap-no">03</span>主入口 GraphRAG 类</div>
          <ul class="mmap-leaves">
            <li>dataclass 兼当配置中心</li>
            <li>九组配置字段</li>
            <li>__post_init__ 完成装配</li>
            <li>同步 / 异步双接口</li>
          </ul>
        </div>
        <div class="mmap-node">
          <div class="mmap-box"><span class="mmap-no">04</span>存储抽象层 base.py</div>
          <ul class="mmap-leaves">
            <li>KV / Vector / Graph 三个基类</li>
            <li>生命周期回调统一落盘</li>
            <li>5 种默认与可替换实现</li>
          </ul>
        </div>
      </div>
    </div>
    <div class="mmap-branch mm-b3">
      <div class="mmap-part"><span class="mmap-pno">05</span>写入管线 Insert</div>
      <div class="mmap-kids">
        <div class="mmap-node">
          <div class="mmap-box"><span class="mmap-no">5.1</span>文本分块</div>
          <ul class="mmap-leaves">
            <li>滑动窗口硬切</li>
            <li>按分隔符切，落自然边界</li>
          </ul>
        </div>
        <div class="mmap-node">
          <div class="mmap-box"><span class="mmap-no">5.2</span>实体关系抽取</div>
          <ul class="mmap-leaves">
            <li>约定式文本协议</li>
            <li>gleaning 补抽循环</li>
            <li>全 chunk 并发 + 全局聚合</li>
            <li>记录级校验与命名归一</li>
          </ul>
        </div>
        <div class="mmap-node">
          <div class="mmap-box"><span class="mmap-no">5.3</span>合并与去重</div>
          <ul class="mmap-leaves">
            <li>节点：类型投票 + 描述拼接</li>
            <li>边：权重累加 + order 取 min</li>
            <li>超长描述交便宜模型压缩</li>
          </ul>
        </div>
        <div class="mmap-node">
          <div class="mmap-box"><span class="mmap-no">5.4</span>Leiden 社区聚类</div>
          <ul class="mmap-leaves">
            <li>稳定最大连通分量</li>
            <li>层级划分，clusters 回写节点</li>
            <li>community_schema 重建社区视图</li>
          </ul>
        </div>
        <div class="mmap-node">
          <div class="mmap-box"><span class="mmap-no">5.5</span>社区报告生成</div>
          <ul class="mmap-leaves">
            <li>层级从细到粗生成</li>
            <li>打包预算：子报告 / 排序 / 切分</li>
            <li>报告 Schema 与双份存储</li>
          </ul>
        </div>
      </div>
    </div>
    <div class="mmap-branch mm-b4">
      <div class="mmap-part"><span class="mmap-pno">06</span>查询管线 Query</div>
      <div class="mmap-kids">
        <div class="mmap-node">
          <div class="mmap-box"><span class="mmap-no">6.1</span>local：以实体为锚</div>
          <ul class="mmap-leaves">
            <li>向量召回 top-20 实体</li>
            <li>四路证据并行扩展</li>
            <li>三处排序智慧</li>
            <li>四段 CSV 注入提示词</li>
          </ul>
        </div>
        <div class="mmap-node">
          <div class="mmap-box"><span class="mmap-no">6.2</span>global：Map-Reduce</div>
          <ul class="mmap-leaves">
            <li>筛选社区：occurrence + rating</li>
            <li>Map 分组并行找要点</li>
            <li>要点聚合排序截断</li>
            <li>Reduce 合成最终回答</li>
          </ul>
        </div>
        <div class="mmap-node">
          <div class="mmap-box"><span class="mmap-no">6.3</span>naive：无图基线</div>
          <ul class="mmap-leaves">
            <li>分块向量检索 top-k</li>
            <li>量化建图带来的增益</li>
          </ul>
        </div>
        <div class="mmap-node">
          <div class="mmap-box"><span class="mmap-no">6.4</span>QueryParam 预算表</div>
          <ul class="mmap-leaves">
            <li>local 三路：4000 / 4800 / 3200</li>
            <li>global：512 社区 / 16384 token</li>
          </ul>
        </div>
      </div>
    </div>
    <div class="mmap-branch mm-b5">
      <div class="mmap-part"><span class="mmap-pno">07–10</span>支撑件与扩展</div>
      <div class="mmap-kids">
        <div class="mmap-node">
          <div class="mmap-box"><span class="mmap-no">07</span>LLM 调用层 _llm.py</div>
          <ul class="mmap-leaves">
            <li>统一函数签名</li>
            <li>内容哈希响应缓存</li>
            <li>指数退避重试与单例客户端</li>
          </ul>
        </div>
        <div class="mmap-node">
          <div class="mmap-box"><span class="mmap-no">08</span>工具库 _utils.py</div>
          <ul class="mmap-leaves">
            <li>TokenizerWrapper</li>
            <li>truncate_list_by_token_size</li>
            <li>MD5 主键与参数哈希</li>
            <li>自研并发限流</li>
            <li>JSON 容错解析</li>
            <li>CSV 渲染</li>
          </ul>
        </div>
        <div class="mmap-node">
          <div class="mmap-box"><span class="mmap-no">09</span>Prompt 工程 prompt.py</div>
          <ul class="mmap-leaves">
            <li>8 组 PROMPTS 集中管理</li>
            <li>grounding 规则反复强调</li>
            <li>分隔符常量贯穿全链路</li>
          </ul>
        </div>
        <div class="mmap-node">
          <div class="mmap-box"><span class="mmap-no">10</span>DSPy 扩展抽取器</div>
          <ul class="mmap-leaves">
            <li>默认：Prompt + 文本协议</li>
            <li>DSPy：Signature + 自反思</li>
          </ul>
        </div>
      </div>
    </div>
    <div class="mmap-branch mm-b6">
      <div class="mmap-part"><span class="mmap-pno">11–12</span>总结与阅读路线</div>
      <div class="mmap-kids">
        <div class="mmap-node">
          <div class="mmap-box"><span class="mmap-no">11</span>八个关键设计决策</div>
          <ul class="mmap-leaves">
            <li>dataclass 即架构</li>
            <li>三存储抽象</li>
            <li>内容寻址 MD5 主键</li>
            <li>双模型分工</li>
            <li>token 预算显式化</li>
            <li>文本协议优先于 JSON</li>
            <li>社区层级复用</li>
            <li>自研限流替代 Semaphore</li>
          </ul>
        </div>
        <div class="mmap-node">
          <div class="mmap-box"><span class="mmap-no">12</span>源码阅读路线图</div>
          <ul class="mmap-leaves">
            <li>90 分钟六段路径</li>
            <li>已知局限五条</li>
          </ul>
        </div>
      </div>
    </div>
  </div>
</div>
</div>

## 怎么看这张图

横向从左到右分三层：**章段 → 小节 → 要点**。每根竖线是同一层的分叉总线，最左边那根总线把各章段串在一起。图比正文列宽，可以左右拖动。

## 一句话架构

第 02 章把整个系统压缩成一句话：**三类存储 + 两条管线**。

- 写入管线：文档 → 分块 → 抽取 → 合并 → 聚类 → 社区报告
- 查询管线：问题 → 向量召回 → 图扩展 → 社区报告 → LLM 合成

脑图里 03~06 这四根枝就是这两条管线的代码落点，07~10 是横切在两条线上的支撑件。

## 源码文件与章节对照

想按文件读源码时，用这张表定位到对应章节。

| 文件 | 行数 | 讲它的章节 |
| --- | --- | --- |
| `graphrag.py` | 382 | 03 主入口 · 05 写入编排 |
| `base.py` | 186 | 04 存储抽象层 |
| `_op.py` | 1140 | 05 写入管线 · 06 查询管线 |
| `_llm.py` | 294 | 07 LLM 调用层 |
| `_utils.py` | 305 | 08 工具库 |
| `prompt.py` | 520 | 09 Prompt 工程 |
| `_splitter.py` | 94 | 05.1 文本分块 |
| `_storage/` | ~1000 | 04 默认与可替换实现 |
| `entity_extraction/` | ~500 | 10 DSPy 扩展抽取器 |

## 八根支柱

第 11 章的八个设计决策，是这本手册真正的骨架，其余章节都是它们的展开。

| 支柱 | 解决的问题 |
| --- | --- |
| dataclass 即架构 | 配置、依赖注入、默认值三合一 |
| 三存储抽象 | 数据形态与接口严格对应 |
| 内容寻址（MD5 主键） | 去重、增量、幂等三合一 |
| 双模型分工 | 贵模型做理解，便宜模型做压缩 |
| token 预算显式化 | 每个组装点都有硬预算 |
| 文本协议优先于 JSON | 抗截断，对弱模型宽容 |
| 社区层级复用 | 同一层级结构服务索引与检索两端 |
| 自研限流替代 Semaphore | 换取事件循环兼容性 |

## 下一步

- 读正文：[源码深度解析（参考手册）](/graphrag/nano-graphrag-source-analysis)
- 看另一张图：[从入门到理解 · 思维脑图](/graphrag/nano-graphrag-tutorial-mindmap)
- 读原理：[从入门到理解（初学者教程）](/graphrag/nano-graphrag-tutorial)
