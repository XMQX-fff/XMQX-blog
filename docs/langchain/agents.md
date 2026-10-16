# 智能体与运行框架

`create_agent` 是 LangChain v1 的绝对中心。本篇说明其组成、状态模型、
调用方式与运行配置，其余章节均为本篇的展开。

## 1. create_agent 的三个组成部分

智能体 = 模型 + 运行框架，具体到 API 则是三项输入：

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

### 提示的两种形式

```python
from langchain.agents.middleware import dynamic_prompt, ModelRequest

@dynamic_prompt
def personalized_prompt(request: ModelRequest) -> str:
    user_name = request.runtime.context["user_name"]
    return f"你是一名乐于助人的助手，请称呼用户为 {user_name}。"
```

`system_prompt` 适合固定指令，`@dynamic_prompt` 适合依赖运行时上下文
（用户身份、语言、租户）的指令。后者本质是中间件提供的便捷形式。

## 2. 状态：AgentState

智能体的状态（state）是贯穿整个图的共享数据。默认 `AgentState`
至少包含 `messages` 列表，并由 `add_messages` 归约器合并——
这正是追加而非覆盖消息的原因。

扩展状态以携带业务字段：

```python
from langchain.agents import AgentState, create_agent

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

::: warning 状态键的可见范围
子智能体若需读取某个状态键，该键必须**同时**定义在主、子智能体的状态模式中。
:::

状态的读写路径有三条：工具内读 `runtime.state`、写 `Command(update={...})`；
中间件内经 `state` 参数读、经返回字典写；外部通过 `invoke` / `stream`
传入初始值。

## 3. 调用与流式

### 同步调用

```python
result = agent.invoke(
    {"messages": [{"role": "user", "content": "你好"}]},
    config={"configurable": {"thread_id": "thread-1"}},
)
print(result["messages"][-1].content)
```

### 带运行时上下文的调用

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

### 流式

```python
for chunk in agent.stream({"messages": [...]}, stream_mode="updates"):
    print(chunk)
```

需要子智能体的输出时，在外层图中调用须设置 `subgraphs=True`，
并通过元数据 `lc_agent_name` 区分来源。

## 4. 运行框架提供的能力

`create_agent` 的能力可以归纳为四类，**全部通过中间件实现**：

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

::: tip 能力组合原则
官方建议从最简形态出发，**仅组合用例所需的能力**。
每增加一项中间件都会带来额外的提示词或模型开销，应结合追踪数据评估收益。
:::

## 5. 运行时配置

### 检查点保存器（checkpointer）

```python
from langgraph.checkpoint.memory import InMemorySaver

agent = create_agent(model=..., tools=[...], checkpointer=InMemorySaver())
```

配置 `thread_id` 后，每步状态被持久化，从而获得短期记忆、
人在回路中断恢复等能力。`InMemorySaver` 仅适合开发，
生产须改用 `PostgresSaver`、`MongoDBSaver` 等数据库实现。

### 上下文 schema

`context_schema` 声明 `context` 参数的结构，配合 `ToolRuntime.context`
把用户身份等信息注入工具与中间件，等价于依赖注入——
无需硬编码或全局状态，且更易测试。

### 命名

```python
create_agent(model=..., name="researcher", ...)
```

为智能体命名后，可在外层流式中通过 `lc_agent_name` 过滤特定子智能体的输出。

## 6. 调用的版本

`invoke` / `stream` 支持 `version="v2"`（需 LangGraph 1.1+）：无论单模式还是
多模式，每个数据块都是带 `type` / `ns` / `data` 的 `StreamPart`，不再需要
元组解包；`invoke` 则返回带 `.value` 与 `.interrupts` 的 `GraphOutput`。
新应用可进一步使用 LangChain v1.3 引入的**事件流类型化投影 API**
（`stream_events(..., version="v3")` 配合 `.messages` / `.values` /
`.interleave(...)` 等独立迭代器），为消息、状态值、工具调用与子图提供
统一入口，无需再按 `stream_mode` 分支处理。旧代码仍可使用 v1 格式。

## 7. 小结

- `create_agent(model, tools, 提示)` 即完整可运行的智能体。
- 状态以 `AgentState` 为基础，由 `add_messages` 归约器合并。
- `thread_id` 界定对话，`context` 承载单次运行数据。
- 监控、修改、控制、强制执行四类能力，全部经由中间件注入。

下一篇：[模型·消息·工具](/langchain/components)。
