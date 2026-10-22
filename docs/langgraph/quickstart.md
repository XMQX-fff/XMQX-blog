# 快速上手：构建第一个智能体

本篇依照官方"快速入门"梳理一遍，并标注实践中的易错点。
目标：从零完成一个具备工具调用、记忆与结构化输出能力的智能体。

## 0. 环境准备

```bash
pip install -U langgraph "langchain[anthropic]"
```

安装 `langchain` 是为了便于调用模型，具体 provider 的 extra 按实际需要选择。
官方示例使用 Anthropic，替换为 OpenAI、DeepSeek 或任意 OpenAI 兼容接口均可。

## 1. 十行代码构建智能体

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

`create_react_agent` 属于**预构建组件**，内部已完成图的搭建：
模型节点与工具节点之间以条件边相连，形成循环，直至模型不再发起工具调用。

::: warning 返回值结构
返回值是一个 `{"messages": [...]}` 字典。
获取最终回答须使用 `result["messages"][-1].content`。
直接输出整个返回值会显示一串 AIMessage / ToolMessage，易被误判为异常。
:::

工具即普通 Python 函数，**docstring 会作为工具描述传入模型**——
因此该字符串的读者是模型，开发者看它意义不大。参数类型注解同理，模型依赖它生成合法入参。

## 2. 配置模型参数

需要调整温度等参数时，使用 `init_chat_model`：

```python
from langchain.chat_models import init_chat_model

model = init_chat_model(
    "anthropic:claude-3-7-sonnet-latest",
    temperature=0,
)
agent = create_react_agent(model=model, tools=[get_weather])
```

## 3. 提示词：静态与动态

**静态**：字符串形式，作为系统消息，内容固定不变。

```python
agent = create_react_agent(
    model=model,
    tools=[get_weather],
    prompt="Never answer questions about the weather.",
)
```

**动态**：函数形式，每次调用时依据状态与配置实时生成。实践中以动态为主——
按 `user_id` 切换称呼、将当前会话的特定状态注入提示词，均依赖该机制。

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

注意 `config["configurable"]` 这一路径，后文会反复出现：
**运行时传入的自定义参数统一存放于此**。

## 4. 添加记忆（多轮对话）

未配置 checkpointer 的智能体不具备跨调用记忆——每次 `invoke` 均为独立执行。
多轮对话必须挂载检查点器：

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
# 第二次使用相同 config，上下文得以延续
agent.invoke(
    {"messages": [{"role": "user", "content": "what about new york?"}]},
    config,
)
```

两个要点：

1. **`thread_id` 是对话的唯一标识**。相同 id 对应同一场对话，更换 id 即开启新对话。
2. checkpointer 会在**每一步**保存状态快照，此为后续人机协作、时间旅行与断点恢复的基础。

`InMemorySaver` 仅存于内存，进程重启即失效；生产环境应改用 SQLite 或 Postgres，
详见[持久化与记忆](/langgraph/persistence-memory)。

## 5. 结构化输出

许多场景需要的是可直接供下游代码使用的对象：

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

结果放在 `structured_response` 字段里（`messages` 里没有）。

::: caution 隐含成本
指定 `response_format` 后，智能体循环结束时会**额外调用一次模型**，
将完整对话历史按 schema 格式化。相当于多一次 LLM 调用，
延迟与费用均需计入。官方文档就此标注了"LLM 后处理"提示，应在上线前评估。
:::

若需为该次额外调用附加系统提示，可使用元组形式：`response_format=(prompt, WeatherResponse)`。

## 6. 小结

至此涉及的能力可归纳为五项：

```text
create_react_agent(model, tools, prompt)   ← 构建智能体
init_chat_model(...)                        ← 配置模型参数
prompt(state, config) -> messages           ← 动态提示词
checkpointer + thread_id                    ← 多轮记忆
response_format=PydanticModel               ← 结构化输出
```

以上属于"预构建"路线：效率高，但形态固定（模型与工具之间的循环）。
如需自行绘制流程，则须深入下一层——下一篇[图 API 三要素](/langgraph/graph-api)。

## 下一步

- 官方六课时入门系列（聊天机器人 → 加工具 → 加记忆 → 人工干预 → 自定义状态 → 时间旅行），
  参见 [LangGraph 基础教程](https://langgraph.com.cn/concepts/why-langgraph.1.html)。
- 本栏目继续：[图 API 三要素](/langgraph/graph-api)。
