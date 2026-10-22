---
title: nano-graphrag 从入门到理解 · 思维脑图
description: nano-graphrag 初学者教程的整页脑图：五篇二十讲的主题结构、每讲要点与它们之间的关系。
outline: [2, 3]
aside: false
pageClass: mindmap-page
---

# nano-graphrag 从入门到理解 · 思维脑图

<p class="mini">一张图看完整篇教程的结构 · 对应正文：<a href="/graphrag/nano-graphrag-tutorial">从入门到理解（初学者教程）</a></p>

<p class="mmap-hint">图比正文宽，可以左右拖动看全貌。</p>

<p class="mini">本页导览：<a href="#怎么看这张图">怎么看这张图</a> · <a href="#两条主线">两条主线</a> · <a href="#三个短板与解法">三个短板与解法</a> · <a href="#选模式的口诀">选模式的口诀</a> · <a href="#下一步">下一步</a></p>

<div class="mmap-wrap">
<div class="mmap">
  <div class="mmap-forest">
    <div class="mmap-branch mm-b1">
      <div class="mmap-part"><span class="mmap-pno">Part 1</span>为什么需要 nano-graphrag</div>
      <div class="mmap-kids">
        <div class="mmap-node">
          <div class="mmap-box"><span class="mmap-no">01</span>大模型回答不了的两个问题</div>
          <ul class="mmap-leaves">
            <li>资料太长，塞不进上下文窗口</li>
            <li>问题要「串起来」看（多跳推理）</li>
          </ul>
        </div>
        <div class="mmap-node">
          <div class="mmap-box"><span class="mmap-no">02</span>检索增强生成（RAG）</div>
          <ul class="mmap-leaves">
            <li>开卷考试：先翻书，再作答</li>
            <li>切块 + 检索 + 生成</li>
          </ul>
        </div>
        <div class="mmap-node">
          <div class="mmap-box"><span class="mmap-no">03</span>向量检索</div>
          <ul class="mmap-leaves">
            <li>embedding 把文字变成坐标</li>
            <li>向量库按「谁离我最近」取 top-k</li>
          </ul>
        </div>
        <div class="mmap-node">
          <div class="mmap-box"><span class="mmap-no">04</span>传统 RAG 的三个短板</div>
          <ul class="mmap-leaves">
            <li>链条断裂</li>
            <li>全局失明</li>
            <li>信息孤岛</li>
          </ul>
        </div>
        <div class="mmap-node">
          <div class="mmap-box"><span class="mmap-no">05</span>知识图谱与 GraphRAG 思路</div>
          <ul class="mmap-leaves">
            <li>节点=实体，边=关系</li>
            <li>建索引 + 写报告 + 查询</li>
          </ul>
        </div>
      </div>
    </div>
    <div class="mmap-branch mm-b2">
      <div class="mmap-part"><span class="mmap-pno">Part 2</span>先看全景：一次写入、一次查询</div>
      <div class="mmap-kids">
        <div class="mmap-node">
          <div class="mmap-box"><span class="mmap-no">06</span>insert：把文章变成知识</div>
          <ul class="mmap-leaves">
            <li>切块→抽取→合并→分组→报告→索引</li>
            <li>磁盘上留下 5 个产物文件</li>
          </ul>
        </div>
        <div class="mmap-node">
          <div class="mmap-box"><span class="mmap-no">07</span>query：三种提问方式</div>
          <ul class="mmap-leaves">
            <li>local 问细节</li>
            <li>global 问全局</li>
            <li>naive 翻原文，当对照组</li>
          </ul>
        </div>
        <div class="mmap-node">
          <div class="mmap-box"><span class="mmap-no">08</span>项目文件地图</div>
          <ul class="mmap-leaves">
            <li>graphrag.py 指挥</li>
            <li>_op.py 干活</li>
            <li>_storage/ 存东西</li>
          </ul>
        </div>
      </div>
    </div>
    <div class="mmap-branch mm-b3">
      <div class="mmap-part"><span class="mmap-pno">Part 3</span>写入流程逐步拆解</div>
      <div class="mmap-kids">
        <div class="mmap-node">
          <div class="mmap-box"><span class="mmap-no">09</span>切块与去重</div>
          <ul class="mmap-leaves">
            <li>1200 token 滑窗，重叠 100</li>
            <li>MD5 内容寻址，幂等去重</li>
          </ul>
        </div>
        <div class="mmap-node">
          <div class="mmap-box"><span class="mmap-no">10</span>让 LLM 圈出实体</div>
          <ul class="mmap-leaves">
            <li>&lt;|&gt; 分隔符协议，抗截断</li>
            <li>gleaning 追问「还有漏的吗」</li>
          </ul>
        </div>
        <div class="mmap-node">
          <div class="mmap-box"><span class="mmap-no">11</span>合并成一张图</div>
          <ul class="mmap-leaves">
            <li>类型投票，描述去重拼接</li>
            <li>边的权重累加，图是无向的</li>
          </ul>
        </div>
        <div class="mmap-node">
          <div class="mmap-box"><span class="mmap-no">12</span>社区：给图分组</div>
          <ul class="mmap-leaves">
            <li>Leiden 算法，圈层套圈层</li>
            <li>occurrence 衡量覆盖了多少原文</li>
          </ul>
        </div>
        <div class="mmap-node">
          <div class="mmap-box"><span class="mmap-no">13</span>给社区写报告</div>
          <ul class="mmap-leaves">
            <li>JSON + Markdown 两份</li>
            <li>打包预算：排序后截断</li>
          </ul>
        </div>
      </div>
    </div>
    <div class="mmap-branch mm-b4">
      <div class="mmap-part"><span class="mmap-pno">Part 4</span>查询流程逐步拆解</div>
      <div class="mmap-kids">
        <div class="mmap-node">
          <div class="mmap-box"><span class="mmap-no">14</span>local：刨根问底式提问</div>
          <ul class="mmap-leaves">
            <li>向量召回 20 个实体</li>
            <li>沿图扩出四路证据</li>
            <li>排序截断，拼 4 段 CSV</li>
          </ul>
        </div>
        <div class="mmap-node">
          <div class="mmap-box"><span class="mmap-no">15</span>global：我要的是全局</div>
          <ul class="mmap-leaves">
            <li>筛出 512 个社区报告</li>
            <li>Map 分组找要点，Reduce 汇总</li>
          </ul>
        </div>
        <div class="mmap-node">
          <div class="mmap-box"><span class="mmap-no">16</span>naive：直接翻书</div>
          <ul class="mmap-leaves">
            <li>分块向量库取 top-k</li>
            <li>等效普通 RAG，充当基线</li>
          </ul>
        </div>
      </div>
    </div>
    <div class="mmap-branch mm-b5">
      <div class="mmap-part"><span class="mmap-pno">Part 5</span>底层支撑机制</div>
      <div class="mmap-kids">
        <div class="mmap-node">
          <div class="mmap-box"><span class="mmap-no">17</span>token 与预算</div>
          <ul class="mmap-leaves">
            <li>排序后再截断</li>
            <li>truncate_list_by_token_size 全局复用</li>
          </ul>
        </div>
        <div class="mmap-node">
          <div class="mmap-box"><span class="mmap-no">18</span>调用 LLM 的三件保险</div>
          <ul class="mmap-leaves">
            <li>重试：指数退避</li>
            <li>缓存：同一道题不答两次</li>
            <li>限流：进闸门先排队</li>
          </ul>
        </div>
        <div class="mmap-node">
          <div class="mmap-box"><span class="mmap-no">19</span>三类存储与可插拔</div>
          <ul class="mmap-leaves">
            <li>KV / Vector / Graph 三个接口</li>
            <li>换后端只改一个字段</li>
          </ul>
        </div>
        <div class="mmap-node">
          <div class="mmap-box"><span class="mmap-no">20</span>动手路线与下一步</div>
          <ul class="mmap-leaves">
            <li>跑通 → 看产物 → 打印上下文 → 改一处</li>
            <li>按性价比排序的延伸方向</li>
          </ul>
        </div>
      </div>
    </div>
  </div>
</div>
</div>

## 怎么看这张图

横向从左到右分三层：**篇 → 讲 → 要点**。每根竖线是同一层的分叉总线，最左边那根总线把五篇串在一起。图比正文列宽，可以左右拖动。

## 两条主线

教程的骨架是两条主线交替推进，读的时候抓住它们就不会乱。

| 主线 | 覆盖 | 关键转折 |
| --- | --- | --- |
| **写入**（Part 1 → Part 3） | 资料怎么变成图和报告 | 第 4 课的三个短板，第 5 课给出解法，第 9~13 课逐站实现 |
| **查询**（Part 1 → Part 4） | 问题怎么变成答案 | 第 7 课定下三种模式，第 14~16 课逐个拆解 |

Part 5 是横切在两条线上的支撑件：token 预算管住长度，LLM 三件保险管住成本与稳定，可插拔存储管住扩展性。

## 三个短板与解法

第 4 课列出的病症，在后面的每一讲里都有对应的治愈点。

| 短板 | 治它的机制 | 出处 |
| --- | --- | --- |
| 链条断裂 | 沿图扩展，顺着边把断开的线索接上 | 第 11 课合并、第 14 课扩展 |
| 全局失明 | 社区报告提前把「部门年报」写好 | 第 12~13 课分组与写报告、第 15 课读报告 |
| 信息孤岛 | 同一实体在图里收敛成一个节点 | 第 11 课节点合并 |

## 选模式的口诀

| 想问什么 | 用哪个模式 |
| --- | --- |
| 具体的人、事、细节 | `local` |
| 整体情况、主题归纳 | `global` |
| 做对比实验、查基线 | `naive` |

## 下一步

- 读正文：[从入门到理解（初学者教程）](/graphrag/nano-graphrag-tutorial)
- 看另一张图：[源码深度解析 · 思维脑图](/graphrag/nano-graphrag-source-analysis-mindmap)
- 动手：[源码深度解析（参考手册）](/graphrag/nano-graphrag-source-analysis)
