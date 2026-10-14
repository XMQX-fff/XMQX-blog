# LangGraph 学习笔记

这个栏目是我跟着 [langgraph.com.cn](https://langgraph.com.cn/) （LangGraph 官方文档的中文站）从头啃下来的笔记。
不是翻译，是我自己理解完、用自己的话重新讲一遍，中间夹着一些我踩过的坑和当时的疑惑。

::: warning 关于准确度
笔记基于我阅读时的文档版本，官方 API 改得挺快的（尤其是 `langgraph.prebuilt` 那一块）。
写代码前请以[官方文档](https://langgraph.com.cn/)为准，别把我笔记里的代码直接复制进生产环境。
:::

## 这个栏目讲什么

| 文章 | 内容 | 适合谁 |
| --- | --- | --- |
| [开篇：LangGraph 到底是个啥](/langgraph/why-langgraph) | 它和 LangChain 什么关系、核心优势、什么时候**不该**用它 | 还在犹豫要不要学的人 |
| [快速上手：跑通第一个 Agent](/langgraph/quickstart) | 装包 → `create_react_agent` → 加记忆 → 结构化输出 | 想先看到东西跑起来的人 |
| [图 API 三件套](/langgraph/graph-api) | State / Node / Edge、超步、Reducer、`Send`、`Command` | 想自己搭工作流的人 |
| [智能体架构](/langgraph/agent-architectures) | 路由器、工具调用 Agent、反思、多智能体四种拓扑 | 想设计复杂流程的人 |
| [持久化与记忆](/langgraph/persistence-memory) | Checkpointer、Store、短期/长期记忆、长对话怎么裁 | 做聊天类应用必读 |
| [人机协作与流式输出](/langgraph/hil-streaming) | `interrupt()` / `Command(resume=...)` / 五种 stream mode | 要做审核、要打字机效果的人 |

## 推荐学习路线

```text
第 1 步  读「开篇」
         └─ 搞清楚 LangGraph 解决什么问题，别盲目上

第 2 步  跑「快速上手」
         └─ 10 行代码起一个带工具的 Agent，先建立手感

第 3 步  啃「图 API 三件套」（这一篇最硬，值得慢读）
         └─ 重点理解 State 的 reducer —— 想通了它，后面全通了

第 4 步  按需挑
         ├─ 做对话产品 → 持久化与记忆
         ├─ 流程复杂 / 多个角色 → 智能体架构
         └─ 要审核、要流式 UI → 人机协作与流式输出
```

## 我的一点心得

LangGraph 最反直觉的一点是：**它并不抽象提示词，也不抽象架构**。

官方原话大意是，LangGraph 是"低级别的编排框架"。也就是说，它不管你提示词怎么写、
不管你的 Agent 长什么形状，它只负责把"状态怎么流转、断了怎么接上、人工怎么插进来"
这些底层脏活干好。所以刚上手会觉得"怎么什么都要自己写"——
习惯了就好，这恰恰是它比一堆黑盒 Agent 框架好用的地方。

::: tip 资料入口
- 官方中文文档：[langgraph.com.cn](https://langgraph.com.cn/)
- 仓库：[github.com/langchain-ai/langgraph](https://github.com/langchain-ai/langgraph)
- 官方免费课程：[LangChain Academy — Intro to LangGraph](https://academy.langchain.com/courses/intro-to-langgraph)
:::
