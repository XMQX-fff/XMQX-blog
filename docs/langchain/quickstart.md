# 快速入门

本篇依照官方"快速入门"梳理一遍，并标注实践中的易错点。
目标：从零完成一个具备工具调用、结构化输出与观测能力的智能体。

## 怎么读本篇

- 目标是**层次完整、能跑通**：每节要么给出可直接运行的脚本，要么明确标出需要你自己补的部分；
- 每段代码后面附**预期输出**，方便对照"我跑出来的对不对"；
- 涉及模型生成的文字标注"（示意）"——措辞会变，看结构和类型。

## 0. 环境准备

```bash
pip install -qU langchain "langchain[openai]"
```

方括号里的 `extra` 是**按需安装的提供商依赖**：用 Anthropic 就装
`langchain[anthropic]`，用 DeepSeek 就 `langchain[deepseek]`（完整列表见
[集成页](https://langchain-doc.cn/v1/python/integrations/providers/overview)）。
默认安装的 `langchain` 本身不绑定任何一家 SDK。

凭据通过环境变量注入，**不要硬编码进源码**（提交进 git 就等于泄露）：

```bash
export OPENAI_API_KEY="sk-..."
# 追踪与评估（可选）
export LANGSMITH_API_KEY="lsv2_..."
export LANGSMITH_TRACING=true
```

**名词解释：LangSmith API Key 前缀。** LangSmith 的密钥以 `lsv2_` 开头
（早期为 `ls__` 开头，控制台里两种可能都看得到，新建的是 `lsv2_`）。
填错不会立刻报错，但追踪静默丢失——排查时先看密钥前缀。

## 1. 构建基础智能体

下面是一个**可以直接运行**的完整脚本，逐行注释了：

```python
from langchain.agents import create_agent


def get_weather(city: str) -> str:
    """获取指定城市的天气。"""
    return f"{city} 总是阳光明媚！"


# 三项输入即完整智能体：
#   ① model     模型标识符字符串或模型实例
#   ② tools     普通函数列表，docstring 会成为模型看的工具描述
#   ③ system_prompt  系统提示词，塑造行为
agent = create_agent(
    model="openai:gpt-5.5",
    tools=[get_weather],
    system_prompt="你是一名乐于助人的助手",
)

result = agent.invoke(
    {"messages": [{"role": "user", "content": "旧金山的天气怎么样？"}]}
)

# 返回值是包含 messages 列表的状态字典，不是字符串
print(type(result))                     # <class 'dict'>
print(result["messages"][-1].text)      # （示意）旧金山总是阳光明媚！
print(result["messages"][-1].content_blocks)
# [{'type': 'text', 'text': '旧金山总是阳光明媚！（示意）', 'id': ...}]
```

**名词解释：`agent.invoke` 的入参。** 它接收的是**对状态的更新**，
与"用户说的话"是两回事。`{"messages": [...]}` 表示往智能体状态的
`messages` 键里追加消息——智能体的状态天生带 `messages` 列表（由
`add_messages` 归约器管理，语义详见[智能体与运行框架](/langchain/agents)）。
你可以顺便传自定义状态字段的初始值，例如 `{"messages": [...], "user_id": "u1"}`。

::: warning 返回值结构
返回值是包含 `messages` 列表的状态字典。
获取最终回答须使用 `result["messages"][-1].text`。
直接输出整个返回值会显示一串 AIMessage / ToolMessage，易被误判为异常。
:::

工具即普通 Python 函数，**docstring 会成为工具描述传入模型**——
该字符串的读者是模型。参数类型注解同理，模型依赖它生成合法入参。
更多工具细节见[模型·消息·工具](/langchain/components)。

## 2. 配置模型参数

需要调整温度等参数时，字符串标识符不够用了——先造模型实例再传入：

```python
from langchain.agents import create_agent
from langchain.chat_models import init_chat_model

model = init_chat_model("openai:gpt-5.5", temperature=0, timeout=300)

agent = create_agent(model=model, tools=[get_weather])
result = agent.invoke({"messages": [{"role": "user", "content": "你好"}]})
print(result["messages"][-1].text)  # （示意）你好！有什么可以帮你？
```

**什么时候需要这一步：** 调 `temperature` / `max_tokens` / `timeout` 等参数、
设 `base_url` 走自建网关、禁用流式、启用推理模型的专项配置。
只用默认行为时，字符串足矣。

## 3. 结构化输出

定义目标 Schema 并通过 `response_format` 指定，结果写入状态的
`structured_response` 字段：

```python
from pydantic import BaseModel, Field

from langchain.agents import create_agent


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
# WeatherReport(city='San Francisco', summary='旧金山总是阳光明媚，气候稳定的城市。（示意）')
```

**名词解释：`structured_response`。** 智能体最终状态里的一个**额外字段**。
对话在 `messages` 里，结构化结果单独放在这里，是**已校验的 Pydantic 实例**，
下游代码 `result["structured_response"].city` 直接取字段，不用解析自然语言。

模型原生支持结构化输出时自动采用提供商策略，否则回退到工具调用策略。
**若自行传入 JSON Schema 字典，必须显式包装**为 `ProviderStrategy(...)`
或 `ToolStrategy(...)`，否则不会被自动识别。两种策略的取舍与
`handle_errors` 重试机制的完整说明见
[记忆·流式·结构化输出](/langchain/context-output#3-结构化输出)。

## 4. 流式输出

LLM 存在明显延迟（一次完整回答可能几秒到几十秒），逐步呈现输出可显著改善体验：

```python
for chunk in agent.stream(
    {"messages": [{"role": "user", "content": "旧金山的天气怎么样？"}]},
    stream_mode="messages",
    version="v2",
):
    if chunk["type"] == "messages":
        token, metadata = chunk["data"]
        print(token.text, end="", flush=True)
```

预期输出（示意，逐段打印拼出一句话）：

```text
旧金山总是阳光明媚！
```

**名词解释：`version="v2"`。** 流式输出的**格式版本**，需要 LangGraph 1.1+。
- v2（推荐）：统一的数据块格式 `StreamPart`，用 `chunk["type"]` 和
  `chunk["data"]` 取值，单模式/多模式长得一样；
- v1（缺省默认）：直接产出裸数据，多模式时是 `(mode, data)` 元组——
  此时上面这段 `chunk["type"]` 取值的代码会直接 `TypeError`，
  **这是最容易踩的坑**。

三种常用 `stream_mode`：

| 模式 | 产出 | 用途 |
| --- | --- | --- |
| `updates` | 每步状态更新 | 观察智能体进度（哪个节点跑完了） |
| `messages` | `(token, metadata)` 元组 | 打字机式逐字输出 |
| `custom` | 自定义数据 | 透传工具内部的中间结果 |

## 5. 在 LangSmith 中观测

启用 `LANGSMITH_TRACING=true` 后，每次运行会记录完整追踪：
模型调用、工具入参出参、状态转换与耗时均可见，在
[smith.langchain.com](https://smith.langchain.com) 查看。

排查问题的顺序建议：先看**智能体决定调用哪个工具**是否正确，
再看**工具返回内容**是否足以支撑回答，最后才调整提示词。
过早调整提示词而忽略追踪记录，是常见的无效调试方式——追踪里能看到
模型收到的完整提示词和它的原始输出，比猜要准得多。

## 6. 易错点小结

下面每条都是实践里高频出现的问题，按出现频率大致排序：

1. **忘记传 `thread_id`，对话历史不保留。** 没配 checkpointer 或没传
   `thread_id` 时，每次 `invoke` 都是独立执行，上一轮说了什么它根本不知道。
2. **依赖 `InMemorySaver` 上线。** 它只存在内存里，进程一重启全部丢失。
   生产必须用数据库型检查点保存器（`PostgresSaver` / `MongoDBSaver` 等）。
3. **工具名含空格或大写。** 应使用 `snake_case`（`web_search`），
   部分提供商直接拒绝该请求。
4. **把工具执行错误直接抛出。** 异常炸穿整个循环，智能体没有自愈机会；
   应转成 `ToolMessage` 让模型看到失败原因并修正（写法见
   [components.md 3.5 节](/langchain/components#3-5-错误处理把异常变成模型能读的反馈)）。
5. **用 `respond` 决策"拒绝"带副作用的工具。** 人工审核里的 `respond`
   是"人工代替工具作答"的机制，用它来拒绝会让模型认为工具**成功执行了**。
   拒绝请用 `reject`（详见[上下文工程与高级能力](/langchain/advanced)）。
6. **以为 `invoke` 返回字符串。** 返回的是状态字典；文本在
   `result["messages"][-1].text`，结构化结果在 `result["structured_response"]`。

## 下一步

- 完整概念体系：[智能体与运行框架](/langchain/agents)
- 三大基础组件：[模型·消息·工具](/langchain/components)
- 从原型到生产：[上下文工程与高级能力](/langchain/advanced)
