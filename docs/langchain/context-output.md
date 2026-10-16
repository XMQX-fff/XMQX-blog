# 记忆 · 流式 · 结构化输出

本篇覆盖三个高频场景：对话如何延续（短期记忆）、输出如何实时呈现（流式）、
数据如何以可预测格式返回（结构化输出）。

## 1. 短期记忆

短期记忆让应用记住**单个线程（thread）内的过往交互**，最常见的形式是对话历史。
跨对话的需求应使用[长期记忆](/langchain/advanced#长期记忆)。

### 为何需要裁剪

长对话会超出上下文窗口；即使模型标称支持完整长度，
多数 LLM 在长上下文中表现仍会下降——陈旧内容分散注意力、增加延迟与成本。
因此需要有策略地删除或"遗忘"陈旧信息。

### 启用检查点

```python
from langchain.agents import create_agent
from langgraph.checkpoint.memory import InMemorySaver

agent = create_agent(
    model="openai:gpt-5.5",
    tools=[get_user_info],
    checkpointer=InMemorySaver(),
)
thread_config = {"configurable": {"thread_id": "1"}}

agent.invoke(
    {"messages": [{"role": "user", "content": "你好，我叫 Bob。"}]},
    thread_config,
)
agent.invoke({"messages": [{"role": "user", "content": "我叫什么？"}]}, thread_config)
```

状态由检查点保存器持久化：每步开始读取、结束更新。
**生产环境**使用数据库型保存器：

```python
from langgraph.checkpoint.postgres import PostgresSaver

DB_URI = "postgresql://postgres:postgres@localhost:5432/postgres"
with PostgresSaver.from_conn_string(DB_URI) as checkpointer:
    checkpointer.setup()   # 自动建表
    agent = create_agent("openai:gpt-5.5", tools=[...], checkpointer=checkpointer)
```

### 四种常见模式

**① 裁剪消息**——`@before_model` 中保留首条与最近若干条：

```python
from langchain.agents.middleware import before_model, AgentState
from langgraph.types import RemoveMessage, REMOVE_ALL_MESSAGES

@before_model
def trim_messages(state: AgentState, runtime) -> dict | None:
    messages = state["messages"]
    if len(messages) <= 3:
        return None
    recent = messages[-3:] if len(messages) % 2 == 0 else messages[-4:]
    return {"messages": [RemoveMessage(id=REMOVE_ALL_MESSAGES),
                         messages[0], *recent]}
```

**② 删除指定消息**：

```python
{"messages": [RemoveMessage(id=m.id) for m in messages[:2]]}
# 全部清除：[RemoveMessage(id=REMOVE_ALL_MESSAGES)]
```

**③ 摘要消息**——触发后由模型将旧历史压缩为摘要并**持久替换**状态：

```python
from langchain.agents.middleware import SummarizationMiddleware

SummarizationMiddleware(
    model="gpt-5.4-mini",
    trigger=("tokens", 4000),
    keep=("messages", 20),
)
```

**④ 自定义策略**——在 `@before_model` / `@after_model` 中实现任意逻辑。

### 裁剪的约束

直接删除会**丢失被移除内容中的信息**，更完整的做法是先摘要再替换。
此外必须保证剩余历史仍符合提供商要求：

- 部分提供商要求消息历史**以 `user` 消息开始**；
- 多数提供商要求含工具调用的 `assistant` 消息后**紧跟**对应的 `tool` 结果；
- `RemoveMessage` 要求状态键使用 `add_messages` 归约器（默认 `AgentState` 已提供）。

### 访问记忆的四个位置

| 位置 | 方式 |
| --- | --- |
| 工具 | 读 `runtime.state`，写 `Command(update={...})` |
| 提示词 | `@dynamic_prompt` |
| 模型调用前 | `@before_model` |
| 模型调用后 | `@after_model` |

## 2. 流式输出

LLM 存在明显延迟，在完整响应生成前逐步展示输出可显著提升体验。

::: tip 版本说明
新应用建议使用 LangChain v1.3 引入的**事件流类型化投影 API**：
为消息、状态值、工具调用与子图提供独立迭代器，无需按 `stream_mode` 分支处理。
:::

### 三种流模式

**① 智能体进度**（`updates`）——按步产出状态更新。
一次工具调用依次产生：LLM 节点 `AIMessage` → 工具节点 `ToolMessage` →
LLM 节点最终响应。

```python
for chunk in agent.stream({"messages": [...]}, stream_mode="updates"):
    print(chunk)
```

**② LLM 令牌**（`messages`）——打字机效果：

```python
for chunk in agent.stream(
    {"messages": [...]},
    stream_mode="messages",
    version="v2",
):
    if chunk["type"] == "messages":
        token, metadata = chunk["data"]
        print(token.text, end="", flush=True)
```

**③ 自定义更新**（`custom`）——从工具内部透传任意数据：

```python
from langgraph.config import get_stream_writer

@tool
def query_city(city: str) -> str:
    """查询城市数据。"""
    writer = get_stream_writer()
    writer(f"正在检索城市数据：{city}")
    ...
```

`get_stream_writer()` 自动绑定当前执行上下文，无需手动传递。
多模式组合用 `stream_mode=["updates", "custom"]` 并传 `version="v2"`，
每块是带 `type` / `ns` / `data` 的 `StreamPart`。

### 推理令牌与流式工具调用

推理内容以标准内容块返回，`type == "reasoning"`——
不同提供商称之为 `thinking` 或 `reasoning`，LangChain 统一为 `reasoning`：

```python
for message in stream.messages:
    for token in message.reasoning:
        print(f"[thinking] {token}", end="")
    for token in message.text:
        print(token, end="", flush=True)
```

工具调用本身也分多个令牌生成，需先**合并消息块**再读取完整参数：

```python
full_message = token if full_message is None else full_message + token
if token.chunk_position == "last":
    if full_message.tool_calls:
        ...
    full_message = None
```

### 子智能体与中断的流式

- 子智能体：为 `create_agent(name=...)` 命名，配合 `subgraphs=True`
  与元数据 `lc_agent_name` 过滤来源；
- 人在回路：从 `updates` 流中收集中断（`source == "__interrupt__"`），
  以 `Command(resume=decisions)` 恢复——**决策顺序必须与中断请求中的操作顺序一致**。

### 关键注意事项

- 依赖 `thread_id` 持久化历史时，智能体**必须**配置 checkpointer
  （LangSmith 部署自动提供，本地需显式传入）；
- 在 `StateGraph` 中调用 `create_agent` 返回的智能体，
  需设 `subgraphs=True` 才能获取子图输出；
- 并非所有集成都支持 `streaming` 参数，不支持时改用基类的 `disable_streaming=True`；
- 禁用流式：`init_chat_model(..., streaming=False)`。

## 3. 结构化输出

结构化输出让智能体以明确、可预测的格式返回数据，
应用无需解析自然语言即可直接消费 JSON 对象、Pydantic 模型或 dataclass。

### 基本用法

```python
from pydantic import BaseModel, Field

class ContactInfo(BaseModel):
    """人员联系信息。"""
    name: str = Field(description="姓名")
    email: str = Field(description="电子邮箱")
    phone: str = Field(description="电话号码")

agent = create_agent(model="openai:gpt-5.5", response_format=ContactInfo)
result = agent.invoke({"messages": [{"role": "user", "content":
    "从以下文本提取联系信息：John Doe, john@example.com, (555) 123-4567"}]})

print(result["structured_response"])
# ContactInfo(name='John Doe', email='john@example.com', phone='(555) 123-4567')
```

结果写入智能体最终状态的 `structured_response` 字段。

### 两种策略

| 策略 | 说明 |
| --- | --- |
| `ProviderStrategy(schema, strict=None)` | 提供商原生约束与校验，可靠性最高 |
| `ToolStrategy(schema, ...)` | 借助工具调用，支持 Pydantic / dataclass / TypedDict / JSON Schema / **联合类型** |

自动选择规则：OpenAI、Anthropic、xAI 等支持原生实现的使用提供商策略，
其余支持工具调用的使用工具策略；模型不支持时自动回退。
若模型同时配置了工具，需确保其**支持并行使用**工具调用与结构化输出。

```python
from langchain.agents.structured_output import ProviderStrategy, ToolStrategy

response_format=ProviderStrategy(contact_info_schema)   # JSON Schema 字典必须显式包装
response_format=ToolStrategy(Union[ProductReview, CustomerComplaint])
```

::: warning 易错点
JSON Schema 字典**必须**显式包装为 `ProviderStrategy` 或 `ToolStrategy`，
直接传给 `response_format` 不会被自动识别；
且字典必须含顶层 `title` 与 `description`。
:::

返回值类型差异：Pydantic 返回已校验实例；
dataclass / TypedDict / JSON Schema 返回字典。

### 错误处理与重试

校验错误会通过 `ToolMessage` 反馈给模型，由其自行修正：
例如 `rating: 10` 超出 `le=5` 触发校验错误，重试后返回 5。
`handle_errors` 提供六种取值：

```python
ToolStrategy(schema=ProductRating,
             handle_errors="请提供 1-5 之间的有效评分并附带评论。")
ToolStrategy(schema=ProductRating, handle_errors=ValueError)          # 特定异常
ToolStrategy(schema=ProductRating, handle_errors=(ValueError, TypeError))
ToolStrategy(schema=..., handle_errors=custom_error_handler)          # 回调
ToolStrategy(schema=ProductRating, handle_errors=False)               # 直接抛出
```

`tool_message_content` 可自定义写入对话历史的提示语：

```python
ToolStrategy(schema=MeetingAction,
             tool_message_content="行动项已记录并写入会议纪要！")
```

## 4. 小结

| 能力 | 机制 | 关键点 |
| --- | --- | --- |
| 短期记忆 | checkpointer + `AgentState` | 裁剪会丢信息，摘要更完整；须满足提供商历史约束 |
| 流式 | `updates` / `messages` / `custom` | 完整消息需累加；子智能体要 `subgraphs=True` |
| 结构化输出 | `response_format` | 结果在 `structured_response`；JSON Schema 需显式包装 |

下一篇：[中间件与运行时](/langchain/middleware-runtime)。
