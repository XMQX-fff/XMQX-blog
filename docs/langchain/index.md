# LangChain 学习笔记

本栏目依据 [langchain-doc.cn](https://langchain-doc.cn/) （LangChain 中文社区文档，覆盖 v1.x）整理而成，
旨在以一条连贯的主线覆盖 LangChain v1 的核心概念，而非逐页翻译。

::: warning 关于准确性
笔记基于撰写时的文档版本。LangChain v1 对链与智能体作了大规模重构，
`langchain.agents.create_agent`、标准内容块等均为 v1 引入的接口；
具体 API 请以[官方文档](https://langchain-doc.cn/)为准。
:::

## 本栏目怎么读

- 每篇都遵循同一结构：**是什么 → 解决什么问题 → 完整可运行例子 → 预期输出**；
- 例子需要 API 密钥才能跑，跑不动也可以只看"预期输出"理解行为；
- 遇到陌生名词先查本篇内的"名词解释"小框，查不到再谷歌；
- 文中互相引用的链接都是站内锚点，点过去就是对应小节。

## 栏目内容

| 文章 | 主题 | 适用读者 |
| --- | --- | --- |
| [概览与设计理念](/langchain/overview) | 生态分工、`create_agent`、v1 的核心变更、发展历程 | 选型阶段的读者 |
| [快速入门](/langchain/quickstart) | 安装、凭据、基础智能体、研究型智能体、LangSmith 追踪 | 希望快速建立感性认识的读者 |
| [智能体与运行框架](/langchain/agents) | `create_agent`、`AgentState`、调用与流式、中间件能力分类 | 本栏目的核心章节 |
| [模型·消息·工具](/langchain/components) | 标准模型接口、四类消息、`@tool` 与 `ToolRuntime` | 使用任何组件前的必读内容 |
| [记忆·流式·结构化输出](/langchain/context-output) | checkpointer、三种 stream mode、`response_format` | 对话类与结构化场景 |
| [中间件与运行时](/langchain/middleware-runtime) | 钩子体系、预置中间件、`Runtime` 依赖注入 | 需要定制行为的读者 |
| [上下文工程与高级能力](/langchain/advanced) | 三类上下文、人在回路、多智能体、长期记忆、护栏 | 面向生产的读者 |

## 推荐学习路线

```text
第 1 步  阅读「概览」与「快速入门」
         └─ 明确 LangChain / LangGraph / Deep Agents 三者的分工

第 2 步  精读「智能体与运行框架」
         └─ create_agent 是 v1 的绝对中心，其余章节均为其展开

第 3 步  补齐「模型·消息·工具」
         └─ 三者是智能体的输入、推理引擎与行动能力

第 4 步  按需选读
         ├─ 长对话与打字机效果 → 记忆·流式·结构化输出
         ├─ 需要定制执行流程   → 中间件与运行时
         └─ 面向生产与多角色   → 上下文工程与高级能力
```

## 核心认识

LangChain v1 给出了一条清晰的等式：

> **智能体 = 模型 + 运行框架（harness）。**

运行框架是围绕模型循环的一切组件：提示词、工具，以及任何用于塑造行为的中间件。
其职责可概括为一句话——**针对指定任务，在恰当的时间为模型提供恰当的上下文**。

由此可以理解本栏目的结构：模型与消息解决"如何与模型对话"，工具解决"模型能做什么"，
记忆与流式解决"对话如何延续与呈现"，中间件与上下文工程解决"如何精确控制循环中的每一步"。

::: tip 与 LangGraph 栏目的关系
LangChain 智能体构建于 LangGraph 之上。凡涉及检查点、`thread_id`、人在回路中断等概念，
均直接沿用 LangGraph 的机制。已阅读本博客的
[LangGraph 学习笔记](/langgraph/) 的读者可跳过相应背景说明。
:::

## 资料入口

- 中文文档：[langchain-doc.cn](https://langchain-doc.cn/)
- 代码仓库：[github.com/langchain-ai/langchain](https://github.com/langchain-ai/langchain)
- API 参考：[reference.langchain.com](https://reference.langchain.com/)
