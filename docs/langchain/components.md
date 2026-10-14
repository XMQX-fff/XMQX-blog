# 模型 · 消息 · 工具

三者是智能体的基础：消息是数据单元，模型是推理引擎，工具是行动能力。
本篇对应官方文档的核心组件部分。

## 1. 模型

### 统一初始化

```python
from langchain.chat_models import init_chat_model

model = init_chat_model("openai:gpt-5.5")
model = init_chat_model("anthropic:claude-sonnet-4-6", temperature=0)
```

`"provider:model"` 标识符是切换提供商的唯一改动点。
对 OpenAI 兼容接口，可通过 `base_url` 指向自建网关。

### 统一接口

```python
response = model.invoke([system_msg, human_msg])   # 返回 AIMessage
```

`invoke` / `stream` / `batch` 与异步对应方法在所有提供商上行为一致。
模型能力（上下文长度、推理支持、多模态）差异由集成层消化，
可在 models.dev 查询具体能力。

### 与智能体的关系

`create_agent` 接受字符串或模型实例。需要精细控制
（自定义参数、禁用流式、指定配置资料）时，先经 `init_chat_model`
构造实例再传入：

```python
model = init_chat_model("openai:gpt-5.5", streaming=False)
agent = create_agent(model=model, tools=[...])
```

## 2. 消息

消息是模型上下文的基本单元，由角色、内容、元数据三部分组成。
LangChain 提供跨所有提供商的标准消息类型，确保行为一致。

### 四种消息类型

| 类型 | 作用 |
| --- | --- |
| `SystemMessage` | 设定语气、角色与响应准则 |
| `HumanMessage` | 用户输入，支持多模态 |
| `AIMessage` | 模型输出，含工具调用与用量元数据 |
| `ToolMessage` | 工具执行结果回传 |

```python
from langchain.chat_models import init_chat_model
from langchain.messages import SystemMessage, HumanMessage

model = init_chat_model("openai:gpt-5.5")
response = model.invoke([
    SystemMessage("你是一名乐于助人的助手。"),
    HumanMessage("你好，最近怎么样？"),
])
```

三种传入方式：**字符串**（单次独立请求）、**消息对象列表**（多轮、多模态、
含系统指令）、**Chat Completions 字典格式**（便于直接迁移既有代码）。

### AIMessage 的关键属性

```python
response.text               # 纯文本
response.content            # 弱类型内容（字符串或内容块列表）
response.content_blocks     # 类型安全的标准内容块
response.tool_calls         # 工具调用列表
response.usage_metadata     # token 用量
response.response_metadata  # 提供商原始元数据
```

`usage_metadata` 形如：

```python
{'input_tokens': 8, 'output_tokens': 304, 'total_tokens': 312,
 'input_token_details': {'audio': 0, 'cache_read': 0},
 'output_token_details': {'audio': 0, 'reasoning': 256}}
```

### 标准内容块（content_blocks）

v1 的关键设计：`content` 保持弱类型以兼容各提供商，`content_blocks`
则提供延迟解析的类型安全视图，并**将 Anthropic 的 `thinking` 与
OpenAI 的 `reasoning` 统一为 `ReasoningContentBlock`**。

核心类型包括：

- 文本：`TextContentBlock`、`ReasoningContentBlock`；
- 多模态：`Image` / `Audio` / `Video` / `File` / `PlainTextContentBlock`；
- 工具调用：`ToolCall`、`ToolCallChunk`、`InvalidToolCall`；
- 服务端工具：`ServerToolCall` / `Chunk` / `Result`；
- 提供商扩展：`NonStandardContentBlock`。

::: note 向后兼容
`content_blocks` 是 v1 的**新增属性**，不是 `content` 的替代品。
指定 `content_blocks` 初始化消息时，`content` 仍会被同步填充。
:::

### 工具调用消息

```python
model_with_tools = model.bind_tools([get_weather])
response = model_with_tools.invoke("巴黎的天气怎么样？")

for tool_call in response.tool_calls:
    print(tool_call["name"], tool_call["args"], tool_call["id"])

tool_message = ToolMessage(content=result_str, tool_call_id=tool_call["id"])
```

`ToolMessage.tool_call_id` **必须与调用 ID 匹配**，否则校验失败。
`ToolMessage.artifact` 用于存放**不发送给模型**但程序可读的补充数据
（文档 ID、调试信息）。

### 多模态与序列化

```python
HumanMessage(content_blocks=[
    {"type": "text", "text": "描述这张图"},
    {"type": "image", "url": "https://example.com/image.jpg"},
])
```

图像、PDF、音频、视频的来源可为 URL、base64 或提供商托管的 `file_id`；
使用 base64 时 `mime_type` 必填。

持久化使用 `dumpd()` / `load()`（`langchain_core.load`）。

::: danger 安全警告
`load()` 会实例化 Python 对象并可能触发副作用，
**切勿对来自不可信或未经身份验证来源的数据调用 `load()`**。
:::

## 3. 工具

工具是具有明确定义输入输出的可调用函数。
传给聊天模型后，模型根据上下文决定何时调用及传何参数。

### 基本定义

```python
from langchain.tools import tool

@tool
def search_database(query: str, limit: int = 10) -> str:
    """在客户数据库中搜索与查询匹配的记录。

    Args:
        query: 检索关键词
        limit: 返回结果上限
    """
    return f"为 '{query}' 找到 {limit} 条结果"
```

- **类型提示是必需的**，它构成输入 Schema；
- docstring 成为工具描述；
- 可用 `@tool("web_search")` 覆盖名称，`@tool(description="...")` 覆盖说明；
- 复杂输入用 `args_schema=SomePydanticModel` 或 JSON Schema 字典。

::: warning 命名约定
工具名应使用 **`snake_case`**（如 `web_search`）。
部分提供商无法处理含空格或特殊字符的名称，会直接报错拒绝。
:::

::: warning 保留参数名
`config`（保留给 `RunnableConfig`）与 `runtime`（保留给 `ToolRuntime`）
不得用作工具参数，否则运行时报错。
:::

### ToolRuntime：访问运行时

```python
from langchain.tools import tool, ToolRuntime
from langgraph.types import Command

@tool
def set_user_name(new_name: str, runtime: ToolRuntime[None, CustomState]) -> Command:
    """设置用户名称。"""
    return Command(update={
        "user_name": new_name,
        "messages": [ToolMessage(
            content=f"用户名称已设置为 {new_name}。",
            tool_call_id=runtime.tool_call_id,
        )],
    })
```

`ToolRuntime` 提供八类信息：状态（短期记忆）、上下文（不可变配置）、
存储（长期记忆）、流写入器、执行信息、服务器信息、配置、工具调用 ID。
`runtime` 参数对模型隐藏，不会出现在工具 Schema 中。

旧版的 `InjectedState` / `InjectedStore` / `get_runtime()` /
`InjectedToolCallId` 已统一由 `ToolRuntime` 取代。

### 返回值的四种形态

| 返回值 | 用途 |
| --- | --- |
| 字符串 | 人类可读的结果 |
| 对象 / `dict` | 结构化数据，供模型推理 |
| 内容块列表 | 多模态结果 |
| `Command` | 同时更新图状态 |

`@tool(return_direct=True)` 可让该工具的结果**短路智能体循环**，
不再返回给模型。注意：结果需进一步推理、总结或与其他调用串联时
不应使用；并行调用中只有**整批**都设置为 `True` 才会短路。

### 错误处理

```python
from langchain.agents.middleware import wrap_tool_call

@wrap_tool_call
def handle_tool_errors(request, handler):
    try:
        return handler(request)
    except Exception as e:
        return ToolMessage(
            content=f"工具错误：请检查输入后重试。（{e}）",
            tool_call_id=request.tool_call["id"],
        )
```

把异常转为 `ToolMessage` 而非直接抛出，模型即可自行修正重试。

### 动态工具选择

工具过多会造成上下文过载，两种收敛方式：

1. **筛选预注册工具**：`@wrap_model_call` 中以 `request.override(tools=...)`
   按状态、存储或上下文过滤；
2. **运行时注册工具**：需**同时**实现 `wrap_model_call` 与 `wrap_tool_call`，
   否则智能体不知道如何执行新注册的工具。

### MCP 与无头工具

```python
async with MCPAdapter("https://example.com/mcp") as adapter:
    tools = await adapter.list_tools()
    agent = create_agent("openai:gpt-5.5", tools)
```

`MCPAdapter` 将 MCP 服务器工具适配为 LangChain 工具
（需 `langchain[mcp]>=1.4.0`，目前为 Beta）。
无头工具（HeadlessTool）将 Schema 留在服务端、执行留在客户端，
Python 端只提供 name / description / args_schema。

## 4. 三者的协作

```text
HumanMessage ──▶ 模型推理 ──▶ AIMessage.tool_calls
                                    │
                                    ▼
                              执行 @tool 函数
                                    │
                                    ▼
                        ToolMessage(tool_call_id=...) ──▶ 模型继续推理
```

## 5. 小结

- 模型经 `init_chat_model` 统一初始化，字符串标识即可切换提供商。
- 四类消息 + 标准内容块，统一了各提供商的输出表达。
- 工具即带类型提示的函数，`ToolRuntime` 承担依赖注入。
- 工具错误转为 `ToolMessage`，动态裁剪工具集以控制上下文。

下一篇：[记忆 · 流式 · 结构化输出](/langchain/context-output)。
