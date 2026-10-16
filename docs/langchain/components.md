# 模型 · 消息 · 工具

三者是智能体的基础：**消息**是数据单元，**模型**是推理引擎，**工具**是行动能力。
本篇对应官方文档的核心组件部分。

## 怎么读本篇

- 每个代码块都尽量写成**可以直接运行的完整脚本**（需要 API 密钥的地方会注明）；
  确实需要省略时会用 `...` 标出，并说明省略的是什么。
- 代码后面附**预期输出**。涉及模型生成的文字会标注"（示意）"——
  具体措辞随模型和版本变化，重点看**结构和类型**对不对。
- 名词第一次出现时会用"名词解释"小框说明，不再默认读者已经懂。

> 本篇所有例子围绕同一个场景：一个能查天气的智能体。
> 建议按顺序读到最后，三者如何协作一节会把整条链路串起来。

## 1. 模型

### 1.1 为什么不能直接调 OpenAI SDK

不同提供商的 API 长得不一样：OpenAI 用 `client.chat.completions.create`，
Anthropic 又是另一套参数和返回结构。如果业务代码里到处是这种调用，
换一家模型提供商就得逐处改写。

LangChain 的做法是提供一层**统一封装**：所有提供商都被包成行为一致的
"聊天模型"对象，都有同样的 `invoke` / `stream` / `batch` 方法。
`init_chat_model` 就是创建这种对象的**工厂函数**——传一个字符串进去，
返回一个统一接口的模型实例：

```python
from langchain.chat_models import init_chat_model

model = init_chat_model("openai:gpt-5.5", temperature=0)
```

**名词解释：`"provider:model"` 标识符字符串。**
冒号左边是提供商（`openai`、`anthropic`、`google_genai`、`deepseek`...），
右边是模型名。这是切换提供商的**唯一改动点**：改这个字符串 + 设置对应的
API 密钥，其余代码一行不用动。

### 1.2 完整例子：第一次调用

```bash
# 环境变量注入凭据，不要硬编码进源码
export OPENAI_API_KEY="sk-..."
```

```python
from langchain.chat_models import init_chat_model

model = init_chat_model("openai:gpt-5.5", temperature=0)

resp = model.invoke("用一句话向程序员解释什么是 RAG。")
print(type(resp))          # 返回的是消息对象，不是字符串
print(resp.text)           # （示意）RAG 就是让大模型先检索资料、再基于资料作答的技术。
print(resp.usage_metadata) # token 用量
```

预期输出：

```text
<class 'langchain.messages.AIMessage'>
RAG 就是让大模型先检索资料、再基于资料作答的技术。（示意）
{'input_tokens': 18, 'output_tokens': 32, 'total_tokens': 50,
 'input_token_details': {'audio': 0, 'cache_read': 0},
 'output_token_details': {'audio': 0, 'reasoning': 0}}
```

注意两点：

1. **返回值是 `AIMessage` 对象，不是 `str`**。取文本内容用 `resp.text`；
   后面 2.4 节会详细介绍这个对象上有哪些属性。
2. `usage_metadata` 记录本次调用的 token 用量，是做成本统计的依据。
   `input_token_details` / `output_token_details` 里还能看到
   缓存命中（`cache_read`）和推理（`reasoning`）的细分。

### 1.3 三种调用方式

| 方法 | 行为 | 适用 |
| --- | --- | --- |
| `invoke` | 一次调用，等完整结果 | 绝大多数场景 |
| `stream` | 逐步返回文本片段（`AIMessageChunk`） | 打字机效果 |
| `batch` | 多个输入并发调用，返回列表 | 批量任务 |

异步版本对应 `ainvoke` / `astream` / `abatch`，用法完全一致。
**并非所有集成都支持 `streaming` 参数**，遇到不支持 `stream()` 的模型，
用基类的 `disable_streaming=True` 显式关掉。

```python
from langchain.chat_models import init_chat_model

model = init_chat_model("openai:gpt-5.5", streaming=False)  # 禁用流式
```

### 1.4 OpenAI 兼容接口：换 base_url 指向自建网关

很多服务商（DeepSeek、Moonshot、本地 vLLM、各类网关）提供
**OpenAI 兼容接口**——协议和 OpenAI 一样，只是地址和模型名不同。
这时用 `model_provider="openai"` + `base_url` 指向它即可：

```python
import os
from langchain.chat_models import init_chat_model

model = init_chat_model(
    model="deepseek-chat",            # 目标服务实际提供的模型名
    model_provider="openai",           # 协议按 OpenAI 来
    base_url="https://api.deepseek.com",
    api_key=os.environ["DEEPSEEK_API_KEY"],
)
resp = model.invoke("你好")
print(resp.text)  # （示意）你好！有什么我可以帮你的吗？
```

**名词解释：base_url。** API 的基础地址。默认是 `https://api.openai.com/v1`，
改成别家地址，请求就发到别家去。换提供商时**只改这里和密钥**，
`invoke` 等调用代码不用动——这正是统一接口的价值。

### 1.5 模型能力去哪查

上下文窗口、是否支持视觉、是否支持推理……这些能力差异由集成层消化。
官方维护了一个模型能力查询站点 **models.dev**，可按提供商筛选，
上面会标注每个模型的上下文长度、模态、能力标签。
写代码前先查一眼，能避免"选了不支持工具调用的模型"这类问题。

### 1.6 与智能体的关系

`create_agent` 的 `model=` 参数**既接受字符串，也接受模型实例**。
需要精细控制（调温度、设超时、指定 base_url、禁用流式）时，
先用 `init_chat_model` 造好实例再传进去：

```python
from langchain.agents import create_agent
from langchain.chat_models import init_chat_model

model = init_chat_model("openai:gpt-5.5", temperature=0, timeout=300)

agent = create_agent(model=model, tools=[...])
```

## 2. 消息

### 2.1 为什么消息不是纯字符串

早期模型只收字符串、只回字符串。2023 年 OpenAI 发布 Chat Completion API 后，
输入输出都变成了**消息列表**——每条消息带一个角色（谁说的）和内容。
LangChain 用标准消息类型把这件事统一起来：不管底层是哪家提供商，
代码里写的都是同一批对象。

**名词解释：消息 = 角色 + 内容 + 元数据。**
角色决定这条消息怎么被模型理解（系统指令 / 用户输入 / 模型回复 / 工具结果）；
内容是实际载荷（文字、图像、文件……）；元数据是可选信息（ID、token 用量等）。

### 2.2 四种消息类型

| 类型 | 作用 | 谁产生 |
| --- | --- | --- |
| `SystemMessage` | 设定语气、角色与响应准则 | 开发者 |
| `HumanMessage` | 用户输入，支持多模态 | 用户 |
| `AIMessage` | 模型输出，含工具调用与用量元数据 | 模型 |
| `ToolMessage` | 工具执行结果回传 | 工具节点 |

```python
from langchain.chat_models import init_chat_model
from langchain.messages import SystemMessage, HumanMessage

model = init_chat_model("openai:gpt-5.5")

messages = [
    SystemMessage("你是一名乐于助人的助手，回答不超过 50 字。"),
    HumanMessage("你好，最近怎么样？"),
]

resp = model.invoke(messages)
print(resp.text)  # （示意）我很好，谢谢关心！有什么可以帮你的吗？
```

### 2.3 三种传入方式

```python
# ① 字符串：单次独立请求的快捷方式，等价于一条 HumanMessage
resp = model.invoke("写一首关于春天的俳句")

# ② 消息对象列表：多轮对话、多模态、带系统指令时用这个
resp = model.invoke([SystemMessage("你是诗歌专家"), HumanMessage("写一首俳句")])

# ③ OpenAI Chat Completions 字典格式：方便直接迁移既有代码
resp = model.invoke([
    {"role": "system", "content": "你是诗歌专家"},
    {"role": "user", "content": "写一首俳句"},
])
```

三种形式在底层都会被转成统一的消息对象。**多轮场景不要用字符串**——
它不带历史，每次都是全新对话。

### 2.4 AIMessage 的关键属性

```python
response = model.invoke("北京天气怎么样？")

response.text               # 纯文本（最常用）
response.content            # 弱类型内容：字符串或内容块列表（原始形态）
response.content_blocks     # 类型安全的标准内容块（v1 新增）
response.tool_calls         # 模型发起的工具调用列表
response.usage_metadata     # token 用量
response.response_metadata  # 提供商原始元数据（模型名、结束原因等）
```

`usage_metadata` 形如：

```python
{'input_tokens': 8, 'output_tokens': 304, 'total_tokens': 312,
 'input_token_details': {'audio': 0, 'cache_read': 0},
 'output_token_details': {'audio': 0, 'reasoning': 256}}
```

### 2.5 `content` 与 `content_blocks`：为什么有两个

这是 v1 的关键设计，也是最容易迷糊的地方：

- **`content`** 保持**弱类型**——原样保留提供商返回的内容
  （可能是字符串，也可能是 provider 私有的结构）。为什么不一刀切？
  因为各提供商输出格式差异大，强转会丢信息，保留原始形态才能向后兼容。
- **`content_blocks`** 是**延迟解析**的**类型安全视图**——
  用的时候才把各家格式统一成一套标准块，把 Anthropic 的 `thinking` 和
  OpenAI 的 `reasoning` 都归一成 `ReasoningContentBlock`。

看个具体例子。Anthropic 返回的消息，`content` 里躺着一个 `thinking` 块：

```python
from langchain.messages import AIMessage

message = AIMessage(
    content=[
        {"type": "thinking", "thinking": "用户在问天气，我应该调用工具。", "signature": "WaUjzkyp..."},
        {"type": "text", "text": "让我查一下。"},
    ],
    response_metadata={"model_provider": "anthropic"},
)
print(message.content)
# [{'type': 'thinking', 'thinking': '用户在问天气，我应该调用工具。', ...},
#  {'type': 'text', 'text': '让我查一下。'}]

print(message.content_blocks)
# [{'type': 'reasoning', 'reasoning': '用户在问天气，我应该调用工具。', 'extras': {'signature': '...'}},
#  {'type': 'text', 'text': '让我查一下。'}]
```

注意 `content_blocks` 里的 `'type': 'reasoning'`——**同一套标准表示**，
换 OpenAI 返回的消息也是这个结构，业务代码就不用给每家写分支了。

::: note 向后兼容
`content_blocks` 是 v1 的**新增属性**，不是 `content` 的替代品。
用 `content_blocks` 初始化消息时，`content` 仍会被同步填充，旧代码不受影响。
:::

标准内容块的类型谱系（日常最常用的是前两组）：

- 文本：`TextContentBlock`、`ReasoningContentBlock`（推理/思考内容）；
- 多模态：`Image` / `Audio` / `Video` / `File` / `PlainTextContentBlock`；
- 工具调用：`ToolCall`、`ToolCallChunk`、`InvalidToolCall`；
- 服务端工具：`ServerToolCall` / `Chunk` / `Result`；
- 提供商扩展：`NonStandardContentBlock`。

### 2.6 工具调用消息：一次完整的对话回合

工具调用是智能体的核心动作，这里把"模型发起调用 → 执行 → 结果回传"的
**完整四步**走一遍，后面所有内容都基于这个链路：

```python
from langchain.chat_models import init_chat_model
from langchain.messages import HumanMessage, ToolMessage

model = init_chat_model("openai:gpt-5.5")

def get_weather(city: str) -> str:
    """获取指定城市的天气。"""
    return f"{city} 总是阳光明媚！"

# ① 把工具绑定到模型上，模型即获得该工具的入参 schema
model_with_tools = model.bind_tools([get_weather])

# ② 模型决定调用工具，返回带 tool_calls 的 AIMessage
ai_msg = model_with_tools.invoke(HumanMessage("巴黎的天气怎么样？"))
print(ai_msg.tool_calls)
# [{'name': 'get_weather', 'args': {'city': 'Paris'}, 'id': 'call_abc123', 'type': 'tool_call'}]

# ③ 本地执行函数，把结果包成 ToolMessage
call = ai_msg.tool_calls[0]
tool_msg = ToolMessage(
    content=get_weather(**call["args"]),   # "Paris 总是阳光明媚！"
    tool_call_id=call["id"],               # 必须与调用 ID 匹配
    name=call["name"],
)

# ④ 把 AI 消息和工具结果一起发回模型，模型基于结果生成最终回答
final = model_with_tools.invoke([HumanMessage("巴黎的天气怎么样？"), ai_msg, tool_msg])
print(final.text)  # （示意）巴黎总是阳光明媚！
```

::: danger `tool_call_id` 必须匹配
`ToolMessage.tool_call_id` 必须与它所回应的那次工具调用 ID 一致。
不一致时模型侧会校验失败——多家提供商会直接报错拒绝整条请求。
生产代码绝不手工编 ID，一律从 `tool_calls` 里取，或用 3.3 节的
`runtime.tool_call_id`。
:::

**名词解释：`artifact`。**
`ToolMessage` 上有个特殊字段 `artifact`，用来放**不发给模型、
但程序可读**的补充数据（文档 ID、调试信息、分页游标……）：

```python
tool_msg = ToolMessage(
    content="查到了 3 篇相关文档。",        # 模型看到的是这行
    tool_call_id=call["id"],
    artifact={"document_ids": ["d1", "d2", "d3"]},  # 只有程序看得到
)
```

典型用途：检索工具返回给模型的文本受 token 预算限制，但前端渲染卡片
需要的完整元数据放 `artifact` 里，各取所需。

### 2.7 多模态与序列化

图像、PDF、音频、视频的来源可为 URL、base64 或提供商托管的 `file_id`；
**使用 base64 时 `mime_type` 必填**：

```python
HumanMessage(content_blocks=[
    {"type": "text", "text": "描述这张图"},
    {"type": "image", "url": "https://example.com/image.jpg"},
    # base64 形式必须带 mime_type：
    # {"type": "image", "base64": "AAAAIGZ0...", "mime_type": "image/jpeg"},
])
```

需要把消息存进数据库/Redis 时，用 `dumpd()` 序列化为普通 dict，
`load()` 反序列化回消息对象（`langchain_core.load`）：

```python
from langchain_core.load import dumpd, load

payload = dumpd(HumanMessage("你好"))   # 可 JSON 序列化的普通字典
msg = load(payload)                      # 还原为 HumanMessage 对象
```

::: danger 安全警告
`load()` 会实例化 Python 对象并可能触发副作用，
**切勿对来自不可信或未经身份验证来源的数据调用 `load()`**。
:::

## 3. 工具

### 3.1 工具到底是什么

**名词解释：工具 = 带类型提示和 docstring 的普通 Python 函数。**
模型本身只能输出文本；工具是它"动手"的唯一方式。传给模型后，
模型根据对话上下文决定**何时调用**、**传什么参数**，LangChain 负责执行
并把结果回传。定义工具只需要三样东西：

```python
from langchain.tools import tool

@tool
def get_weather(city: str) -> str:
    """获取指定城市的天气。

    Args:
        city: 城市名，如 "北京"、"Paris"
    """
    return f"{city} 总是阳光明媚！"
```

1. **类型提示是必需的**——它构成工具的输入 Schema，模型靠它生成合法入参；
2. **docstring 成为工具描述**——注意，这段话的读者是**模型**而不是开发者，
   写清楚"什么时候该用我"比写实现细节更重要；
3. 返回值转成 `ToolMessage` 回传（见 3.4 节）。

模型实际看到的工具定义大致是下面这段 JSON（示意）：

```json
{
  "name": "get_weather",
  "description": "获取指定城市的天气。...",
  "parameters": {
    "type": "object",
    "properties": {"city": {"type": "string", "description": "城市名，如 \"北京\""}},
    "required": ["city"]
  }
}
```

这也解释了为什么 2.6 节强调 `tool_call_id` 要匹配：**模型眼中工具调用是
对话的一部分**，结果必须能对回它发起的那一次请求。

复杂输入用 `args_schema` 传 Pydantic 模型或 JSON Schema 字典：

```python
from pydantic import BaseModel, Field
from typing import Literal

class WeatherInput(BaseModel):
    """天气查询输入。"""
    location: str = Field(description="城市名称或坐标")
    units: Literal["celsius", "fahrenheit"] = Field(default="celsius")
    include_forecast: bool = Field(default=False)

@tool(args_schema=WeatherInput)
def get_weather_detailed(location: str, units: str = "celsius",
                         include_forecast: bool = False) -> str:
    """获取当前天气和可选预报。"""
    ...
```

::: warning 命名约定
工具名应使用 **`snake_case`**（如 `web_search`）。
部分提供商无法处理含空格或特殊字符的名称，会直接报错拒绝。
:::

::: warning 保留参数名
`config`（保留给 `RunnableConfig`）与 `runtime`（保留给 `ToolRuntime`）
不得用作工具参数，否则运行时报错。需要 runtime 信息就按下一节声明。
:::

### 3.2 `@tool` 的两个可选参数

```python
@tool("web_search", description="在互联网上搜索最新信息。当用户询问时事、新闻时使用。")
def search(query: str) -> str:
    ...
```

第一个位置参数覆盖工具**名**，`description=` 覆盖**描述**。
默认都取自函数名和 docstring。

### 3.3 `ToolRuntime`：访问运行时

这是本篇最重要、也最容易被原文略过的一节，慢慢讲。

#### 3.3.1 它解决什么问题

设想工具运行时需要这些信息：

- "把用户称呼写进对话状态"——要访问**当前图状态**（短期记忆）；
- "查该用户的偏好"——要访问**注入的用户身份**（运行时上下文）；
- "记住用户上次的选择"——要访问**长期记忆存储**；
- "把这次调用记到哪个 tool_call 上"——要知道**当前工具调用 ID**。

这些信息有个共同点：**它们是运行期的数据，不是工具的业务参数**。
如果把它们做成工具参数（比如 `def set_name(new_name, state, user_id)`），
会出两个问题：模型会在 schema 里看到这些参数并试图填值（它根本不知道
当前状态是什么）；你得在每次调用时手工传递它们。

LangGraph 的解法是**关键字注入**：在工具签名里声明一个 `runtime` 参数，
执行时由框架自动填好。`ToolRuntime` 就是这个注入对象的类型注解。

#### 3.3.2 与旧版写法的关系

旧版有四种各自为政的注入方式：`InjectedState`（注入状态）、
`InjectedStore`（注入存储）、`get_runtime()`（函数式获取）、
`InjectedToolCallId`（注入调用 ID）——记四套 API，且风格不统一。
v1 起**统一由 `ToolRuntime` 取代**，一个参数拿到全部。

#### 3.3.3 八类信息一览

`ToolRuntime` 提供八类信息，按用途分组记：

| 类别 | 是什么 | 访问方式 | 典型用途 |
| --- | --- | --- | --- |
| 状态 | **短期记忆**：当前对话的状态（消息列表 + 自定义字段） | `runtime.state` | 读写对话内数据 |
| 上下文 | **不可变配置**：本次调用注入的静态数据（用户 ID、租户） | `runtime.context` | 按用户身份区分行为 |
| 存储 | **长期记忆**：跨对话持存的 `BaseStore` | `runtime.store` | 记住跨会话的偏好 |
| 流写入器 | 向 `"custom"` 流模式发数据的水管 | `runtime.stream_writer` | 工具内部发进度 |
| 执行信息 | 线程 ID、运行 ID、重试次数 | `runtime.execution_info` | 日志关联、按重试状态决策 |
| 服务器信息 | LangGraph Server 上的助手 ID、图 ID、认证用户 | `runtime.server_info` | 多助手部署时区分来源 |
| 配置 | 本次执行的 `RunnableConfig` | `runtime.config` | 回调、标签等 |
| 工具调用 ID | 当前工具调用的唯一标识 | `runtime.tool_call_id` | 回填 `ToolMessage` |

**名词解释：短期记忆 vs 长期记忆。**
短期记忆（状态）只活在**一个 `thread_id` 界定的对话**里，随检查点持久化、
可恢复；长期记忆（Store）**跨对话共享**，任何线程都能读。
两者配合使用，机制详见[持久化与记忆](/langgraph/persistence-memory)。

**名词解释：不可变上下文。** `runtime.context` 的数据通过 `context=` 参数
在调用时传入，单次运行内不变。它和 `thread_id` 分工明确：
`thread_id` 界定"哪场对话"，`context` 承载"这场对话里这次运行的静态身份"。

::: warning 版本要求
`execution_info` / `server_info` 需要 `deepagents>=0.5.0` 或 `langgraph>=1.1.5`。
在非 LangGraph Server 环境中（本地开发），`server_info` 为 `None`——
用之前先判空。
:::

#### 3.3.4 完整可运行例子：改写用户称呼

下面这个例子把 `CustomState`、`Context`、`ToolRuntime` 三个知识点串起来，
每一行都能对应到上面的表格。**建议直接复制运行**（需要 API 密钥）：

```python
from dataclasses import dataclass

from langchain.agents import AgentState, create_agent
from langchain.messages import ToolMessage
from langchain.tools import ToolRuntime, tool
from langgraph.checkpoint.memory import InMemorySaver
from langgraph.types import Command


# ① 自定义状态：在默认 AgentState（含 messages）上加一个 user_name 字段
class CustomState(AgentState):
    user_name: str


# ② 上下文 schema：声明 runtime.context 的结构
@dataclass
class Context:
    user_id: str


# ③ 工具：runtime 参数由框架自动注入，对模型完全隐藏
@tool
def set_user_name(new_name: str, runtime: ToolRuntime[Context, CustomState]) -> Command:
    """设置用户名称。"""
    # 读状态：当前对话里已有什么（这里是 messages 和 user_name）
    old_name = runtime.state.get("user_name", "")

    return Command(
        update={
            "user_name": new_name,
            "messages": [
                ToolMessage(
                    content=f"用户名称已从 {old_name or '（空）'} 修改为 {new_name}。",
                    tool_call_id=runtime.tool_call_id,  # ③-a 必须与本次调用对应
                )
            ],
        }
    )


# ④ 组装智能体：state_schema / context_schema 分别告诉框架用哪套结构
agent = create_agent(
    model="openai:gpt-5.5",
    tools=[set_user_name],
    state_schema=CustomState,     # 启用 user_name 字段
    context_schema=Context,       # 启用 context.user_id
    checkpointer=InMemorySaver(), # 状态持久化，否则 Command 更新无处存
)

result = agent.invoke(
    {"messages": [{"role": "user", "content": "把用户名称改成小明"}],
     "user_name": ""},                    # 初始值
    config={"configurable": {"thread_id": "1"}},
    context=Context(user_id="u-1001"),    # 注入运行时上下文
)

print("最终 user_name =", result["user_name"])
for m in result["messages"]:
    print(m.pretty_repr()[:100])
```

预期输出：

```text
最终 user_name = 小明
================================ Human Message =================================
把用户名称改成小明
================================== Ai Message =================================
Tool Calls:  set_user_name (call_9xK2...)
 Call ID:   call_9xK2...
  Args:    {'new_name': '小明'}
================================= Tool Message =================================
Name: set_user_name
用户名称已从 （空） 修改为 小明。
```

对照输出理解三件事：

1. **模型的输入里只有 `new_name`**——你在模型侧看到的 tool call 是
   `{'new_name': '小明'}`，`runtime` 没有出现在参数里，模型对它无感；
2. **`runtime.state` 读到了旧值**——工具内部 `old_name` 取到初始的 `""`，
   所以提示语是"从 （空） 修改为 小明"；
3. **`runtime.tool_call_id` 对上了**——ToolMessage 的 `tool_call_id`
   与上面 AI 消息的 `Call ID` 一致（都是 `call_9xK2...`），
   模型因此能正确理解"我发起的调用有结果了"。

::: danger 为什么必须手写这条 ToolMessage
`Command(update={...})` 更新的是**图状态**，模型看到的对话是另一回事。
`ToolNode` 强制要求：**每个工具调用都必须有一条 `tool_call_id` 匹配的
`ToolMessage`**，否则直接抛 `ValueError`。忘了写是最常见的报错之一。
:::

#### 3.3.5 另外几类信息的读写范式

**读写长期记忆（Store）：**

```python
@tool
def save_preference(runtime: ToolRuntime[Context]) -> str:
    """保存用户偏好。"""
    assert runtime.store is not None  # 没配 store 时该属性为 None，先判空
    runtime.store.put(("preferences",), runtime.context.user_id,
                      {"style": "简洁"})
    return "已保存。"
```

**从工具内部发进度（配合 `stream_mode="custom"` 消费）：**

```python
@tool
def query_city(city: str, runtime: ToolRuntime) -> str:
    """查询城市数据。"""
    runtime.stream_writer(f"正在检索 {city} 的数据...")
    ...
    return result
```

### 3.4 返回值的四种形态

| 返回值 | 用途 | 模型看到什么 |
| --- | --- | --- |
| 字符串 | 人类可读的结果 | 这段文本 |
| 对象 / `dict` | 结构化数据供模型推理 | 序列化后的内容 |
| 内容块列表 | 多模态结果（文本 + 图片 URL） | 多模态 ToolMessage |
| `Command` | 同时更新图状态 | 你放进去的那条 ToolMessage |

`Command` 的用法已在 3.3.4 完整演示，这里补 `return_direct`——
让工具结果**短路智能体循环**，不再回传给模型：

```python
@tool(return_direct=True)
def fetch_order_status(order_id: str) -> str:
    """获取客户订单的当前状态。"""
    return f"订单 {order_id} 已发货，将在 2 天内送达。"
```

调用后智能体**直接结束**，把工具输出作为最终响应用户——省一次模型调用。
两个注意点：

- 结果需要进一步推理、总结、或与其他调用串联时**不要用**；
- 模型并行调用多个工具时，**只有整批全部**设了 `return_direct=True`
  才会短路；混着一个普通工具，整批结果都会乖乖回传给模型。

### 3.5 错误处理：把异常变成模型能读的反馈

工具抛异常时，如果直接炸掉，整个智能体循环就断了。更好的做法是
把异常转成 `ToolMessage` 反馈给模型，让它自己修正重试
（"上次参数不对，换个写法"）。用 `wrap_tool_call` 装饰器：

```python
from collections.abc import Callable

from langchain.agents import create_agent
from langchain.agents.middleware import wrap_tool_call
from langchain.messages import ToolMessage
from langchain.tools.tool_node import ToolCallRequest


@wrap_tool_call
def handle_tool_errors(
    request: ToolCallRequest,
    handler: Callable[[ToolCallRequest], ToolMessage],
) -> ToolMessage:
    """把工具异常转换为模型可以处理的 ToolMessage。"""
    try:
        return handler(request)
    except Exception as e:
        return ToolMessage(
            content=f"工具执行失败：请检查输入后重试。（{e}）",
            tool_call_id=request.tool_call["id"],
        )


agent = create_agent(
    model="openai:gpt-5.5",
    tools=[get_weather],
    middleware=[handle_tool_errors],
)
```

**名词解释：`handler`。** 包装式钩子（wrap-style hook）的核心概念——
`handler(request)` 就是"执行真正的工具调用"这个动作。
`wrap_tool_call` 让你在调用前后包一层逻辑：可以重试、可以记录日志、
可以像这里一样把异常吞掉转成反馈。`handler` 被调**零次**=短路不执行，
**一次**=正常，**多次**=重试。

### 3.6 动态工具选择：工具太多时收敛上下文

模型一次看到的工具定义也是要占上下文的。工具过多会造成
**上下文过载**——模型难以稳定选择，错误率上升。两种收敛方式：

**① 筛选预注册工具**——创建时已知全部工具，运行时按需过滤：

```python
from langchain.agents.middleware import wrap_model_call


@wrap_model_call
def state_based_tools(request, handler):
    # 未登录用户只给 public_ 前缀的工具
    if not request.state.get("authenticated"):
        tools = [t for t in request.tools if t.name.startswith("public_")]
        request = request.override(tools=tools)
    return handler(request)
```

**② 运行时注册工具**——工具来自 MCP 服务器等运行时来源。
需要**同时**实现 `wrap_model_call`（把新工具加进请求）和
`wrap_tool_call`（告诉智能体怎么执行它）：

```python
class DynamicToolMiddleware(AgentMiddleware):
    def wrap_model_call(self, request, handler):
        # 从 MCP 服务器、数据库等来源拿到新工具
        return handler(request.override(tools=[*request.tools, calculate_tip]))

    def wrap_tool_call(self, request, handler):
        # 不在原始列表里的工具，必须在这里接手执行
        if request.tool_call["name"] == "calculate_tip":
            return handler(request.override(tool=calculate_tip))
        return handler(request)
```

::: warning 缺一个钩子都不行
只写 `wrap_model_call` 不加 `wrap_tool_call`，智能体"知道"有新工具
却不会执行它——调用时报无法找到工具。这是运行时注册最常见的坑。
:::

### 3.7 MCP 与无头工具

**名词解释：MCP（Model Context Protocol，模型上下文协议）。**
一套开放标准，用来把"外部工具"以统一方式暴露给 LLM 应用。
LangChain 1.4 起内置了适配器，几行代码把 MCP 服务器的工具接进智能体：

```python
from langchain.agents import create_agent
from langchain.mcp import MCPAdapter

async with MCPAdapter("https://example.com/mcp") as adapter:
    tools = await adapter.list_tools()
    agent = create_agent("claude-sonnet-4-6", tools)
```

::: note 版本与状态
`langchain.mcp` 命名空间需要 `langchain[mcp]>=1.4.0`，目前处于 Beta 阶段，
API 可能变化。更早的方案是用独立包
[`langchain-mcp-adapters`](https://github.com/langchain-ai/langchain-mcp-adapters)
（`MultiServerMCPClient` / `load_mcp_tools`），文档见其仓库。
:::

**名词解释：无头工具（Headless Tool）。**
有些工具的执行必须发生在**客户端**（浏览器）：地理位置、剪贴板、
文件选择器、Canvas——这些能力服务端进程根本没有。
无头工具的思路是**Schema 留在服务端、执行留在客户端**：
Python 端只提供 name / description / args_schema，工具被调用时图会
**中断**并抛出 `{"type": "tool", "tool_call": {...}}` 载荷，由前端
（或其他服务、人工）真正执行后 `Command(resume=...)` 把结果填回来。
它和"函数体在服务端运行的普通工具"、和"由模型提供商远程执行的
服务端工具"是三件不同的事。

## 4. 三者的协作

把前面所有片段接起来，一次"问天气"的完整生命线：

```text
HumanMessage ──▶ 模型推理 ──▶ AIMessage.tool_calls（模型决定调用 get_weather）
                                     │
                                     ▼
                            ToolNode 执行 @tool 函数
                            （此处 runtime 可读写状态/上下文/存储）
                                     │
                                     ▼
                    ToolMessage(tool_call_id=对上调用 ID) ──▶ 模型继续推理 ──▶ 最终回答
```

在智能体里这条路由 `create_agent` 的循环自动完成，开发者不用编排。
在裸 LangGraph 里也可以手工搭——见本博客
[图 API 三要素](/langgraph/graph-api)。

## 5. 小结

- 模型经 `init_chat_model` 统一初始化，`"provider:model"` 字符串 + `base_url`
  是切换提供商的唯二改动点；`invoke` 返回的是 `AIMessage` 不是字符串。
- `content` 保留原始形态保证兼容，`content_blocks` 提供跨提供商的
  类型安全视图，推理内容统一为 `reasoning` 块。
- 工具即带类型提示和好 docstring 的函数；`tool_call_id` 必须配对，
  这是工具消息链路的铁律。
- `ToolRuntime` 一个参数统一了状态、上下文、存储、流写入器等八类运行期
  信息，对模型隐藏；缺了 `ToolMessage` 是新手最常踩的报错。
- 工具错误转 `ToolMessage` 让模型自愈；工具太多时动态裁剪上下文。

下一篇：[记忆 · 流式 · 结构化输出](/langchain/context-output)。
