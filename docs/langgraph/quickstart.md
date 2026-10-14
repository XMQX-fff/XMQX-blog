# 快速上手：跑通第一个 Agent

这一篇完全照着官方"快速入门"走一遍，顺便把我当时卡住的地方标出来。
目标：从零到一个能查天气、带记忆、能输出结构化结果的 Agent。

## 0. 环境

```bash
pip install -U langgraph "langchain[anthropic]"
```

`langchain` 是为了让 Agent 能方便地调模型，装哪个 provider 的 extra 看你自己。
官方示例用的是 Anthropic，你换成 OpenAI / DeepSeek / 任何 OpenAI 兼容接口都行。

## 1. 十行代码起一个 Agent

```python
from langgraph.prebuilt import create_react_agent

def get_weather(city: str) -> str:
    """Get weather for a given city."""
    return f"It's always sunny in {city}!"

agent = create_react_agent(
    model="anthropic:claude-3-7-sonnet-latest",  # 模型
    tools=[get_weather],                          # 工具
    prompt="You are a helpful assistant",          # 系统提示
)

result = agent.invoke(
    {"messages": [{"role": "user", "content": "what is the weather in sf"}]}
)
print(result["messages"][-1].content)
```

就这些。`create_react_agent` 是**预构建组件**，它替你把一张图搭好了：
模型节点 ↔ 工具节点，中间用条件边连成循环，直到模型不再调工具为止。

::: warning 我踩的第一个坑
返回值是 `{"messages": [...]}`，不是字符串。
要拿最终回答得 `result["messages"][-1].content`。
我第一次直接 print 整个 result，屏幕上一大坨 AIMessage/ToolMessage，还以为出 bug 了。
:::

工具就是普通 Python 函数，**docstring 会被当成工具描述传给模型**——
所以那个 `"""Get weather for a given city."""` 不是写给自己看的，是写给模型看的。
参数类型注解也一样重要，模型靠它生成合法入参。

## 2. 配置模型参数

要调温度之类的，用 `init_chat_model`：

```python
from langchain.chat_models import init_chat_model

model = init_chat_model(
    "anthropic:claude-3-7-sonnet-latest",
    temperature=0,
)
agent = create_react_agent(model=model, tools=[get_weather])
```

## 3. 提示词：静态 vs 动态

**静态**：一个字符串，被当成系统消息，永远不变。

```python
agent = create_react_agent(
    model=model,
    tools=[get_weather],
    prompt="Never answer questions about the weather.",
)
```

**动态**：一个函数，每次调用时根据状态和配置现算。这是更常用的形态——
想根据 `user_id` 换称呼、想把当前会话的某些状态塞进提示词，都靠它。

```python
from langchain_core.messages import AnyMessage
from langchain_core.runnables import RunnableConfig
from langgraph.prebuilt.chat_agent_executor import AgentState

def prompt(state: AgentState, config: RunnableConfig) -> list[AnyMessage]:
    user_name = config["configurable"].get("user_name")
    system_msg = f"You are a helpful assistant. Address the user as {user_name}."
    return [{"role": "system", "content": system_msg}] + state["messages"]

agent = create_react_agent(model=model, tools=[get_weather], prompt=prompt)

agent.invoke(
    {"messages": [{"role": "user", "content": "hi"}]},
    config={"configurable": {"user_name": "John Smith"}},
)
```

注意 `config["configurable"]` 这个路径，后面会反复出现：
**运行时传进去的自定义参数都放这儿**。

## 4. 加记忆（多轮对话）

没有 checkpointer 的 Agent 是金鱼记忆——每次 invoke 都是全新的一次。
要多轮，就得挂一个：

```python
from langgraph.checkpoint.memory import InMemorySaver

checkpointer = InMemorySaver()

agent = create_react_agent(
    model=model,
    tools=[get_weather],
    checkpointer=checkpointer,
)

config = {"configurable": {"thread_id": "1"}}

agent.invoke(
    {"messages": [{"role": "user", "content": "what is the weather in sf"}]},
    config,
)
# 第二次用同一个 config，它记得上一轮
agent.invoke(
    {"messages": [{"role": "user", "content": "what about new york?"}]},
    config,
)
```

两个要点：

1. **`thread_id` 是对话的唯一标识**。同一个 id 就是同一场对话，换 id 就是新对话。
2. checkpointer 会在**每一步**都存一份状态快照，这就是后面人机协作、时间旅行、断点恢复的地基。

`InMemorySaver` 只存内存，重启就没了。生产环境换 SQLite / Postgres（后面[持久化与记忆](/langgraph/persistence-memory)细讲）。

## 5. 结构化输出

很多时候你要的不是一段话，而是一个能直接喂给下游代码的对象：

```python
from pydantic import BaseModel

class WeatherResponse(BaseModel):
    conditions: str

agent = create_react_agent(
    model=model,
    tools=[get_weather],
    response_format=WeatherResponse,
)

resp = agent.invoke({"messages": [{"role": "user", "content": "weather in sf"}]})
print(resp["structured_response"])
```

结果挂在 `structured_response` 字段上，不是 `messages`。

::: caution 一个隐藏成本
传了 `response_format` 之后，Agent 循环跑完**还会额外再调一次模型**，
把整个对话历史按 schema 格式化一遍。等于多一次 LLM 调用，延迟和钱都要算进去。
官方文档专门标了"LLM 后处理"这个提示，别到上线才发现账单翻倍。
:::

想给这次额外调用加系统提示，用元组：`response_format=(prompt, WeatherResponse)`。

## 6. 到这里你已经会了

回顾一下，五件事：

```text
create_react_agent(model, tools, prompt)   ← 起 Agent
init_chat_model(...)                        ← 调模型参数
prompt(state, config) -> messages           ← 动态提示词
checkpointer + thread_id                    ← 多轮记忆
response_format=PydanticModel               ← 结构化输出
```

这套是"预构建"路线，快，但形状是固定的（模型↔工具循环）。
真要自己画流程图，得往下走——下一篇 [图 API 三件套](/langgraph/graph-api)。

## 下一步

- 想跑官方的六课时入门系列（聊天机器人 → 加工具 → 加记忆 → 人工干预 → 自定义状态 → 时间旅行），
  见 [LangGraph 基础教程](https://langgraph.com.cn/concepts/why-langgraph.1.html)。
- 本栏目继续：[图 API 三件套](/langgraph/graph-api)。
