# LangGraph 学习笔记

## 栏目内容

| 文章 | 主题 | 适用读者 |
| --- | --- | --- |
| [开篇：LangGraph 的定位](/langgraph/why-langgraph) | 与 LangChain 的关系、核心能力、适用与不适用场景 | 尚在评估是否采用的读者 |
| [快速上手](/langgraph/quickstart) | 安装、`create_react_agent`、记忆、结构化输出 | 希望快速建立感性认识的读者 |
| [图 API 三要素](/langgraph/graph-api) | State / Node / Edge、超步、Reducer、`Send`、`Command` | 需要自定义工作流的读者 |
| [智能体架构](/langgraph/agent-architectures) | 路由器、工具调用型智能体、反思、多智能体拓扑 | 需要设计复杂流程的读者 |
| [持久化与记忆](/langgraph/persistence-memory) | Checkpointer、Store、短期与长期记忆、长对话治理 | 对话类应用的必备知识 |
| [人机协作与流式输出](/langgraph/hil-streaming) | `interrupt()` / `Command(resume=...)` / 五种 stream mode | 涉及审核流程与流式界面的场景 |

## 推荐学习路线

```text
第 1 步  阅读「开篇」
         └─ 明确 LangGraph 解决的问题与适用边界

第 2 步  实践「快速上手」
         └─ 以十行代码构建带工具的智能体，建立整体认识

第 3 步  研读「图 API 三要素」（本栏目理论密度最高的一篇）
         └─ 重点理解 State 的 reducer——该概念贯通后续全部章节

第 4 步  按需选读
         ├─ 对话类产品      → 持久化与记忆
         ├─ 流程复杂 / 多角色 → 智能体架构
         └─ 审核流程 / 流式 UI → 人机协作与流式输出
```

## 核心认识

LangGraph 最具辨识度的一点在于：**它既不抽象提示词，也不抽象架构**。

官方将其定义为"低级别的编排框架"。它不约束提示词的写法，也不规定智能体的形态，
只负责状态流转、故障恢复、人工介入等底层机制。
因此初次接触时容易产生"什么都要自己实现"的感觉——
这正是其区别于各类黑盒智能体框架之处：可控性来自较低的抽象层级。

::: tip 资料入口
- 官方中文文档：[langgraph.com.cn](https://langgraph.com.cn/)
- 代码仓库：[github.com/langchain-ai/langgraph](https://github.com/langchain-ai/langgraph)
- 官方课程：[LangChain Academy — Intro to LangGraph](https://academy.langchain.com/courses/intro-to-langgraph)
:::
