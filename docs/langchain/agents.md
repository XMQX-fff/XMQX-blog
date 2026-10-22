# 智能体与运行框架

`create_agent` 是 LangChain v1 的绝对中心。本篇说明其组成、状态模型、
调用方式与运行配置，其余章节均为本篇的展开。

## 怎么读本篇

本篇是栏目的**枢纽**：消息、工具、记忆、中间件都以某种方式挂在这条
循环上。建议先花两分钟看 1.1 节把"智能体循环"在脑子里画出来，
后面每一节都是在给这条循环加东西。

## 1. create_agent 的三个组成部分

### 1.1 先看循环本身

官方给出的核心等式为：

> **智能体 = 模型 + 运行框架。**

**名词解释：运行框架（harness）。** 围绕"模型调用"这一件事的**全部外围
组件**——提示词、工具、以及塑造行为的中间件。为什么需要它？因为裸模型
只会聊天；要把"聊天"变成"能干活"，必须有人负责：

```text
        ┌─────────────────────────────────────────────┐
        │                 智能体循环                    │
        │                                             │
        │   ① 模型看到：系统提示词 + 消息历史 + 工具定义 │
        │              ↓                              │
        │   ② 模型输出：一段文本，或一个/多个工具调用     │
        │              ↓                              │
        │   ③ 有工具调用？──是──▶ 执行工具，结果作为      │
        │              │          ToolMessage 回传 ────┤
        │             否                              │
        │              ↓                              │
        │   ④ 输出最终回答，循环结束                     │
        └─────────────────────────────────────────────┘
```

模型不知道这个循环的存在——它只是每次被调用时看到越来越长的消息列表，
决定接下来"说话"还是"调用工具"。`create_agent` 就是把这套循环
（外加一堆生产必需能力）替你搭好的**工厂函数**。

具体到 API，只要三项输入：

```python
from langchain.agents import create_agent

agent = create_agent(
    model="openai:gpt-5.5",   # ① 模型：字符串或模型实例
    tools=[get_weather],       # ② 工具：函数列表
    system_prompt="你是……",     # ③ 提示：系统提示词或动态提示
)
```

运行框架自动搭建循环：模型发起工具调用 → 执行工具 → 结果回传 → 再次调用模型，
直至模型不再请求工具。开发者无需手工编排节点与边。

### 1.2 提示的两种形式

```python
from langchain.agents.middleware import dynamic_prompt, ModelRequest


@dynamic_prompt
def personalized_prompt(request: ModelRequest) -> str:
    user_name = request.runtime.context["user_name"]
    return f"你是一名乐于助人的助手，请称呼用户为 {user_name}。"
```

- **`system_prompt` 字符串**：固定指令，每次调用一字不差，适合角色设定；
- **`@dynamic_prompt` 函数**：每次模型调用前现算，适合依赖运行时上下文
  （用户身份、语言、租户）的指令。它本质是中间件提供的便捷形式——
  等价于一个改提示词的 `wrap_model_call`。

完整跑一遍的样子：

```python
from dataclasses import dataclass

from langchain.agents import create_agent
from langchain.agents.middleware import dynamic_prompt, ModelRequest


@dataclass
class Context:
    user_name: str


@dynamic_prompt
def personalized_prompt(request: ModelRequest) -> str:
    user_name = request.runtime.context.get("user_name", "朋友")
    return f"你是一名乐于助人的助手，请称呼用户为 {user_name}。"


agent = create_agent(
    model="openai:gpt-5.5",
    tools=[get_weather],
    middleware=[personalized_prompt],
    context_schema=Context,
)

result = agent.invoke(
    {"messages": [{"role": "user", "content": "你好"}]},
    context=Context(user_name="小明"),
)
print(result["messages"][-1].text)  # （示意）你好，小明！有什么可以帮你？
```

## 2. 状态：AgentState

**名词解释：状态（state）。** 贯穿整个图的**共享数据**——可以把它想象成
一张在循环各环节之间传递的"工作台"：工具往上写结果，提示词从上面读历史，
每跑完一步落一次盘（检查点）。智能体的状态（state）是贯穿整个图的共享数据。
默认 `AgentState` 至少包含 `messages` 列表。

### 2.1 messages 为什么用追加语义

`AgentState` 的 `messages` 键挂着一个叫 **`add_messages` 的归约器
（reducer）**。

**名词解释：归约器。** 决定"同一个状态键收到多个更新时怎么合并"的函数。
`add_messages` 的规则是：按消息 ID 追加新消息、就地更新同 ID 的旧消息。
没有它，每次节点返回的 `{"messages": [...]}` 都会把上一轮的对话**整体覆盖**
——多轮对话就断了。这也是为什么扩展状态时，自定义字段要想清楚
"并发写入要不要归约"。

扩展状态以携带业务字段：

```python
from langchain.agents import AgentState


class CustomAgentState(AgentState):
    user_id: str
    preferences: dict


agent = create_agent(
    model="openai:gpt-5.5",
    tools=[...],
    state_schema=CustomAgentState,
    checkpointer=InMemorySaver(),
)
```

`state_schema=` 把自定义状态类挂上去后，`invoke` 时可以直接传初始值，
工具里可以从 `runtime.state` 读：

```python
result = agent.invoke(
    {"messages": [{"role": "user", "content": "你好"}],
     "user_id": "u-123", "preferences": {"theme": "dark"}},
    {"configurable": {"thread_id": "1"}},
)
```

::: warning 状态键的可见范围
子智能体若需读取某个状态键，该键必须**同时**定义在主、子智能体的状态模式中。
只给子图定义、父图没有，数据过不去；反过来也一样。
:::

状态的读写路径有三条：工具内读 `runtime.state`、写 `Command(update={...})`
（见 [components.md 3.3 节](/langchain/components#3-3-toolruntime访问运行时)）；
中间件内经 `state` 参数读、经返回字典写；外部通过 `invoke` / `stream`
传入初始值。

## 3. 调用与流式

### 3.1 同步调用（带记忆的最小完整例子）

```python
from langgraph.checkpoint.memory import InMemorySaver

agent = create_agent(
    model="openai:gpt-5.5",
    tools=[...],
    checkpointer=InMemorySaver(),   # 没有它就没有记忆
)

config = {"configurable": {"thread_id": "thread-1"}}

r1 = agent.invoke({"messages": [{"role": "user", "content": "我叫 Bob"}]}, config)
r2 = agent.invoke({"messages": [{"role": "user", "content": "我叫什么？"}]}, config)

print(r2["messages"][-1].text)  # （示意）你叫 Bob。
```

**名词解释：`thread_id`。** "对话"的唯一标识。相同 id = 同一场对话，
检查点按它归档历史；换 id = 开一场全新的。生产环境通常一人一会话一个
`thread_id`（如 `user-{id}` 或 UUIDv7）。

### 3.2 带运行时上下文的调用

```python
from dataclasses import dataclass

@dataclass
class Context:
    user_name: str

agent = create_agent(model="openai:gpt-5.5", tools=[...], context_schema=Context)

result = agent.invoke(
    {"messages": [{"role": "user", "content": "你好"}]},
    config={"configurable": {"thread_id": "thread-1"}},
    context=Context(user_name="John Smith"),
)
```

`thread_id` 界定对话范围（消息历史与检查点），`context` 承载单次运行的
静态数据；生产环境中两者通常同时传入。

**名词解释：依赖注入。** `context=` 传数据、工具里 `runtime.context` 读——
这就是依赖注入模式。好处是工具不依赖全局变量、不读环境变量，
测试时直接构造一个 `Context(...)` 传进去即可，行为完全可控。

### 3.3 流式

```python
for chunk in agent.stream({"messages": [...]}, stream_mode="updates", version="v2"):
    print(chunk["type"])   # "updates"
    print(chunk["data"])   # {'model': {'messages': [AIMessage(...)]}} 等
```

`updates` 模式按"哪个节点跑完了"产出增量，是展示进度的主力模式；
`messages` 模式逐 token 产出，是打字机效果。两者可组合
`stream_mode=["messages", "updates"]`（记得 `version="v2"`）。

需要子智能体的输出时，在外层图中调用须设置 `subgraphs=True`，
并通过元数据 `lc_agent_name` 区分来源。完整流式专题见
[人机协作与流式输出](/langgraph/hil-streaming)（LangGraph 栏目）。

## 4. 运行框架提供的能力

`create_agent` 的能力可以归纳为四类，**全部通过中间件实现**——
这也是 v1 的设计哲学：核心循环保持最小，能力按需插拔。

| 能力 | 说明 | 代表实现 |
| --- | --- | --- |
| **监控** | 日志、分析、调试 | LangSmith 追踪、自定义 `after_agent` |
| **修改** | 调整提示词、工具选择、输出格式 | `@dynamic_prompt`、`request.override(tools=...)` |
| **控制** | 重试、回退、提前终止 | `ToolRetryMiddleware`、`ModelFallbackMiddleware` |
| **强制执行** | 速率限制、护栏、PII 检测 | `ModelCallLimitMiddleware`、`PIIMiddleware` |

```python
from langchain.agents.middleware import (
    SummarizationMiddleware,
    ToolRetryMiddleware,
)

agent = create_agent(
    model="openai:gpt-5.5",
    tools=[...],
    middleware=[
        SummarizationMiddleware(model="gpt-5.4-mini", trigger=("tokens", 4000)),
        ToolRetryMiddleware(),
    ],
)
```

上面这行的含义：**对话快到 4000 token 就把旧历史压缩成摘要**
（`SummarizationMiddleware`），**工具失败自动重试**
（`ToolRetryMiddleware`）。所有中间件的清单、参数、适用场景见
[中间件与运行时](/langchain/middleware-runtime)，那里每个都配了完整例子。

::: tip 能力组合原则
官方建议从最简形态出发，**仅组合用例所需的能力**。
每增加一项中间件都会带来额外的提示词或模型开销，应结合追踪数据评估收益。
:::

## 5. 运行时配置

### 5.1 检查点保存器（checkpointer）

```python
from langgraph.checkpoint.memory import InMemorySaver

agent = create_agent(model=..., tools=[...], checkpointer=InMemorySaver())
```

**名词解释：检查点保存器。** 负责把 state 存起来、并能按 `thread_id`
取回来的组件。配置 `thread_id` 后，每步状态被持久化，从而获得三样东西：
**短期记忆**（多轮对话）、**人在回路中断恢复**（暂停后能继续）、
**容错**（失败后从上一个成功步骤重来）。`InMemorySaver` 仅适合开发，
生产须改用 `PostgresSaver`、`MongoDBSaver` 等数据库实现
（用法见[持久化与记忆](/langgraph/persistence-memory)）。

### 5.2 上下文 schema

`context_schema` 声明 `context` 参数的结构，配合 `ToolRuntime.context`
把用户身份等信息注入工具与中间件，等价于依赖注入——
无需硬编码或全局状态，且更易测试。见 3.2 节。

### 5.3 命名

```python
create_agent(model=..., name="researcher", ...)
```

**名词解释：`lc_agent_name`。** 给智能体命名后，多智能体场景里
（子智能体作为子图跑在外层图内）可以用它区分消息来源：流式时打开
`subgraphs=True`，每条消息的 metadata 里的 `lc_agent_name` 就是
产出它的那个智能体的名字。

## 6. 调用的版本

`invoke` / `stream` 支持 `version="v2"`（需 LangGraph 1.1+）：无论单模式还是
多模式，每个数据块都是带 `type` / `ns` / `data` 的 `StreamPart`，不再需要
元组解包；`invoke` 则返回带 `.value` 与 `.interrupts` 的 `GraphOutput`。
新应用可进一步使用 LangChain v1.3 引入的**事件流类型化投影 API**
（`stream_events(..., version="v3")` 配合 `.messages` / `.values` /
`.interleave(...)` 等独立迭代器），为消息、状态值、工具调用与子图提供
统一入口，无需再按 `stream_mode` 分支处理。旧代码仍可使用 v1 格式。

## 7. 小结

- `create_agent(model, tools, 提示)` 即完整可运行的智能体；
  框架负责"模型 ↔ 工具"循环，你负责喂对上下文。
- 状态以 `AgentState` 为基础，`messages` 由 `add_messages` 归约器合并，
  自定义字段用 `state_schema` 扩展。
- `thread_id` 界定对话，`context` 承载单次运行数据；
  checkpointer 是记忆、中断恢复、容错的共同地基。
- 监控、修改、控制、强制执行四类能力，全部经由中间件注入——
  核心循环最小化，能力按需组合。

下一篇：[模型·消息·工具](/langchain/components)。
