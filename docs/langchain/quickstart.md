# 快速入门

本篇依照官方"快速入门"梳理一遍，并标注实践中的易错点。
目标：从零完成一个具备工具调用、结构化输出与观测能力的智能体。

## 0. 环境准备

```bash
pip install -qU langchain "langchain[openai]"
```

安装 `langchain` 后按所选提供商补充对应 extra（`langchain[anthropic]`、
`langchain[deepseek]` 等），或使用 OpenAI 兼容接口。

凭据通过环境变量注入，**不要硬编码进源码**：

```bash
export OPENAI_API_KEY="sk-..."
# 追踪与评估（可选）
export LANGSMITH_API_KEY="lsv2_..."
export LANGSMITH_TRACING=true
```

## 1. 构建基础智能体

```python
from langchain.agents import create_agent

def get_weather(city: str) -> str:
    """获取指定城市的天气。"""
    return f"{city} 总是阳光明媚！"

agent = create_agent(
    model="openai:gpt-5.5",
    tools=[get_weather],
    system_prompt="你是一名乐于助人的助手",
)

result = agent.invoke(
    {"messages": [{"role": "user", "content": "旧金山的天气怎么样？"}]}
)
print(result["messages"][-1].content_blocks)
```

::: warning 返回值结构
返回值是包含 `messages` 列表的状态字典，而非字符串。
获取最终回答须使用 `result["messages"][-1].content`。
直接输出整个返回值会显示一串 AIMessage / ToolMessage，易被误判为异常。
:::

工具即普通 Python 函数，**docstring 会成为工具描述传入模型**——
该字符串的读者是模型而非开发者。参数类型注解同理，模型依赖它生成合法入参。

## 2. 配置模型参数

需要调整温度等参数时，使用 `init_chat_model` 得到模型实例再传入：

```python
from langchain.chat_models import init_chat_model

model = init_chat_model("openai:gpt-5.5", temperature=0)
agent = create_agent(model=model, tools=[get_weather])
```

## 3. 结构化输出

定义目标 Schema 并通过 `response_format` 指定，结果写入状态的
`structured_response` 字段：

```python
from pydantic import BaseModel, Field

class WeatherReport(BaseModel):
    """天气查询结果。"""
    city: str = Field(description="城市名称")
    summary: str = Field(description="一句话天气概括")

agent = create_agent(
    model="openai:gpt-5.5",
    tools=[get_weather],
    response_format=WeatherReport,
    system_prompt="你是一名乐于助人的助手",
)

result = agent.invoke(
    {"messages": [{"role": "user", "content": "旧金山的天气怎么样？"}]}
)
print(result["structured_response"])
```

模型原生支持结构化输出时自动采用提供商策略，否则回退到工具调用策略。
**若自行传入 JSON Schema 字典，必须显式包装**为 `ProviderStrategy(...)`
或 `ToolStrategy(...)`，否则不会被自动识别。

## 4. 流式输出

LLM 存在明显延迟，逐步呈现输出可显著改善体验：

```python
for chunk in agent.stream(
    {"messages": [{"role": "user", "content": "旧金山的天气怎么样？"}]},
    stream_mode="messages",
):
    if chunk["type"] == "messages":
        token, metadata = chunk["data"]
        print(token.text, end="", flush=True)
```

三种常用 `stream_mode`：

| 模式 | 产出 | 用途 |
| --- | --- | --- |
| `updates` | 每步状态更新 | 观察智能体进度 |
| `messages` | `(token, metadata)` 元组 | 打字机式逐字输出 |
| `custom` | 自定义数据 | 透传工具内部的中间结果 |

## 5. 在 LangSmith 中观测

启用 `LANGSMITH_TRACING=true` 后，每次运行会记录完整追踪：
模型调用、工具入参出参、状态转换与耗时均可见。

排查问题的顺序建议：先看**智能体决定调用哪个工具**是否正确，
再看**工具返回内容**是否足以支撑回答，最后才调整提示词。
过早调整提示词而忽略追踪记录，是常见的无效调试方式。

## 6. 易错点小结

1. 忘记在 `agent.invoke` 中传 `thread_id`，导致对话历史不保留；
2. 依赖 `InMemorySaver` 上线——生产必须使用数据库型检查点保存器；
3. 工具名含空格或大写（应使用 `snake_case`），部分提供商直接拒绝该请求；
4. 将工具执行错误直接抛出而非转为 `ToolMessage`，智能体循环因此中断；
5. 用 `respond` 决策去"拒绝"带副作用的工具——该消息会被当作成功结果。

## 下一步

- 完整概念体系：[智能体与运行框架](/langchain/agents)
- 三大基础组件：[模型·消息·工具](/langchain/components)
- 从原型到生产：[上下文工程与高级能力](/langchain/advanced)
