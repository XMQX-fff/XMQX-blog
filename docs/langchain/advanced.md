# 上下文工程与高级能力

本篇覆盖官方"高级用法"一组：上下文工程（方法论）、人在回路、多智能体、
长期记忆与护栏。这五者共同服务于"从原型到生产"这一跨越。

## 怎么读本篇

- 第 1 节是**方法论**，读完后会用"上下文"的视角看智能体设计；
- 第 2~5 节是四个可落地机制，每节都给了完整可运行示例；
- 最后一节汇总了各能力的**最低版本要求**，上线前逐条核对。

## 1. 上下文工程

### 1.1 为什么智能体会失败

官方指出两个原因：底层 LLM 能力不足，以及**未向模型提供"正确"的上下文**，
并认为多数情况下后者才是主因。

**名词解释：上下文工程（context engineering）。** 以正确的格式提供适当的
信息和工具，使 LLM 能够完成任务。它被称为 AI 工程师最重要的工作——
模型再强，喂给它的东西不对，输出照样错。其在 LangChain 中的落地机制是
**中间件**：所有对"模型看到什么"的干预，都是某个中间件在某个时机
改状态或改请求。

### 1.2 三类上下文

| 类别 | 作用范围 | 生命周期 |
| --- | --- | --- |
| **模型上下文** | 进入模型调用的内容：指令、消息历史、工具、响应格式 | 临时 |
| **工具上下文** | 工具可读写的状态、存储、运行时上下文 | 持久 |
| **生命周期上下文** | 模型与工具调用之间：摘要、护栏、日志 | 持久 |

展开说：

- **模型上下文**——模型每次开口前"眼前"的一切。改它有两种改法：
  **临时**（只改这一次模型调用看到的，状态不动）和**持久**
  （把改动写回状态，后续都受影响）。两者的边界是新手最常搞混的地方。
- **工具上下文**——工具能碰到的数据：读状态（短期）、读写存储（长期）、
  读运行时配置。
- **生命周期上下文**——步骤**之间**发生的横切关注点：摘要历史、
  过滤敏感内容、记录日志。这些不属于"模型看到什么"，而是
  "在两个动作之间做点什么"。

三类数据源贯穿始终：**运行时上下文**（静态配置，对话级）、
**状态**（短期记忆，对话级）、**存储**（长期记忆，跨对话）。
三类上下文 × 三类数据源的组合，就是"某个信息从哪来、影响多久"的
定位坐标系。

### 1.3 模型上下文的五个要素

系统提示词、消息、工具、模型、响应格式——每一项都可来自三类数据源。
动态调整的统一手法是 `request.override(...)`：

```python
@dynamic_prompt
def state_aware_prompt(request: ModelRequest) -> str:
    message_count = len(request.messages)   # request.state["messages"] 的快捷方式
    base = "你是一名乐于助人的助手。"
    if message_count > 10:
        base += "\n这是一段较长的对话，请格外简洁。"
    return base


@wrap_model_call
def inject_file_context(request, handler):
    uploaded_files = request.state.get("uploaded_files", [])
    request = request.override(
        messages=[*request.messages, {"role": "user", "content": file_context}],
    )
    return handler(request)
```

`request.override` 可作用于 `tools=`、`model=`、`response_format=`、
`messages=`，是实现"按状态/存储/上下文裁剪"的通用入口。

::: warning 临时更新 vs 持久更新
- **临时**：在 `wrap_model_call` 中改写单次调用，**不改状态**；
- **持久**：返回带 `Command` 的 `ExtendedModelResponse`，
  或使用 `@before_model` / `@after_model` / `@wrap_tool_call`。

两者混淆会带来"改了却没生效"（改的是临时，却以为写进去了）或
"不该留下却被永久写入"（写回了状态，污染后续所有轮次）的问题。
**判断口诀：`wrap_model_call` 里默认都是临时的；想持久就要显式写状态。**
:::

工具的说明同样属于上下文——**工具定义不只是元数据，它们会引导模型**：
过多导致上下文过载，过少则限制能力。这解释了为什么第 3 章的
[动态工具选择](/langchain/components#3-6-动态工具选择工具太多时收敛上下文)值得投入精力。

### 1.4 六条最佳实践

1. **从简单方案开始**——静态提示词 + 固定工具能跑，就别上动态；
2. **增量测试，每次只加一项功能**——同时加三个中间件，
   出问题无法归因；
3. **监控性能**（调用次数、token、延迟）—— LangSmith 里看，
   别凭感觉；
4. **优先使用内置中间件**——Summarization、ToolSelector 这些
   都是踩过坑的产物；
5. **记录上下文策略**——写清楚"传了什么、为什么"，
   三个月后的自己会感谢现在；
6. **理解临时更新与持久更新的区别**——见上面的警告框。

## 2. 人在回路（Human-in-the-Loop）

当模型提出敏感操作（写文件、执行 SQL、转账、发信）时暂停执行，
图状态经 LangGraph 持久化层保存，由人工决定后再继续。

**名词解释：中断（interrupt）。** 智能体执行到某处主动"挂起"，
把控制权交还给外部（人），并把待决策信息作为载荷抛出。挂起期间
状态存在 checkpointer 里，可以等一分钟，也可以等三天——
异步审核因此成为可能。

### 2.1 四种决策

| 决策 | 行为 | 什么时候用 |
| --- | --- | --- |
| `approve` | 原样执行 | 常规确认 |
| `edit` | 执行前修改参数 | 小修小补（改个收件人） |
| `reject` | 跳过执行，返回拒绝反馈 | 否决，并告诉模型为什么 |
| `respond` | 跳过执行，把人工消息作为**合成工具结果** | 工具本来就是"问人"（如 `ask_user`） |

::: danger 注意
不要用 `respond` 拒绝**带副作用**的工具——其消息会被视为成功结果，
模型以为事儿已经办完了。**拒绝一律用 `reject`**，它的 `message`
会作为反馈进入对话，模型能理解"被否了，别重试"。

多个工具同时暂停时，**决策顺序必须与中断请求中的操作顺序一致**——
按收集到的顺序逐个决策，别自己挑着先批简单的。

编辑参数需谨慎，大幅修改可能让模型重新评估方案、重复执行或意外操作。
:::

### 2.2 配置

```python
from langchain.agents import create_agent
from langchain.agents.middleware import HumanInTheLoopMiddleware
from langgraph.checkpoint.memory import InMemorySaver

agent = create_agent(
    model="openai:gpt-5.5",
    tools=[write_file, execute_sql, read_data],
    middleware=[HumanInTheLoopMiddleware(
        interrupt_on={
            "write_file": True,                                       # 全决策可用
            "execute_sql": {"allowed_decisions": ["approve", "reject"]},  # 不许编辑
            "read_data": False,                                        # 只读，直接放行
        },
        description_prefix="工具执行待审批",
    )],
    checkpointer=InMemorySaver(),     # 必须
)
```

`interrupt_on` 的值即"该工具的审批策略"：`True`=默认配置（四种决策全开），
`False`=自动批准，`dict`=`InterruptOnConfig`（可用 `allowed_decisions`
限制决策类型、`description` 自定义给审核人看的描述）。

恢复执行：

```python
from langgraph.types import Command

agent.invoke(
    Command(resume={"decisions": [{"type": "approve"}]}),
    config={"configurable": {"thread_id": tid}},
    version="v2",
)
# {"type": "edit", "edited_action": {"name": ..., "args": {...}}}
# {"type": "reject", "message": "用户拒绝该操作，请勿重试此工具调用。"}
# {"type": "respond", "message": "..."}
```

**名词解释：`Command(resume=...)`。** 与中断配对的另一半原语：
把人工的决策作为"返回值"填回挂起点，图从那里继续跑。
`version="v2"` 时返回的是 `GraphOutput`，其 `.interrupts` 属性直接
列出待审核事项，不用自己从流里捞。

**条件中断**可用 `when` 谓词按请求内容决定是否暂停
（需 `langchain>=1.3.3`）——比如只拦非 `SELECT`：

```python
"execute_sql": {
    "when": lambda req: not req.tool_call["args"]["query"].upper().startswith("SELECT"),
    "allowed_decisions": ["approve", "reject"],
}
```

实现上，该中间件定义 `after_model` 钩子，在模型生成响应之后、
工具执行之前介入，因而不修改模型输出本身。

::: warning 前置条件
- **必须配置 checkpointer**（生产用 `AsyncPostgresSaver` 或 `MongoDBSaver`）；
- 调用必须传含 `thread_id` 的 config；
- 流式场景中审核决定的顺序须与收集到的中断顺序一致。
:::

## 3. 多智能体系统

### 3.1 何时需要拆分

单个智能体出现下列信号时，应考虑多智能体：

- **工具过多**，模型难以稳定选择；
- **上下文或记忆过于庞大**；
- 任务本身需要**专业化分工**（规划者、研究员、数学专家）。

::: warning 不是万金油
多智能体并非默认选项。官方明确说拆分的前提是"工具过多、
上下文过复杂、需要多领域"——**先确认确实遭遇这些瓶颈**。
过早拆分，仅通信协议的复杂度就足以抵消其收益。
:::

### 3.2 两种模式

| 模式 | 控制流 | 适用 |
| --- | --- | --- |
| **工具调用**（主管把子智能体当工具） | 集中式 | 任务编排、结构化工作流 |
| **交接**（Handoffs，转移控制权） | 分散式 | 多领域对话、专家接管 |

选择依据：需要集中式控制 → 工具调用；
希望智能体直接与用户交互 → 交接；两者**可混合使用**。

### 3.3 工具调用模式（完整例子）

四步流程：控制器决定 → 工具智能体运行 → 返回结果 → 控制器继续或完成。
下面是一个可以直接跑的"研究主管"：

```python
from langchain.agents import create_agent
from langchain.tools import tool


def web_search(query: str) -> str:
    """搜索互联网。"""
    ...


# 子智能体：专门干调研，工具集收窄
researcher = create_agent(
    model="openai:gpt-5.5",
    tools=[web_search],
    system_prompt="你是研究员，负责收集事实并给出带引用的结论。",
)


# 主管把子智能体包装成一个工具
@tool("researcher", description="针对给定主题执行深度调研并返回结论")
def call_researcher(query: str) -> str:
    """调用调研子智能体。"""
    result = researcher.invoke({"messages": [{"role": "user", "content": query}]})
    return result["messages"][-1].text   # 只把最终结论交回主管


agent = create_agent(
    model="openai:gpt-5.5",
    tools=[call_researcher],
    system_prompt="你是主管。需要事实时调用 researcher，最后综合成报告。",
)

result = agent.invoke({"messages": [{"role": "user", "content": "调研一下 GraphRAG 的适用场景"}]})
print(result["messages"][-1].text)  # （示意）一份综合了研究员结论的报告
```

消息流（调试时可以打印 `result["messages"]` 对照）：

```text
Human: 调研一下 GraphRAG 的适用场景
AI:     Tool Calls: researcher({'query': '...'})        ← 主管决定派活
Tool:  （子智能体的最终结论）                            ← 结论，不是过程
AI:     （主管基于结论写的最终报告）
```

**关键观察：主管只看到结论，看不到子智能体的中间推理。**
这正是上下文隔离的意义——子智能体可以翻 20 个网页，
主管的上下文里只多一条最终结论。需要把子智能体结果写回主状态时，
用 `Command` 合并：

```python
def call_researcher(
    query: str,
    tool_call_id: Annotated[str, InjectedToolCallId],
) -> Command:
    result = researcher.invoke({"messages": [{"role": "user", "content": query}]})
    return Command(update={
        "research_notes": result["research_notes"],
        "messages": [ToolMessage(
            content=result["messages"][-1].content,
            tool_call_id=tool_call_id,
        )],
    })
```

需要定制的四个位置：子智能体的**名称**、**描述**（直接决定主智能体
何时调用它）、**对子智能体的输入**（修改提示，或从状态注入消息历史）、
**来自子智能体的输出**（指定返回内容，或自定义输出格式化）。

::: warning 常见失败模式
子智能体完成了工具执行与推理，**却没有把结论放进最终消息**——
控制器与用户只能看到中间过程，任务因此看似"无产出"。
子智能体的系统提示词里要明确要求"最后一条消息必须是结论"。
:::

官方强调：多智能体系统的质量**严重依赖于上下文工程**——
每个子智能体看到什么状态片段、是否包含中间推理，直接决定其表现。
用作工具的子智能体不期望与用户对话；需要对话时应改用交接模式。

## 4. 长期记忆

长期记忆让智能体**跨对话**保存并召回信息，
与仅限单线程的[短期记忆](/langchain/context-output#1-短期记忆)互补。
底层是 LangGraph 存储（`BaseStore`），数据以 JSON 文档保存，
用**命名空间 + 键**组织——命名空间类似文件夹，键类似文件名。

### 4.1 创建存储

```python
from langgraph.store.memory import InMemoryStore

store = InMemoryStore()      # 仅开发使用
# 生产：PostgresStore.from_conn_string(DB_URI) 后调用 store.setup()

agent = create_agent(model=..., tools=[...], store=store)
```

生产须使用数据库支撑的实现（PostgreSQL、Redis、MongoDB）。
需要向量检索时，为 `InMemoryStore(index=IndexConfig(embed=embed, dims=n))`
配置嵌入即可支持 `store.search(..., query=...)` 的语义查询。

### 4.2 从工具读写

```python
@tool
def save_user_info(user_info: UserInfo, runtime: ToolRuntime[Context]) -> str:
    """保存用户资料。"""
    assert runtime.store is not None
    runtime.store.put(("users",), runtime.context.user_id, dict(user_info))
    return "用户资料已保存。"
```

读取：

```python
runtime.store.get(("users",), user_id)   # 返回 StoreValue：value + metadata
```

命名空间可含用户 ID、组织 ID 等标签以支持层级组织与跨命名空间过滤。
`assert runtime.store is not None` 是必要的——
未配置 `store` 时该属性为 `None`。

**名词解释：命名空间 + 键。** `put(namespace, key, value)` 的三段式：
`("users",)` 是文件夹，`user_id` 是文件名，`dict(user_info)` 是内容。
`store.get(namespace, key)` 精确取，`store.search(namespace)` 列目录，
`store.search(namespace, query="...")` 语义搜（需配嵌入）。
想要"按用户隔离"，就把 user_id 编进命名空间或键里。

## 5. 护栏

护栏在关键节点验证与过滤内容：防 PII 泄露、阻止提示词注入、屏蔽有害内容、
执行业务与合规规则、验证输出质量。实现方式同样是**中间件**。

官方区分两类互补手段：

| 类型 | 特点 |
| --- | --- |
| **确定性护栏** | 正则、关键词、显式检查——快、可预测、低成本，但可能漏掉细微违规 |
| **基于模型的护栏** | LLM 或分类器语义评估——能发现规则遗漏，但更慢更贵 |

**名词解释：为什么需要两类。** 正则能挡住 `sk-[a-zA-Z0-9]{32}` 这种
有固定形状的东西，但挡不住"委婉索要密钥"的话术；模型反过来，
能理解语义但不稳定、慢、花钱。生产上两者叠加：
确定性护栏做第一道粗筛，模型护栏兜细腻场景。

### 5.1 内置护栏：PII 检测

```python
from langchain.agents.middleware import PIIMiddleware

PIIMiddleware("api_key", detector=r"sk-[a-zA-Z0-9]{32}", strategy="block",
              apply_to_input=True)
```

| 策略 | 效果 |
| --- | --- |
| `redact` | `[REDACTED_EMAIL]` |
| `mask` | `****-****-****-1234` |
| `hash` | 确定性哈希 |
| `block` | 抛出异常 |

内置类型：`email`、`credit_card`（含 Luhn 校验）、`ip`、`mac_address`、`url`。
当 `apply_to_output=True` 时还会经注册的流转换器**遮蔽流式输出**
（文本增量、工具调用参数、工具输出、状态快照），需 `langchain>=1.3.2`。

### 5.2 内置护栏：人在回路

适用于金融转账、删除或修改生产数据、对外发送消息：

```python
interrupt_on={"send_email": True, "delete_database": True, "search": False}
```

配置与恢复方式见上文[人在回路](#2-人在回路human-in-the-loop)一节。

### 5.3 自定义护栏

**执行前**（`before_agent`）——身份验证、速率限制、阻断不当请求：

```python
@before_agent(can_jump_to=["end"])
def content_filter(state: AgentState, runtime) -> dict | None:
    if contains_forbidden(state["messages"]):
        return {"messages": [{"role": "assistant", "content": "该请求无法处理。"}],
                "jump_to": "end"}
    return None
```

**执行后**（`after_agent`）——模型安全检查、质量验证、合规扫描：

```python
@after_agent(can_jump_to=["end"])
def safety_guardrail(state: AgentState, runtime) -> dict | None:
    verdict = judge.invoke(...)      # 例如 gpt-5.4-mini 判定 SAFE / UNSAFE
    ...
```

多个护栏加入 `middleware` 数组即**按顺序执行**，形成分层防护。
顺序原则同第 5 章总述：**确定性在前，模型在后**。

## 6. 关于检索（RAG）

官方文档的"检索"页面目前为占位页，尚无正文内容。
需要 RAG 相关实现时，应参考 LangChain 官方英文文档或
`langchain` 的 retriever 组件，而非该页。

## 7. 版本要求汇总

高级能力对版本有若干隐性依赖，部署前建议集中核对：

| 能力 | 要求 |
| --- | --- |
| 条件中断 `when` | `langchain>=1.3.3` |
| PII 流式遮蔽 | `langchain>=1.3.2` |
| `ProviderStrategy(strict=...)` | `langchain>=1.2` |
| `execution_info` / `server_info` | `deepagents>=0.5.0` 或 `langgraph>=1.1.5` |
| `version="v2"` 流式格式（`StreamPart` / `GraphOutput`） | LangGraph 1.1+ |
| 事件流类型化投影 API（`stream_events` v3） | LangChain v1.3+ |
| MCP 适配器 | `langchain[mcp]>=1.4.0`（Beta） |

## 8. 小结

- 上下文工程是方法论：区分模型、工具、生命周期三类上下文，
  以及临时更新与持久更新的差别——一切"模型看到什么"的问题
  都往这个坐标系里归位。
- 人在回路与护栏均依赖中间件与 checkpointer，`respond` 不可用于拒绝副作用操作。
- 多智能体的本质仍是上下文工程：控制每个子智能体看到什么、交出什么；
  先确认瓶颈再拆分。
- 长期记忆经 `store` 跨对话存取，生产必须使用数据库后端。
- 高级能力多有最低版本要求，上线前应集中核对。

[返回栏目首页](/langchain/)
