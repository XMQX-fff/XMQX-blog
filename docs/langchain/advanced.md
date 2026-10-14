# 上下文工程与高级能力

本篇覆盖官方"高级用法"一组：上下文工程（方法论）、人在回路、多智能体、
长期记忆与护栏。这五者共同服务于"从原型到生产"这一跨越。

## 1. 上下文工程

### 为什么智能体会失败

官方指出两个原因：底层 LLM 能力不足，以及**未向模型提供"正确"的上下文**，
并认为多数情况下后者才是主因。上下文工程即"以正确格式提供适当的信息与工具"，
被称为 AI 工程师最重要的工作。其在 LangChain 中的落地机制是**中间件**。

### 三类上下文

| 类别 | 作用范围 | 生命周期 |
| --- | --- | --- |
| **模型上下文** | 进入模型调用的内容：指令、消息历史、工具、响应格式 | 临时 |
| **工具上下文** | 工具可读写的状态、存储、运行时上下文 | 持久 |
| **生命周期上下文** | 模型与工具调用之间：摘要、护栏、日志 | 持久 |

三类数据源贯穿始终：**运行时上下文**（静态配置，对话级）、
**状态**（短期记忆，对话级）、**存储**（长期记忆，跨对话）。

### 模型上下文的五个要素

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

两者混淆会带来"改了却没生效"或"不该留下却被永久写入"的问题。
:::

工具的说明同样属于上下文——**工具定义不只是元数据，它们会引导模型**：
过多导致上下文过载，过少则限制能力。

### 六条最佳实践

1. 从简单方案开始；
2. 增量测试，每次只加一项功能；
3. 监控性能（调用次数、token、延迟）；
4. 优先使用内置中间件；
5. 记录上下文策略；
6. 理解临时更新与持久更新的区别。

## 2. 人在回路（Human-in-the-Loop）

当模型提出敏感操作（写文件、执行 SQL、转账、发信）时暂停执行，
图状态经 LangGraph 持久化层保存，由人工决定后再继续。

### 四种决策

| 决策 | 行为 |
| --- | --- |
| `approve` | 原样执行 |
| `edit` | 执行前修改参数 |
| `reject` | 跳过执行，返回拒绝反馈 |
| `respond` | 跳过执行，把人工消息作为**合成工具结果** |

::: danger 注意
不要用 `respond` 拒绝**带副作用**的工具——其消息会被视为成功结果。
多个工具同时暂停时，**决策顺序必须与中断请求中的操作顺序一致**。
编辑参数需谨慎，大幅修改可能让模型重新评估方案、重复执行或意外操作。
:::

### 配置

```python
from langchain.agents.middleware import HumanInTheLoopMiddleware
from langgraph.checkpoint.memory import InMemorySaver

agent = create_agent(
    model="openai:gpt-5.5",
    tools=[write_file, execute_sql, read_data],
    middleware=[HumanInTheLoopMiddleware(
        interrupt_on={
            "write_file": True,
            "execute_sql": {"allowed_decisions": ["approve", "reject"]},
            "read_data": False,
        },
        description_prefix="工具执行待审批",
    )],
    checkpointer=InMemorySaver(),     # 必须
)
```

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
# {"type": "respond", "content": "..."}
```

**条件中断**可用 `when` 谓词按请求内容决定是否暂停
（需 `langchain>=1.3.3`）：

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

### 何时需要拆分

单个智能体出现下列信号时，应考虑多智能体：

- **工具过多**，模型难以稳定选择；
- **上下文或记忆过于庞大**；
- 任务本身需要**专业化分工**（规划者、研究员、数学专家）。

### 两种模式

| 模式 | 控制流 | 适用 |
| --- | --- | --- |
| **工具调用**（主管把子智能体当工具） | 集中式 | 任务编排、结构化工作流 |
| **交接**（Handoffs，转移控制权） | 分散式 | 多领域对话、专家接管 |

选择依据：需要集中式控制 → 工具调用；
希望智能体直接与用户交互 → 交接；两者**可混合使用**。

### 工具调用模式

四步流程：控制器决定 → 工具智能体运行 → 返回结果 → 控制器继续或完成。

```python
researcher = create_agent(model="openai:gpt-5.5", tools=[...])

@tool("researcher", description="针对给定主题执行深度调研并返回结论")
def call_researcher(query: str) -> str:
    """调用调研子智能体。"""
    result = researcher.invoke({"messages": [{"role": "user", "content": query}]})
    return result["messages"][-1].content

agent = create_agent(model="openai:gpt-5.5", tools=[call_researcher])
```

需要把子智能体结果写回主状态时，用 `Command` 合并：

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

### 需要定制的四个位置

1. 子智能体的**名称**；
2. 子智能体的**描述**（直接决定主智能体何时调用它）；
3. **对子智能体的输入**（修改提示，或从状态注入消息历史）；
4. **来自子智能体的输出**（指定返回内容，或自定义输出格式化）。

::: warning 常见失败模式
子智能体完成了工具执行与推理，**却没有把结论放进最终消息**——
控制器与用户只能看到中间过程，任务因此看似"无产出"。
:::

官方强调：多智能体系统的质量**严重依赖于上下文工程**——
每个子智能体看到什么状态片段、是否包含中间推理，直接决定其表现。
用作工具的子智能体不期望与用户对话；需要对话时应改用交接模式。

## 4. 长期记忆

长期记忆让智能体**跨对话**保存并召回信息，
与仅限单线程的[短期记忆](/langchain/context-output#1-短期记忆)互补。
底层是 LangGraph 存储（`BaseStore`），数据以 JSON 文档保存，
用**命名空间 + 键**组织——命名空间类似文件夹，键类似文件名。

### 创建存储

```python
from langgraph.store.memory import InMemoryStore

store = InMemoryStore()      # 仅开发使用
# 生产：PostgresStore.from_conn_string(DB_URI) 后调用 store.setup()

agent = create_agent(model=..., tools=[...], store=store)
```

生产须使用数据库支撑的实现（PostgreSQL、Redis、MongoDB）。
需要向量检索时，为 `InMemoryStore(index=IndexConfig(embed=embed, dims=n))`
配置嵌入即可支持 `store.search(..., query=...)` 的语义查询。

### 从工具读写

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

## 5. 护栏

护栏在关键节点验证与过滤内容：防 PII 泄露、阻止提示词注入、屏蔽有害内容、
执行业务与合规规则、验证输出质量。实现方式同样是**中间件**。

官方区分两类互补手段：

| 类型 | 特点 |
| --- | --- |
| **确定性护栏** | 正则、关键词、显式检查——快、可预测、低成本，但可能漏掉细微违规 |
| **基于模型的护栏** | LLM 或分类器语义评估——能发现规则遗漏，但更慢更贵 |

### 内置护栏：PII 检测

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

### 内置护栏：人在回路

适用于金融转账、删除或修改生产数据、对外发送消息：

```python
interrupt_on={"send_email": True, "delete_database": True, "search": False}
```

配置与恢复方式见上文[人在回路](#2-人在回路human-in-the-loop)一节。

### 自定义护栏

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
| 类型化投影 API / `version="v2"` | LangGraph 1.1+ |
| MCP 适配器 | `langchain[mcp]>=1.4.0`（Beta） |

## 8. 小结

- 上下文工程是方法论：区分模型、工具、生命周期三类上下文，
  以及临时更新与持久更新的差别。
- 人在回路与护栏均依赖中间件与 checkpointer，`respond` 不可用于拒绝副作用操作。
- 多智能体的本质仍是上下文工程：控制每个子智能体看到什么、交出什么。
- 长期记忆经 `store` 跨对话存取，生产必须使用数据库后端。
- 高级能力多有最低版本要求，上线前应集中核对。

[返回栏目首页](/langchain/)
