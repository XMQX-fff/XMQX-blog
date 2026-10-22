# 中间件与运行时

中间件是 LangChain 控制智能体执行流程的唯一入口，
运行时（Runtime）则是向工具与中间件注入依赖的通道。
两者共同回答一个问题：**如何精确控制"模型调用 → 工具执行 → 结束"这一循环**。

## 怎么读本篇

- 2.1 节把"钩子什么时候运行"画出来是读懂本篇的前提，别跳过；
- 预置中间件按"记忆 / 安全 / 限制 / 效率"分组，每组都给了
  **什么时候该用**的判据，可以当选型清单用；
- `Runtime` 部分回答"工具和中间件怎么拿到用户身份、存储这类依赖"。

## 1. 中间件概览

### 1.1 它到底是什么

**名词解释：中间件（middleware）。** 挂在智能体循环各环节上的**可插拔
逻辑片**。不用改核心代码，就能在"模型调用前/后""工具调用前后""整个智能体
开始前/结束后"插入自己的代码。这是 v1 的核心设计：核心循环保持最小，
所有增强能力（摘要、护栏、重试、审批……）都做成中间件。

中间件在核心循环的**之前**与**之后**暴露钩子（hooks），承担四类职责：

| 职责 | 说明 | 例 |
| --- | --- | --- |
| 监控 | 日志、分析、调试 | 追踪记录、`after_agent` 校验 |
| 修改 | 调整提示词、工具选择、输出格式 | `@dynamic_prompt`、`request.override` |
| 控制 | 重试、回退、提前终止 | `ToolRetryMiddleware`、`ModelFallbackMiddleware` |
| 强制执行 | 速率限制、护栏、PII 检测 | `ModelCallLimitMiddleware`、`PIIMiddleware` |

钩子在循环里的位置：

```text
@before_agent ─┐
               ▼
        ┌─▶ 模型调用 ◀── @before_model / wrap_model_call / dynamic_prompt
        │      │
        │      ▼
        │   要调用工具？──否──▶ @after_model ─▶ @after_agent ─▶ 结束
        │      │是
        │      ▼
        └── 工具执行 ◀── wrap_tool_call （每个工具一次）
```

注入方式就是往 `create_agent` 传一个列表：

```python
agent = create_agent(
    model="openai:gpt-5.5",
    tools=[...],
    middleware=[SummarizationMiddleware(...), ToolRetryMiddleware(...)],
)
```

数组顺序 = 执行顺序（见第 5 节）。

## 2. 两种编写方式

### 2.1 先分清两类钩子

这是本篇**最重要的概念**，官方文档用"节点式/包装式"区分：

**节点式钩子（node-style）**：在固定时机**顺序运行**的逻辑片，
接收 `state` 和 `runtime`，返回 `dict | None`（None = 什么都不改）。
它的作用是在流程里"插入一步"：

```python
from langchain.agents.middleware import before_agent, before_model, after_model, after_agent
from langgraph.runtime import Runtime


@after_model(can_jump_to=["end"])
def validate_output(state: AgentState, runtime: Runtime) -> dict | None:
    """模型回答后检查：包含 BLOCKED 就把回答换掉并结束。"""
    last = state["messages"][-1]
    if "BLOCKED" in last.text:
        return {
            "messages": [AIMessage("我不能回答这个请求。")],
            "jump_to": "end",   # 直接跳到"结束"，不再进入下一步
        }
    return None
```

**名词解释：`can_jump_to`。** 声明这个钩子**允许跳转到哪些目标**。
节点式钩子默认只能改状态；想改控制流（提前结束、跳到某节点），
必须先在装饰器上登记目标，函数返回里才可以用 `jump_to`。
`@before_agent` / `@after_agent` 支持 `can_jump_to=["end"]`，
是实现"执行前拦截""执行后兜底"的标准手段。

**包装式钩子（wrap-style）**：把真正的调用**包起来**，
通过 `handler` 决定它被调用**零次（短路）、一次（正常）、多次（重试）**：

```python
from langchain.agents.middleware import wrap_model_call


@wrap_model_call
def retry_model(request, handler):
    for attempt in range(3):
        try:
            return handler(request)      # ← 真正调用模型的地方
        except Exception:
            if attempt == 2:
                raise
    ...
```

**名词解释：`handler`。** "继续执行原本流程"的入口。
包装式钩子的一切能力都来自对 `handler` 调用时机的控制：
不调用 = 短路（比如未授权直接拒绝，模型都不碰）；调用一次 = 正常放行；
循环调用 = 重试。**重试与动态改写必须用包装式实现**——节点式钩子
拿不到"正在进行的调用"，改不了它的输入。

### 2.2 装饰器 vs 类

| 方式 | 适用 | 说明 |
| --- | --- | --- |
| 装饰器（单钩子） | 简单场景、快速实现 | 一个函数一个钩子，无需类 |
| 类（多钩子） | 复杂配置、需复用 | 一个类里实现多个钩子、带 `__init__` 参数 |

```python
class MyMiddleware(AgentMiddleware):
    def before_model(self, state, runtime): ...
    def wrap_model_call(self, request, handler): ...
```

选择标准：单钩子、无复杂配置、不复用 → 装饰器；否则用类。

## 3. 预置中间件

官方中间件文档列举了 12 个常用预置实现，可直接组合使用
（langchain 1.4 起还提供了 `ModelRetryMiddleware`、`ToolErrorMiddleware`、
`ProviderToolSearchMiddleware` 等更多实现，以 API 参考为准）：

### 记忆与上下文

- **Summarization**：接近上下文窗口上限时自动摘要历史，适用于长期对话。
  触发条件用 `trigger=("tokens", 4000)`，保留策略用 `keep=("messages", 20)`：

  ```python
  SummarizationMiddleware(
      model="gpt-5.4-mini",      # 用便宜模型做摘要，主模型继续干正事
      trigger=("tokens", 4000),  # 4000 token 触发
      keep=("messages", 20),     # 保留最近 20 条
  )
  ```

- **ContextEditingMiddleware + ClearToolUsesEdit**：修剪、摘要或清除工具使用，
  `trigger=100000`、`keep=3`、`placeholder="[cleared]"`。
  与 Summarization 的分工：Summarization 压的是**对话正文**，
  ContextEditing 清的是**旧工具调用的明细**——工具结果往往是最占
  篇幅又最少被回顾的部分。

  ```python
  ContextEditingMiddleware(
      edits=[ClearToolUsesEdit(max_tokens=1000, keep=3,
                               placeholder="[已清理，节省上下文]")]
  )
  ```

### 人在回路与安全

- **HumanInTheLoop**：工具执行前暂停，供人工批准、编辑或拒绝。
  ⚠️ **需要 checkpointer 在中断期间维护状态**。
  完整配置与恢复流程见[上下文工程与高级能力](/langchain/advanced#2-人在回路human-in-the-loop)。

- **PIIMiddleware**：个人身份信息检测，策略 `block` / `redact` / `mask` / `hash`，
  `apply_to_input=True`（默认）、`apply_to_output=False`、
  `apply_to_tool_results=False`。四种策略的效果对照：

  | 策略 | 效果 |
  | --- | --- |
  | `redact` | 整段替换为 `[REDACTED_EMAIL]` |
  | `mask` | 打码保留部分，如 `****-****-****-1234` |
  | `hash` | 换成确定性哈希（同输入同哈希，可关联不可还原） |
  | `block` | 直接抛异常，拒绝执行 |

### 限制与回退

- **ModelCallLimitMiddleware**：限制模型调用次数，
  `thread_limit`（整个对话累计）/ `run_limit`（单次运行）/
  `exit_behavior`（`"end"` 优雅结束或 `"error"` 抛异常）。
  **防的是失控循环烧钱**——智能体陷入"调用工具→失败→再调用"死循环时，
  这是最后一道闸。

- **ToolCallLimitMiddleware**：同上，可用 `tool_name` 限定单个工具
  （比如"搜索工具最多调 5 次"）。

- **ModelFallbackMiddleware**：主模型失败后按序回退到 `first_model`
  与 `*additional_models`。典型用法：主力模型挂了自动切备用商，
  用户无感。

- **ToolRetryMiddleware**：指数回退，`backoff_factor=2.0`、
  `initial_delay=1.0`、`max_delay=60.0`、`jitter=True`（±25% 防惊群）；
  `on_failure` 默认 `"return_message"`（让模型看到失败并尝试别的办法），
  可选 `"raise"`（直接炸，适合"这个工具绝不能静默失败"的场景）。

### 效率与测试

- **Anthropic prompt caching**：缓存重复提示词前缀以降成本，
  `ttl` 仅支持 `"5m"` 或 `"1h"`。适合**系统提示词很长且多轮不变**的
  Agent——每轮都在付重复 token 的钱。

- **TodoListMiddleware**：⚠️ **自动为智能体注入 `write_todos` 工具与系统提示词**，
  结果可经 `result["todos"]` 读取。适合多步骤复杂任务，
  让模型自己拆解并跟踪进度。

- **LLMToolSelectorMiddleware**：先用便宜模型筛选工具，
  `max_tools` / `always_include`，适用于 10 个以上工具的场景
  （工具定义很占上下文，先瘦身再进主模型）。

- **LLMToolEmulator**：测试用，以 AI 生成的响应替换真实工具调用，
  `tools=None` 表示模拟全部。写单测或 Demo 时不用真连外部系统。

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
工具侧拿这五类信息的方式（外加状态、配置、调用 ID 共八类）
见 [components.md 3.3 节](/langchain/components#3-3-toolruntime访问运行时)；
中间件侧按钩子类型分两种入口：

```python
# 包装式：经 request.runtime
@dynamic_prompt
def prompt(request: ModelRequest) -> str:
    user_id = request.runtime.context.get("user_id", "guest")
    return f"你是服务于 {user_id} 的助手。"

# 节点式：经 runtime 参数
@before_model
def gate(state: AgentState, runtime: Runtime[Context]) -> dict | None:
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

为什么必须这个顺序：**廉价的检查在前，昂贵的在后**。①是纯字符串
匹配，微秒级；④是实打实的模型调用，秒级。顺序颠倒会让昂贵的检查
先于廉价的过滤执行；更糟的是敏感数据在人工审批前已经进了日志。

## 6. 小结

- 中间件是控制循环的唯一入口，分**节点式**（改状态，可 `jump_to`）
  与**包装式**（包住调用，可控零/一/多次执行）两类钩子；
- 官方文档列举的 12 个预置中间件覆盖记忆、安全、限制、回退、效率、
  测试六类需求，每个都对准一类具体症状；
- `Runtime` 提供 context / store / stream_writer / execution_info /
  server_info，等价于依赖注入；
- 组合次序即执行次序，护栏须按"廉价在前、昂贵在后"排列。

下一篇：[上下文工程与高级能力](/langchain/advanced)。
