# 人机协作与流式输出

本篇为栏目最后一篇，讨论两项使智能体由演示走向生产的能力：
**人工可介入**，以及**过程可观测**。

## 怎么读本篇

- 本篇所有例子**都不需要 API 密钥**（纯 LangGraph 图），装好
  `langgraph` 就能跑，适合边跑边学；
- "中断与恢复"一节是重点，例子从第一次 `invoke` 到人工恢复全程可复现；
- 流式部分同一个图反复用，方便对比五种模式的输出差异。

## 一、人机协作（HIL）

### 1.1 必要性

模型输出可能需要验证、更正或补充上下文。
“由 AI 直接发送邮件”与“AI 起草、人工确认后发送”，风险等级截然不同。

文档归纳的两项关键能力：

- **持久化执行状态**：每步之后均产生检查点，因此可**无限期暂停**——
  审核可完全异步，跨越任意时长（暂停三天再批，状态还在）。
- **灵活的介入位置**：HIL 逻辑可置于工作流的**任意位置**。

三类典型用例：

1. **审查工具调用**：工具执行**之前**，人工可查看、修改参数或直接否决；
2. **验证模型输出**：生成内容交由人工审阅、编辑或批准；
3. **补充上下文**：智能体主动询问“该需求指 A 还是 B？”，支持多轮澄清。

### 1.2 名词解释：中断与恢复

实现仅涉及两个原语：

```text
interrupt(...)          在指定位置暂停，将信息抛出供人工处理
Command(resume=...)     将人工输入回填，自断点继续执行
```

**名词解释：`interrupt(payload)`。** 在节点内部调用它，节点**当场冻结**，
`payload`（要给人看的信息）随之抛出；LangGraph 把当前状态写进检查点，
本次 `invoke` 就此返回。注意它是"存档退出"，不会抛异常，
进程退出都没关系，状态在 checkpointer 里。

**名词解释：`Command(resume=value)`。** 恢复执行的原语。
`value` 会成为 `interrupt(...)` 的**返回值**——就像函数被暂停后
拿到了入参继续跑。`resume` 的值此时正是 `interrupt()` 的返回值：

```python
def approval(state):
    decision = interrupt({"question": "是否批准？"})   # ← 这里冻结
    # 恢复后，decision 就是 Command(resume=...) 里带的那个值
    ...
```

::: warning 前置条件：必须挂载 checkpointer
`interrupt` 的本质是“保存状态并停止”。**若无 checkpointer 则无状态可存**，
该前置条件若被忽略，`interrupt` 将直接报错（本地测试也要显式传
`InMemorySaver()`，只有 LangGraph Platform 才默认提供）。
:::

### 1.3 完整可运行例子

存成 `approval.py` 直接运行。场景：智能体提议一次“删除 30 天前的旧数据”，
等人工批准后才执行：

```python
from typing import Annotated
import operator

from typing_extensions import TypedDict
from langgraph.graph import StateGraph, START, END
from langgraph.checkpoint.memory import InMemorySaver
from langgraph.types import Command, interrupt
from langchain_core.messages import AIMessage, HumanMessage


class State(TypedDict):
    messages: Annotated[list, operator.add]


def propose(state: State):
    """模型侧：提议一个敏感操作。"""
    return {"messages": [AIMessage(content="建议：删除 30 天前的订单数据（约 12 万条）")]}


def approval(state: State):
    """人工侧：在这里冻结，等决策。"""
    decision = interrupt({
        "question": "是否批准执行删除？",
        "tool": "delete_old_orders",
        "risk": "high",
    })
    if decision.get("approved"):
        return {"messages": [AIMessage(content="已执行删除，影响 119,842 条。")]}
    return {"messages": [AIMessage(content="已取消，未做任何改动。")]}


builder = StateGraph(State)
builder.add_node("propose", propose)
builder.add_node("approval", approval)
builder.add_edge(START, "propose")
builder.add_edge("propose", "approval")
builder.add_edge("approval", END)

graph = builder.compile(checkpointer=InMemorySaver())
config = {"configurable": {"thread_id": "demo-1"}}

# ---- 第一次运行：走到 interrupt 处停下 ----
result = graph.invoke({"messages": [HumanMessage(content="帮我清理下旧数据")]}, config)
print("第一次调用返回的消息数:", len(result["messages"]))
for m in result["messages"]:
    print("  -", type(m).__name__, ":", m.content[:30])
```

预期输出：

```text
第一次调用返回的消息数: 2
  - HumanMessage : 帮我清理下旧数据
  - AIMessage : 建议：删除 30 天前的订单数据（约 12 万条）
```

注意：只跑到 `propose`，**`approval` 里那条结果消息还没出现**——
因为图在 `interrupt` 处冻结了。想知道“现在卡在哪、等人做什么”，
用 `get_state` 查看：

```python
snapshot = graph.get_state(config)
print("待恢复节点:", snapshot.next)
task = snapshot.tasks[0]
print("中断载荷:", task.interrupts[0].value)
```

预期输出：

```text
待恢复节点: ('approval',)
中断载荷: {'question': '是否批准执行删除？', 'tool': 'delete_old_orders', 'risk': 'high'}
```

**名词解释：`next` / `tasks`。** `next` 是“接下来要跑哪些节点”的元组——
这里指向 `approval`，说明它还没执行完；`tasks` 携带该节点的待办信息，
`interrupts` 就是节点内部 `interrupt()` 抛出的内容。把 `value`
渲染成审核卡片，就是典型的前端 HIL 界面。

人工做完决策，用 `Command(resume=...)` 继续（**同样的 `thread_id`**）：

```python
final = graph.invoke(Command(resume={"approved": True}), config)
for m in final["messages"]:
    print("  -", type(m).__name__, ":", m.content[:30])
```

预期输出：

```text
  - HumanMessage : 帮我清理下旧数据
  - AIMessage : 建议：删除 30 天前的订单数据（约 12 万条）
  - AIMessage : 已执行删除，影响 119,842 条。
```

`interrupt()` 的返回值正是 `{"approved": True}`，所以分支走到了
“已执行”。如果传 `{"approved": False}`，最后一行会是“已取消”。

### 1.4 断点 vs `interrupt`

另有两个相关概念，均为 checkpointer 的衍生能力：

| 能力 | 设置时机 | 触发条件 | 适用 |
| --- | --- | --- | --- |
| **断点（breakpoints）** | 编译时静态声明（`interrupt_before=["node"]`） | 每次运行到必停 | 调试：每回合看状态 |
| **`interrupt()`** | 运行时动态判断 | 满足条件才停（可带参数） | 生产：按业务规则审批 |

一句话：**断点是“到站就停”的静态方案，`interrupt` 是“看情况停”的
动态方案**。两者都靠 checkpointer 存状态，恢复方式相同。

**时间旅行（Time Travel）**：从任意历史检查点分叉重跑。
人工驳回后若需考察“另一选择的结果”，即依赖该能力
（见[持久化与记忆](/langgraph/persistence-memory)）。

## 二、流式输出（Streaming）

聊天界面的逐字显示、后台任务的进度提示，均依赖该机制。

### 2.1 可流式传输的三类数据与五种模式

三类数据：

1. **工作流进度**：每个图节点执行后的状态更新（“正在调用搜索工具”）；
2. **LLM token**：模型生成时的逐字输出（逐字显示效果的来源）；
3. **自定义更新**：开发者自行发出的信号，例如“已抓取 10/100 条”。

对应五种 `stream_mode`：

| mode | 输出内容 | 典型用途 | 本节能跑吗 |
| --- | --- | --- | --- |
| `values` | 每步之后的**完整状态** | 渲染整体状态快照 | ✅ 纯图即可 |
| `updates` | **增量**，`{节点名: 本次更新}` | 进度提示：“某节点已完成” | ✅ 纯图即可 |
| `messages` | LLM **token** 及元数据 | 逐字显示 | 需要模型，见 2.4 |
| `custom` | 节点通过 `get_stream_writer()` 主动发送的数据 | 进度通知、自定义事件 | ✅ 纯图即可 |
| `debug` | 详细跟踪信息 | 问题排查 | ✅ |

调用方式：

```python
for chunk in graph.stream(input, stream_mode="updates"):
    print(chunk)

for mode, chunk in graph.stream(input, stream_mode=["messages", "updates"]):
    # 可同时请求多种模式（默认 v1 格式：(模式名, 数据) 元组）
    ...
```

### 2.2 `values` 与 `updates`：同一张图的两种视角

用 1.3 节的审批图当例子（把注释掉的中断去掉，让它无审批直接跑完）：

```python
# 沿用 approval.py 的图结构，但 approval 节点里不调 interrupt：
def approval(state: State):
    return {"messages": [AIMessage(content="已自动执行删除（演示）。")]}

graph = builder.compile(checkpointer=InMemorySaver())

print("=== values：每步后的完整状态 ===")
for chunk in graph.stream({"messages": [HumanMessage(content="清理")]},
                          config, stream_mode="values"):
    print(f"当前共 {len(chunk['messages'])} 条消息")

print("=== updates：每步的增量 ===")
for chunk in graph.stream({"messages": [HumanMessage("清理")]},
                          config, stream_mode="updates"):
    print(chunk)
```

预期输出：

```text
=== values：每步后的完整状态 ===
当前共 1 条消息
当前共 2 条消息
当前共 3 条消息
=== updates：每步的增量 ===
{'propose': {'messages': [AIMessage(content='建议：……')]}}
{'approval': {'messages': [AIMessage(content='已自动执行删除（演示）。')]}}
```

差别一眼可见：`values` 每步给**全量状态**（做状态快照渲染用），
`updates` 只给**这一步谁写了什么**（做进度条用）。**键名就是节点名**——
这就是“当前进行到哪一步”的直接答案。

### 2.3 `custom`：从节点内部发自定义信号

```python
from langgraph.config import get_stream_writer


def bulk_delete(state: State):
    writer = get_stream_writer()
    for i in range(1, 4):
        writer(f"已删除第 {i} 批，共 3 批")   # 任意 Python 对象
    return {"messages": [AIMessage(content="删除完成")]}


# add_node("bulk_delete", bulk_delete) ...
for chunk in graph.stream({"messages": []}, config, stream_mode="custom"):
    print("custom:", chunk)
```

预期输出：

```text
custom: 已删除第 1 批，共 3 批
custom: 已删除第 2 批，共 3 批
custom: 已删除第 3 批，共 3 批
```

`get_stream_writer()` 自动绑定当前执行上下文，无需手动传递写入器。
工具里也可以用（`runtime.stream_writer` 或 `get_stream_writer()`）。

### 2.4 `messages`：逐字输出（需要模型）

`messages` 模式透出的是模型生成的 token，因此必须挂一个真实模型。
LangChain 智能体上的完整示例见
[记忆·流式·结构化输出 2.1 节](/langchain/context-output#2-1-三种流模式)。

文档明确列出的几项能力（不限于某种框架）：

- **任意位置的 token 流均可捕获**——节点内、子图中、工具内均适用；
- **工具可发送进度**：在工具函数内直接发出自定义更新（“已检索 3/10 个文档”）；
- **子图的流可向上传递**：父图与任意嵌套子图的输出均可获取；
- **不绑定 LangChain 模型**：即使使用其他 LLM SDK，也可通过 `custom` 模式自行输出 token；
- **多模式并用**：将 mode 传入列表即可。

### 2.5 前端接入时的两点注意

1. **token 流需要自行拼接**：`messages` 模式输出的是片段，
   同一 message id 的 chunk 应累加；逐 chunk 新增消息会让列表碎片化。判断“这条消息拼完了”用
   `chunk_position == "last"`（详见 LangChain 栏目
   [context-output.md 2.2 节](/langchain/context-output#2-2-推理令牌与流式工具调用)）。
2. **不应只使用 `messages`**：`updates` 才能反映当前所处步骤。
   仅有 token 流时，无法区分智能体是在思考还是已停滞。

（上述两点来自工程实践经验，官方文档未作特别强调。）

## 三、整合示例：带审核的流式智能体

把前三章拼起来：**流式运行 → 撞上中断 → 把中断喂给前端 → 人工批准 → 恢复**。
这是可以直接跑的生产骨架，存成 `hil_stream.py`：

```python
from typing import Annotated
import operator

from typing_extensions import TypedDict
from langgraph.graph import StateGraph, START, END
from langgraph.checkpoint.memory import InMemorySaver
from langgraph.types import Command, interrupt
from langchain_core.messages import AIMessage, HumanMessage


class State(TypedDict):
    messages: Annotated[list, operator.add]


def propose(state: State):
    return {"messages": [AIMessage(content="建议：删除 30 天前的订单数据")]}


def approval(state: State):
    decision = interrupt({"question": "是否批准执行删除？", "tool": "delete_old_orders"})
    if decision.get("approved"):
        return {"messages": [AIMessage(content="已执行删除，影响 119,842 条。")]}
    return {"messages": [AIMessage(content="已取消，未做任何改动。")]}


builder = StateGraph(State)
builder.add_node("propose", propose)
builder.add_node("approval", approval)
builder.add_edge(START, "propose")
builder.add_edge("propose", "approval")
builder.add_edge("approval", END)

graph = builder.compile(checkpointer=InMemorySaver())
config = {"configurable": {"thread_id": "sess-42"}}

# ---- 1. 流式运行，同时监听审批中断 ----
interrupts = []
for mode, chunk in graph.stream(
    {"messages": [HumanMessage(content="帮我清理下旧数据")]},
    config,
    stream_mode=["messages", "updates"],   # 多模式：默认格式是 (模式名, 数据) 元组
):
    if mode == "updates" and "__interrupt__" in chunk:
        interrupts.extend(chunk["__interrupt__"])
        print("[后端] 收到审核请求:", chunk["__interrupt__"][0].value["question"])
    elif mode == "updates":
        node = next(iter(chunk))
        print(f"[进度] 节点 {node} 完成")

if interrupts:
    # ---- 2. 前端渲染审核卡片（payload 里什么都有）----
    print("[前端] 展示审核卡片:", interrupts[0].value)

    # ---- 3. 人工批准后恢复 ----
    final = graph.invoke(Command(resume={"approved": True}), config)
    print("[最终]", final["messages"][-1].content)
```

预期输出：

```text
[进度] 节点 propose 完成
[后端] 收到审核请求: 是否批准执行删除？
[前端] 展示审核卡片: {'question': '是否批准执行删除？', 'tool': 'delete_old_orders'}
[最终] 已执行删除，影响 119,842 条。
```

三点说明：

1. **中断是从 `updates` 流里收到的**（`mode == "updates"` 且数据里
   有 `__interrupt__` 键）——不需要额外轮询；多个工具同时挂起时
   `chunk["__interrupt__"]` 是一个列表，逐个处理；
2. `interrupts[0].value` 就是节点里 `interrupt(...)` 的载荷，
   字段你自己定（问题、工具名、参数、风险等级……），前端直接渲染；
3. 恢复时**必须用同一个 `config`**（同 `thread_id`），否则找不到存档。

整条链路的分工：

```text
PostgresSaver   →  中断可恢复、人工可中途介入
interrupt/resume →  审核门禁
stream_mode     →  逐字显示 + 步骤进度
```

生产环境把 `InMemorySaver` 换成 `PostgresSaver.from_conn_string(...)`
（记得 `.setup()`），`emit(...)` 换成你的 SSE/WebSocket 发送即可。

## 四、全栏目回顾

六篇文章串起来，LangGraph 的骨架可归结为一条主线：

```text
1. 图 API（State / Node / Edge）   ← 描述"流程的形态"
2. 超步 + reducer                  ← 决定"状态如何合并、如何并行"
3. checkpointer                    ← 使每一步均可回溯
         ├─→ 人机协作（interrupt / resume）
         ├─→ 时间旅行（回放 / 分叉）
         ├─→ 容错（pending writes 不重跑）
         └─→ 短期记忆（thread 内消息历史）
4. store                           ← 跨 thread 的长期记忆
5. stream                          ← 将过程实时输出至用户
6. Command / Send / 子图           ← 组织复杂拓扑与多智能体
```

**第 3 项是整个框架的枢纽。**
从结构上看，图 API 解决"流程如何表达"，checkpointer 解决"执行如何管理"，
其余能力皆由后者派生。

## 未覆盖的章节

本栏目聚焦概念主线，以下实操性内容尚未展开：

- **LangGraph Platform / Studio**：托管部署与可视化调试；
- **MCP 集成**、**评估（Evals）**、**UI 组件**；
- **函数式 API**（`@task` / `@entrypoint`，无需显式建图的另一种写法）；
- **子图在不同状态模式下的输入输出转换**。

需要时可另行补充，亦可直接参阅[官方文档](https://langgraph.com.cn/)——
其目录结构与本栏目各篇的顺序基本一致。

::: tip 资料
- 概念文档：[langgraph.com.cn](https://langgraph.com.cn/)
- 官方课程：[Intro to LangGraph](https://academy.langchain.com/courses/intro-to-langgraph)
- 本栏目首页：[LangGraph 学习笔记](/langgraph/)
:::
