# A2A 协议学习笔记

> A2A（Agent2Agent）是 Google 于 2025 年 4 月开源、随后交由 Linux Foundation 托管的
> 智能体互操作协议。2026 年 8 月，A2A 进一步加入 **Agentic AI Foundation**，
> 与 MCP、AGENTS.md 等项目同处一个基金会生态。

本栏目以 **A2A 协议规范 v1.0.0** 为基准，串起「为什么需要协议 → 协议长什么样 →
怎么写 → 怎么上生产 → 怎么选型」的完整链路。

## 一句话定位

> A2A 是一套**应用层通信协议**，规定了"一个智能体如何发现另一个智能体、
> 把工作委托给它、并持续跟踪这项工作的进展"。

它解决的是**智能体与智能体之间**的协作问题，与"智能体与工具之间"的 MCP
是互补关系：MCP 是纵向的（让一个智能体变深），A2A 是横向的（让智能体之间连成网）。

## 栏目内容

| 文章 | 主题 | 适合什么时候读 |
| --- | --- | --- |
| [开篇导读：为什么需要 A2A](/a2a/why-a2a) | 协议诞生的背景、解决什么痛点、划清能力边界 | 第一次听说 A2A，想先判断它值不值得投入 |
| [前置知识准备](/a2a/prerequisites) | LLM Agent 基础、工具调用、状态机、JSON-RPC、SSE、Task/消息模型 | 协议读起来"每句都认识，连起来不懂" |
| [核心认知：什么是 Agent-to-Agent 协议](/a2a/core-concepts) | A2A 的定位、六个核心角色、协议层的三层结构 | 想建立整体心智模型 |
| [核心模型详解](/a2a/data-model) | Task 状态机、Message、Artifact、Agent Card、Part | 要动手实现服务端 / 客户端 |
| [标准接口全解析](/a2a/interfaces) | 11 个操作、JSON-RPC 绑定、SSE 流式、推送通知、三种绑定对照 | 要照着协议写请求 |
| [通信模型：智能体之间怎么对话](/a2a/communication) | 直连与对等两种模式、能力发现、路由、幂等与重试 | 要设计跨组织、跨团队的协作链路 |
| [成熟系统架构拆解](/a2a/architecture) | Gateway / Orchestrator / MessageBus / Agent Host / ToolRuntime 分层 | 要把 A2A 塞进已有平台 |
| [全流程调用时序](/a2a/sequence) | 正常流程、流式流程、四类异常分支 | 要排障、要画时序图进设计文档 |
| [动手实战 1：最小 A2A Demo](/a2a/hands-on-minimal) | 纯协议实现 Agent Card + SendMessage + 双智能体协同 | 想用几百行代码跑通协议 |
| [动手实战 2：对接 RAG 与工具调用](/a2a/hands-on-rag) | ToolRuntime 与 A2A 的分工、把检索与沙箱封成 Agent 能力 | 想把已有组件接进协议 |
| [生产落地：平台必备能力](/a2a/production) | 权限、限流、护栏、审计、持久化、断点续跑、链路追踪、K8s 扩缩容 | 要交付上线 |
| [避坑专题：高频误区](/a2a/pitfalls) | 选型误区、乱序、大文件、断线重连、版本迁移 | 准备踩坑之前先看 |
| [对比选型](/a2a/comparison) | A2A vs LangGraph / AutoGen / CrewAI / 自研消息总线 | 做技术选型评审 |
| [收尾：未来方向与资源清单](/a2a/future) | 扩展机制、绑定治理、生态现状、官方资源索引 | 读完想继续深挖 |
| [附录：核心 JSON Schema](/a2a/appendix) | AgentCard / Task / Message / Artifact / Part 完整字段表 | 写代码时要对着抄字段 |

## 推荐学习路线

```text
第 1 步  开篇导读 + 核心认知
         └─ 先建立"协议层"这个位置感，知道 A2A 管什么、不管什么

第 2 步  前置知识准备
         └─ 补齐 JSON-RPC / SSE / 状态机三个缺口

第 3 步  核心模型详解
         └─ 本栏目理论密度最高的一篇，Task/Message/Artifact 三件套
            后面每一篇都要回头引用这里的概念

第 4 步  标准接口全解析
         └─ 把模型映射到具体的 11 个操作上

第 5 步  动手实战 1
         └─ 手写一遍最小实现，协议立刻从"规范"变成"能跑的东西"

第 6 步  按需选读
         ├─ 要接已有系统   → 通信模型 + 系统架构 + 调用时序
         ├─ 要接 RAG/工具  → 动手实战 2
         ├─ 要上线         → 生产落地 + 避坑专题
         └─ 要做选型       → 对比选型
```

## 读者自检

进入第 3 步之前，下面这四问应当都能答上来：

1. JSON-RPC 2.0 的 request / response / error 三种结构长什么样？
2. SSE 的 `data:` 帧是怎么把服务端推送伪装成"流"的？
3. 一个任务从提交到结束，中间会经历哪些状态？终态有哪几个？
4. 消息和产物为什么要分成两个对象？

答不上来的，回到[前置知识准备](/a2a/prerequisites)补一补。

## 版本说明

本栏目内容以 **v1.0.0** 为基准撰写。v1.0 相比 v0.3 有一批破坏性变更（方法名改名、
Part 类型合并、枚举值改为 `SCREAMING_SNAKE_CASE` 等），涉及老代码时先看
[避坑专题](/a2a/pitfalls)里的迁移小节。

::: tip 资料入口
- 官方文档：[a2a-protocol.org](https://a2a-protocol.org/latest/)
- 规范正文：[a2a-protocol.org/latest/specification](https://a2a-protocol.org/latest/specification/)
- v1.0 变更说明：[What's New in v1.0](https://a2a-protocol.org/latest/whats-new-v1/)
- 主仓库：[github.com/a2aproject/A2A](https://github.com/a2aproject/A2A)
- SDK 集合：[Python](https://github.com/a2aproject/a2a-python) ·
  [Go](https://github.com/a2aproject/a2a-go) ·
  [Java](https://github.com/a2aproject/a2a-java) ·
  [JS](https://github.com/a2aproject/a2a-js) ·
  [.NET](https://github.com/a2aproject/a2a-dotnet) ·
  [Rust](https://github.com/a2aproject/a2a-rs)
:::
