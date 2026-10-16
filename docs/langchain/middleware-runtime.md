# 中间件与运行时

中间件是 LangChain 控制智能体执行流程的唯一入口，
运行时（Runtime）则是向工具与中间件注入依赖的通道。
两者共同回答一个问题：**如何精确控制"模型调用 → 工具执行 → 结束"这一循环**。

## 1. 中间件概览

中间件在核心循环的**之前**与**之后**暴露钩子（hooks），承担四类职责：

| 职责 | 说明 | 例 |
| --- | --- | --- |
| 监控 | 日志、分析、调试 | 追踪记录、`after_agent` 校验 |
| 修改 | 调整提示词、工具选择、输出格式 | `@dynamic_prompt`、`request.override` |
| 控制 | 重试、回退、提前终止 | `ToolRetryMiddleware`、`ModelFallbackMiddleware` |
| 强制执行 | 速率限制、护栏、PII 检测 | `ModelCallLimitMiddleware`、`PIIMiddleware` |

注入方式：

```python
agent = create_agent(
    model="openai:gpt-5.5",
    tools=[...],
    middleware=[SummarizationMiddleware(...), ToolRetryMiddleware(...)],
)
```

## 2. 两种编写方式

### 装饰器（单钩子、简单场景）

**节点式钩子**按顺序运行，返回 `dict | None`，可附带跳转指令：

```python
from langchain.agents.middleware import (
    before_agent, before_model, after_model, after_agent,
    wrap_model_call, wrap_tool_call, dynamic_prompt,
    AgentState, ModelRequest,
)

@dynamic_prompt
def personalized_prompt(request: ModelRequest) -> str:
    user_id = request.runtime.context.get("user_id", "guest")
    return f"你是服务于 {user_id} 的助手。"

@after_model(can_jump_to=["end"])
def validate_output(state: AgentState, runtime) -> dict | None:
    ...
```

**包装式钩子**可让 `handler` 被调用**零次（短路）、一次（正常）、多次（重试）**，
因而重试与动态改写必须用包装式实现。

### 类（多钩子、复杂配置、需复用）

```python
class MyMiddleware(AgentMiddleware):
    def before_model(self, state, runtime): ...
    def wrap_model_call(self, request, handler): ...
```

选择标准：单钩子、无复杂配置、不复用 → 装饰器；否则用类。

钩子一览：

| 类型 | 钩子 | 语义 |
| --- | --- | --- |
| 节点式 | `@before_agent` / `@before_model` / `@after_model` / `@after_agent` | 在对应节点前后插入或修改状态 |
| 包装式 | `@wrap_model_call` / `@wrap_tool_call` | 包裹调用过程，可短路或重试 |
| 便利 | `@dynamic_prompt` | 动态系统提示词的简写 |

`@before_agent` / `@after_agent` 支持 `can_jump_to=["end"]`，
是实现"执行前拦截""执行后兜底"的标准手段。

## 3. 预置中间件

官方中间件文档列举了 12 个常用预置实现，可直接组合使用
（langchain 1.4 起还提供了 `ModelRetryMiddleware`、`ToolErrorMiddleware`、
`ProviderToolSearchMiddleware` 等更多实现，以 API 参考为准）：

### 记忆与上下文

- **Summarization**：接近上下文窗口上限时自动摘要历史，适用于长期对话；
- **ContextEditingMiddleware + ClearToolUsesEdit**：修剪、摘要或清除工具使用，
  `trigger=100000`、`keep=3`、`placeholder="[cleared]"`。

### 人在回路与安全

- **HumanInTheLoop**：工具执行前暂停，供人工批准、编辑或拒绝。
  ⚠️ **需要 checkpointer 在中断期间维护状态**；
- **PIIMiddleware**：策略 `block` / `redact` / `mask` / `hash`，
  `apply_to_input=True`（默认）、`apply_to_output=False`、
  `apply_to_tool_results=False`。

### 限制与回退

- **ModelCallLimitMiddleware**：`thread_limit` / `run_limit` /
  `exit_behavior`（`"end"` 或 `"error"`），防止失控与成本失控；
- **ToolCallLimitMiddleware**：同上，可用 `tool_name` 限定单个工具；
- **ModelFallbackMiddleware**：主模型失败后按序回退到 `first_model`
  与 `*additional_models`；
- **ToolRetryMiddleware**：指数回退，`backoff_factor=2.0`、
  `initial_delay=1.0`、`max_delay=60.0`、`jitter=True`（±25% 防惊群）；
  `on_failure` 默认 `"return_message"`（让模型处理失败），可选 `"raise"`。

### 效率与测试

- **Anthropic prompt caching**：缓存重复提示词前缀以降成本，
  `ttl` 仅支持 `"5m"` 或 `"1h"`；
- **TodoListMiddleware**：⚠️ **自动为智能体注入 `write_todos` 工具与系统提示词**，
  结果可经 `result["todos"]` 读取；
- **LLMToolSelectorMiddleware**：先用便宜模型筛选工具，
  `max_tools` / `always_include`，适用于 10 个以上工具的场景；
- **LLMToolEmulator**：测试用，以 AI 生成的响应替换真实工具调用，
  `tools=None` 表示模拟全部。

## 4. 运行时（Runtime）

`create_agent` 底层运行于 LangGraph 运行时之上，
`Runtime` 对象提供五类信息：

| 类别 | 内容 |
| --- | --- |
| 上下文（context） | 单次调用的静态信息，经 `context=` 传入 |
| 存储（store） | `BaseStore`，用于长期记忆 |
| 流写入器（stream_writer） | 对应 `"custom"` 流模式 |
| 执行信息（execution_info） | `thread_id`、`run_id`、重试次数 |
| 服务器信息（server_info） | 助手 ID、图 ID、认证用户 |

官方强调：运行时上下文为工具与中间件提供**依赖注入**——
注入数据库连接、用户 ID 等，无需硬编码或全局状态，更易测试复用。

### 在工具中访问

```python
from dataclasses import dataclass

@dataclass
class Context:
    user_name: str
    user_id: str

@tool
def fetch_preferences(runtime: ToolRuntime[Context]) -> str:
    """读取用户偏好。"""
    user_id = runtime.context.user_id
    if runtime.store:
        if memory := runtime.store.get(("users",), user_id):
            return str(memory.value["preferences"])
    return "{}"
```

### 在中间件中访问

```python
@dynamic_prompt
def prompt(request: ModelRequest) -> str:      # 包装式经 request.runtime
    ...

@before_model
def gate(state: AgentState, runtime: Runtime[Context]) -> dict | None:  # 节点式经 runtime 参数
    ...
```

::: warning 版本要求
`server_info` 在**非 LangGraph Server 环境中为 `None`**；
`execution_info` / `server_info` 需要 `deepagents>=0.5.0` 或 `langgraph>=1.1.5`。
:::

## 5. 组合次序

中间件按传入数组的顺序执行，这一点在护栏场景中尤为关键。
官方建议的分层防护示例：

```text
① 确定性输入过滤（before_agent，关键词拦截并 jump_to="end"）
        ↓
② PII 检测（PIIMiddleware，redact / block）
        ↓
③ 人在回路（HumanInTheLoopMiddleware，敏感工具暂停审批）
        ↓
④ 模型安全检查（after_agent，由小模型判定 SAFE / UNSAFE）
```

顺序颠倒会导致昂贵的检查先于廉价的过滤执行，
或敏感数据在人工审批前已经进入日志。

## 6. 小结

- 中间件是控制循环的唯一入口，分节点式与包装式两类钩子。
- 官方文档列举的 12 个预置中间件覆盖记忆、安全、限制、回退、效率、测试六类需求。
- `Runtime` 提供 context / store / stream_writer / execution_info / server_info，
  等价于依赖注入。
- 组合次序即执行次序，护栏须按"廉价在前、昂贵在后"排列。

下一篇：[上下文工程与高级能力](/langchain/advanced)。
