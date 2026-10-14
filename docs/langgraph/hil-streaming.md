# 人机协作与流式输出

本栏目的最后一篇，讲两个"让 Agent 从 demo 变成能上线的东西"的功能：
**人插得进手**，和**过程吐得出来**。

## 一、人机协作（HIL）

### 为什么非得有它

模型输出可能需要验证、更正、或者补充上下文。
"让 AI 直接把邮件发出去"和"AI 起草、人点确认再发"，是两种完全不同的风险等级。

文档列的两个关键能力：

- **持久化执行状态**：每一步之后都检查点，所以可以**无限期暂停**——
  人今天下班了，明天回来接着审也行，完全异步。
- **灵活的集成点**：HIL 逻辑可以放在工作流的**任何位置**，不是只能在开头或结尾。

### 三个典型用例

1. **审查工具调用**：工具执行**之前**，人可以看一眼、改参数、或者直接否掉。
2. **验证 LLM 输出**：生成的内容让人过目/编辑/批准。
3. **提供上下文**：Agent 主动开口问人"你这个需求是指 A 还是 B？"，支持多轮澄清。

### 实现就两个原语

```text
interrupt(...)          在特定点暂停，把信息抛出去给人看
Command(resume=...)     把人给的值塞回来，从断点继续
```

完整长这样：

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

# 第一次跑到 interrupt 会抛出，图停在那儿
graph.invoke(input, config)

# 人审完，用 Command(resume=...) 恢复
graph.invoke(Command(resume={"approved": True}), config)
```

::: warning 必须先挂 checkpointer
`interrupt` 的本质是"存好状态然后停下"。**没有 checkpointer 就没有状态可存**，
这个前置条件我在读文档时一开始没当回事，结果就是 `interrupt` 根本不生效。
:::

配套还有两个概念，都是 checkpointer 的衍生品（上一篇讲过）：

- **断点（Breakpoints）**：更"静态"的做法，在编译时声明在某个节点前停下。
  `interrupt()` 是"动态"的，可以在节点内部根据运行时条件决定停不停。
- **时间旅行（Time Travel）**：从历史任意检查点分叉重跑。
  人驳回之后想"如果当时选了另一条会怎样"，这个能力就是干这个的。

### 一个额外的贴心设计

`interrupt()` 抛出的信息里可以带上结构化的载荷（问题、待审的工具调用、候选选项……），
前端直接渲染就行，不用自己另外拼一份 UI 数据。

## 二、流式输出（Streaming）

聊天界面要打字机效果，后台长任务要进度条——都靠它。

### 能流出来的东西有三类

1. **工作流进度**：每个图节点执行完之后的状态更新（"现在在调搜索工具"）。
2. **LLM token**：模型生成时逐字吐（打字机效果的来源）。
3. **自定义更新**：你自己发的信号，比如"已抓取 10/100 条"。

### 五种 stream mode

这是我认为最该背下来的表：

| mode | 吐什么 | 典型用途 |
| --- | --- | --- |
| `values` | 每步之后的**完整状态** | 想渲染整个状态快照 |
| `updates` | **增量**，`{节点名: 本次更新}` | 进度提示："a 节点完成了" |
| `messages` | LLM **token** + 元数据 | 打字机效果 |
| `custom` | 节点主动 `get_stream_writer()` 发的数据 | 进度通知、自定义事件 |
| `debug` | 详细跟踪 | 排查问题 |

用法：

```python
for chunk in graph.stream(input, stream_mode="updates"):
    print(chunk)

for mode, chunk in graph.stream(input, stream_mode=["messages", "updates"]):
    # 可以同时要多种模式
    ...
```

几个能力点，官方专门列了：

- **任何地方的 token 流都能抓到**——节点内、子图里、工具里，都能捕获。
- **工具能发进度**：直接在工具函数里发自定义更新（"查了 3/10 个文档"）。
- **子图的流会往上冒**：父图 + 任意嵌套子图的输出都能拿到。
- **不绑定 LangChain 模型**：即使你用的是别的 LLM SDK，也能用 `custom` 模式自己往外发 token。
- **多模式并用**：把 mode 传成列表就行。

### 前端接的时候我想过的两个坑

1. **token 流要自己拼**：`messages` 模式吐的是碎片，同一个 message id 的 chunk 要累加，
   不能每来一个 chunk 就往数组里 push 一条新消息（那会变成一堆碎消息）。
2. **别只留 `messages`**：`updates` 才能告诉用户"现在卡在哪一步"。
   纯 token 流看不出 Agent 是在思考还是卡死了。

（这两条是我结合自己做前端的经验写的，官方文档没有明确强调。）

## 三、串起来：一个"带审核的流式 Agent"大概长什么样

```python
from langgraph.checkpoint.postgres import PostgresSaver
from langgraph.types import interrupt, Command

checkpointer = PostgresSaver.from_conn_string(DATABASE_URL)
graph = workflow.compile(checkpointer=checkpointer)

config = {"configurable": {"thread_id": user_session_id}}

# 前端发起
for mode, chunk in graph.stream(user_input, config, stream_mode=["messages", "updates"]):
    emit(mode, chunk)          # SSE / WebSocket 推给浏览器

# 若图停在 interrupt 上 → 后端收到审批事件
if needs_approval(config):
    show_review_ui()           # 把 interrupt 的载荷渲染出来

# 人点了同意
graph.invoke(Command(resume={"approved": True}), config)
```

整条链路里：

```text
PostgresSaver  →  断了能接、人能中途插手
interrupt/resume → 审核门禁
stream_mode    →  打字机 + 步骤进度
```

## 四、整个栏目回顾

六篇读下来，LangGraph 的骨架其实就一条线：

```text
1. 图 API（State/Node/Edge）     ← 描述"流程长什么样"
2. 超步 + reducer                ← 决定"状态怎么合并、怎么并行"
3. checkpointer                  ← 让每一步都可回溯
        ├─→ 人机协作（interrupt/resume）
        ├─→ 时间旅行（回放/分叉）
        ├─→ 容错（pending writes 不重跑）
        └─→ 短期记忆（thread 内消息历史）
4. store                         ← 跨 thread 的长期记忆
5. stream                        ← 把过程实时吐给用户
6. Command / Send / 子图          ← 组织复杂拓扑，多智能体
```

**第 3 步是整个框架的枢纽。** 我读的时候是先囫囵吞枣看完图 API，
再回头补持久化才豁然开朗的——如果顺序反了，可能理解成本更低。

## 还没覆盖的部分

本栏目是"概念主线"，还有一些实操向的章节没展开：

- **LangGraph Platform / Studio**：托管部署、可视化调试。
- **MCP 集成**、**评估（Evals）**、**UI 组件**。
- **函数式 API**（`@task` / `@entrypoint`，不需要显式建图的另一种写法）。
- **子图的不同状态模式怎么接输入输出转换**。

需要的时候我再回来补。也欢迎直接啃[官方文档](https://langgraph.com.cn/)——
它的目录结构跟本栏目的文章顺序基本是一致的。

::: tip 资料
- 概念文档：[langgraph.com.cn](https://langgraph.com.cn/)
- 免费课程：[Intro to LangGraph](https://academy.langchain.com/courses/intro-to-langgraph)
- 本栏目首页：[LangGraph 学习笔记](/langgraph/)
:::
