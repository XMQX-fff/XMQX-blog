---
description: GraphRAG 学习资料：围绕开源项目 nano-graphrag（微软 GraphRAG 的极简实现）整理的初学者教程与源码深度解析，覆盖知识图谱构建、实体抽取、社区检测、多模式检索与本地/全局查询全流程。
---

# GraphRAG 学习

本栏目围绕开源项目 [nano-graphrag](https://github.com/gusye1234/nano-graphrag)（微软 GraphRAG 的极简实现：官方 README 口径约 1100 行、按当前源码实测核心约 2900 行）整理的系列学习资料。

## 这两份资料是什么？

| 资料 | 定位 | 适合谁 |
| --- | --- | --- |
| [从入门到理解（初学者教程）](/graphrag/nano-graphrag-tutorial) | **由浅入深的课**：先讲清"为什么需要 GraphRAG"，再用同一个例子走完写入与查询全流程，每课有要点总结 | 没接触过 RAG / 知识图谱的初学者 |
| [源码深度解析（参考手册）](/graphrag/nano-graphrag-source-analysis) | **工具书式手册**：架构分层、模块细节、关键设计决策、源码文件地图 | 已想通原理、要抠实现细节的进阶读者 |
| [从入门到理解 · 思维脑图](/graphrag/nano-graphrag-tutorial-mindmap) | **教程的结构图**：五篇二十讲的主题骨架与每讲要点 | 想先看全局、决定从哪讲读起 |
| [源码深度解析 · 思维脑图](/graphrag/nano-graphrag-source-analysis-mindmap) | **手册的结构图**：十二章的模块地图与关键机制 | 准备动手读源码、想定位到具体文件 |

## 推荐学习路线

```text
第 1 步  读「从入门到理解」
         └─ 建立直觉：RAG → 向量检索 → 短板 → 知识图谱 → GraphRAG
         └─ 看懂 insert 6 步流程与 query 三种模式

第 2 步  跑通最小例子
         └─ clone nano-graphrag，insert 一段文本，三种 mode 各问一次
         └─ 打开工作目录，把流程和磁盘产物对上号

第 3 步  按需查「源码深度解析」
         └─ 写入细节 → 第 5 章 ；查询细节 → 第 6 章
         └─ 工具机制（缓存/限流/预算）→ 第 7、8 章

第 4 步  带着问题读源码
         └─ 路线图见教程第 20 课 / 手册第 12 章
```

## 快速入口

- 🟢 **初学**：[从入门到理解 →](/graphrag/nano-graphrag-tutorial) · [教程脑图 →](/graphrag/nano-graphrag-tutorial-mindmap)
- 🔵 **进阶**：[源码深度解析 →](/graphrag/nano-graphrag-source-analysis) · [手册脑图 →](/graphrag/nano-graphrag-source-analysis-mindmap)
- 📦 **原仓库**：[github.com/gusye1234/nano-graphrag](https://github.com/gusye1234/nano-graphrag)

::: tip 后续计划
后续会补充：与官方 Microsoft GraphRAG 的对照笔记、图算法（Leiden）专题、以及动手实验记录。
:::
