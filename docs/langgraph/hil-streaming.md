# 人机协作与流式输出

本篇为本栏目最后一篇，讨论两项使智能体由演示走向生产的能力：
**人工可介入**，以及**过程可观测**。

## 一、人机协作（HIL）

### 必要性

模型输出可能需要验证、更正或补充上下文。
"由 AI 直接发送邮件"与"AI 起草、人工确认后发送"，风险等级截然不同。

文档归纳的两项关键能力：

- **持久化执行状态**：每步之后均产生检查点，因此可**无限期暂停**——
  审核可完全异步，跨越任意时长。
- **灵活的介入位置**：HIL 逻辑可置于工作流的**任意位置**，而非仅限首尾。

### 三类典型用例

1. **审查工具调用**：工具执行**之前**，人工可查看、修改参数或直接否决。
2. **验证模型输出**：生成内容交由人工审阅、编辑或批准。
3. **补充上下文**：智能体主动询问"该需求指 A 还是 B？"，支持多轮澄清。

### 实现仅涉及两个原语

```text
interrupt(...)          在指定位置暂停，将信息抛出供人工处理
Command(resume=...)     将人工输入回填，自断点继续执行
```

完整流程如下：

```python
from langgraph.types import interrupt, Command

def human_review(state):
    decision = interrupt({
        "question": "是否批准这次工具调用？",
        "tool_call": state["pending_call"],
    })
    if decision["approved"]:
        return {"messages": [...]}          # 放行
    return {"messages": [AIMessage("已取消")]}

# 首次执行至 interrupt 时抛出，图停驻于该处
graph.invoke(input, config)

# 审核完成后，以 Command(resume=...) 恢复
graph.invoke(Command(resume={"approved": True}), config)
```

::: warning 前置条件：必须挂载 checkpointer
`interrupt` 的本质是"保存状态并停止"。**若无 checkpointer 则无状态可存**，
该前置条件若被忽略，`interrupt` 将无法生效。
:::

另有两个相关概念，均为 checkpointer 的衍生能力（前一篇已述）：

- **断点（Breakpoints）**：较为"静态"的方式，在编译时声明于某节点前停止。
  `interrupt()` 属"动态"方式，可在节点内部依据运行时条件决定是否停止。
- **时间旅行（Time Travel）**：从任意历史检查点分叉重跑。
  人工驳回后若需考察"另一选择的结果"，即依赖该能力。

### 一项配套设计

`interrupt()` 抛出的信息可携带结构化载荷（问题、待审的工具调用、候选选项等），
前端可直接渲染，无需另行组织 UI 数据。

## 二、流式输出（Streaming）

聊天界面的逐字显示、后台任务的进度提示，均依赖该机制。

### 可流式传输的三类数据

1. **工作流进度**：每个图节点执行后的状态更新（"正在调用搜索工具"）。
2. **LLM token**：模型生成时的逐字输出（逐字显示效果的来源）。
3. **自定义更新**：开发者自行发出的信号，例如"已抓取 10/100 条"。

### 五种 stream mode

下表为本节的核心内容：

| mode | 输出内容 | 典型用途 |
| --- | --- | --- |
| `values` | 每步之后的**完整状态** | 渲染整体状态快照 |
| `updates` | **增量**，`{节点名: 本次更新}` | 进度提示："某节点已完成" |
| `messages` | LLM **token** 及元数据 | 逐字显示 |
| `custom` | 节点通过 `get_stream_writer()` 主动发送的数据 | 进度通知、自定义事件 |
| `debug` | 详细跟踪信息 | 问题排查 |

调用方式：

```python
for chunk in graph.stream(input, stream_mode="updates"):
    print(chunk)

for mode, chunk in graph.stream(input, stream_mode=["messages", "updates"]):
    # 可同时请求多种模式
    ...
```

文档明确列出的几项能力：

- **任意位置的 token 流均可捕获**——节点内、子图中、工具内均适用。
- **工具可发送进度**：在工具函数内直接发出自定义更新（"已检索 3/10 个文档"）。
- **子图的流可向上传递**：父图与任意嵌套子图的输出均可获取。
- **不绑定 LangChain 模型**：即使使用其他 LLM SDK，也可通过 `custom` 模式自行输出 token。
- **多模式并用**：将 mode 传入列表即可。

### 接入前端时的两点注意

1. **token 流需要自行拼接**：`messages` 模式输出的是片段，
   同一 message id 的 chunk 应累加，而非每收到一个 chunk 就新增一条消息，
   否则消息列表将被碎片化。
2. **不应只使用 `messages`**：`updates` 才能反映当前所处步骤。
   仅有 token 流时，无法区分智能体是在思考还是已停滞。

（上述两点来自工程实践经验，官方文档未作特别强调。）

## 三、整合示例：带审核的流式智能体

```python
from langgraph.checkpoint.postgres import PostgresSaver
from langgraph.types import interrupt, Command

checkpointer = PostgresSaver.from_conn_string(DATABASE_URL)
graph = workflow.compile(checkpointer=checkpointer)

config = {"configurable": {"thread_id": user_session_id}}

# 前端发起
for mode, chunk in graph.stream(user_input, config, stream_mode=["messages", "updates"]):
    emit(mode, chunk)          # 通过 SSE / WebSocket 推送至浏览器

# 若图停驻于 interrupt → 后端收到审核事件
if needs_approval(config):
    show_review_ui()           # 渲染 interrupt 的载荷

# 人工确认后
graph.invoke(Command(resume={"approved": True}), config)
```

整条链路的分工：

```text
PostgresSaver   →  中断可恢复、人工可中途介入
interrupt/resume →  审核门禁
stream_mode     →  逐字显示 + 步骤进度
```

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

- **LangGraph Platform / Studio**：托管部署与可视化调试。
- **MCP 集成**、**评估（Evals）**、**UI 组件**。
- **函数式 API**（`@task` / `@entrypoint`，无需显式建图的另一种写法）。
- **子图在不同状态模式下的输入输出转换**。

需要时可另行补充，亦可直接参阅[官方文档](https://langgraph.com.cn/)——
其目录结构与本栏目各篇的顺序基本一致。

::: tip 资料
- 概念文档：[langgraph.com.cn](https://langgraph.com.cn/)
- 官方课程：[Intro to LangGraph](https://academy.langchain.com/courses/intro-to-langgraph)
- 本栏目首页：[LangGraph 学习笔记](/langgraph/)
:::
