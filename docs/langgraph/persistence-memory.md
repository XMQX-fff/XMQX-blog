# 持久化与记忆：Checkpointer、Store 与长对话

此前各篇多次提及"挂载 checkpointer 即可支持多轮对话"，本篇对此展开说明。
理解本篇后可知：断点续跑、时间旅行、人工介入与长期记忆，
**本质上是同一套机制的不同应用**。

## 一、持久化层：Checkpointer

> 使用 checkpointer 编译图之后，**每个超步**均会保存一份图状态快照（checkpoint），
> 这些快照存入一个 **thread**。

三个术语须先区分：

| 术语 | 含义 |
| --- | --- |
| **Thread** | 一次会话或执行序列的唯一 ID，是快照的容器 |
| **Checkpoint** | 某个超步结束时的状态快照 |
| **StateSnapshot** | 读取得到的快照对象（含 values / next / metadata / config / tasks） |

调用时**必须**提供 `thread_id`：

```python
config = {"configurable": {"thread_id": "1"}}
```

::: tip LangGraph API 自动处理
若使用 LangGraph Platform / API，检查点器与存储均由平台在后台配置，
无需自行实现。以下内容针对自托管场景。
:::

### 示例：快照数量

```python
from langgraph.graph import StateGraph, START, END
from langgraph.checkpoint.memory import InMemorySaver

class State(TypedDict):
    foo: str
    bar: Annotated[list[str], add]

def node_a(state): return {"foo": "a", "bar": ["a"]}
def node_b(state): return {"foo": "b", "bar": ["b"]}

workflow = StateGraph(State)
workflow.add_node(node_a)
workflow.add_node(node_b)
workflow.add_edge(START, "node_a")
workflow.add_edge("node_a", "node_b")
workflow.add_edge("node_b", END)

graph = workflow.compile(checkpointer=InMemorySaver())
graph.invoke({"foo": ""}, {"configurable": {"thread_id": "1"}})
```

执行后共产生 **4 个**快照：

```text
1. 空快照                        输入尚未写入
2. 输入后 {'foo':'', 'bar':[]}    next = ('node_a',)
3. A 之后 {'foo':'a','bar':['a']} next = ('node_b',)
4. B 之后 {'foo':'b','bar':['a','b']} next = () → 结束
```

注意 `bar` 为 `['a', 'b']`——由于 `bar` 配置了 reducer，A 与 B 的贡献均被保留；
**未配置 reducer 的 `foo` 仅保留最后一个值**。此即前一篇强调 reducer 的原因。

### 读取状态

```python
# 最新状态
graph.get_state(config)

# 指定快照
graph.get_state({"configurable": {"thread_id": "1", "checkpoint_id": "1ef663ba-..."}})

# 完整历史（按时间倒序，最近者在前）
list(graph.get_state_history(config))
```

`StateSnapshot` 中最常用的是 `values`（当前状态）与 `next`（待执行节点），
可直接定位执行所处位置。

### 回放（Replay）

```python
config = {"configurable": {"thread_id": "1", "checkpoint_id": "0c62ca34-..."}}
graph.invoke(None, config=config)
```

语义为：**自该 checkpoint 之后重新执行**，之前的步骤直接回放而不重算。

需要留意：`checkpoint_id` **之后**的步骤即使曾经执行过，也会**重新执行**
（相当于开辟新分支）。由此延伸出"时间旅行"——从任意历史点分叉，探索其他路径。

### 更新状态（可修改历史）

```python
graph.update_state(config, {"foo": 2, "bar": ["b"]}, as_node="node_a")
```

三个参数中有两项容易产生误解：

- **`values`**：更新遵循**与节点更新完全相同的路径**——配置了 reducer 的键执行归约，
  未配置的才覆盖。设当前为 `{"foo": 1, "bar": ["a"]}`，更新为 `{"foo": 2, "bar": ["b"]}`，
  结果是 `{"foo": 2, "bar": ["a", "b"]}`（`foo` 覆盖，`bar` 追加）。
- **`as_node`**：声明此次更新归属于哪个节点。**该参数决定后续执行哪个节点**——
  因为"下一步"取决于"最后修改状态者"。省略时将取最后更新状态的节点，
  存在歧义时结果可能不符合预期。

## 二、Store：跨会话的长期记忆

问题在于：checkpointer 将状态存入 thread，**不同 thread 之间互不可见**。
"该用户偏好简洁表达"这类信息，如何在第 1 次与第 50 次对话中均可用？

答案是 **Store**——一个独立于 thread 的键值存储：

```python
from langgraph.store.memory import InMemoryStore

store = InMemoryStore()

namespace = (user_id, "memories")          # 类似文件夹
store.put(namespace, memory_id, {"food_preference": "I like pizza"})

memories = store.search(namespace)          # 读取
```

编译时两者**同时**挂载：

```python
graph = workflow.compile(checkpointer=checkpointer, store=store)
```

职责划分明确：

```text
checkpointer  →  线程内（短期）  "本场对话进行到何处"
store         →  跨线程（长期）  "该用户是谁、偏好如何"
```

### 在节点中访问 Store

节点额外接收一个 `store` 参数（关键字注入），命名空间由配置中的 `user_id` 决定：

```python
from langgraph.store.base import BaseStore

def call_model(state, config: RunnableConfig, *, store: BaseStore):
    user_id = config["configurable"]["user_id"]
    namespace = (user_id, "memories")
    memories = store.search(namespace, query=state["messages"][-1].content, limit=3)
    info = "\n".join([m.value["memory"] for m in memories])
    # 将 info 拼入提示词...
```

**语义搜索**：为 store 配置 embedding 后，`search` 支持按自然语言查询检索记忆，
而非依赖精确匹配：

```python
from langchain.embeddings import init_embeddings

store = InMemoryStore(index={
    "embed": init_embeddings("openai:text-embedding-3-small"),
    "dims": 1536,
    "fields": ["food_preference", "$"],   # 仅对这些字段建立索引
})
```

`fields` 中的 `"$"` 表示整个文档。`put` 时亦可用 `index=False` 将某条记忆排除出索引。

## 三、记忆：短期与长期

以上为机制，以下为**设计**。

```text
短期记忆（thread 范围）        长期记忆（跨 thread）
├─ 存储位置：图 State           ├─ 存储位置：Store
├─ 持久化：检查点               ├─ 持久化：任意命名空间
└─ 读写时机：每个步骤           └─ 任意时刻、任意线程均可召回
```

### 短期记忆的主要难点：长对话

对话历史是短期记忆最常见的形态，且持续增长。其后果有三层：

1. **超出容量**：超出上下文窗口将直接报错，且属不可恢复错误。
2. **效果劣化**：模型在长上下文下易被过时、跑题的内容干扰。
3. **延迟与成本上升**。

因此短期记忆管理本质上是**精确率、召回率、延迟与成本**之间的权衡。
三种常用手段如下：

**① 编辑消息列表**（最直接）

```python
from langchain_core.messages import RemoveMessage

def my_node(state: State):
    # 仅保留最近 2 条，其余按 ID 删除
    to_delete = [RemoveMessage(id=m.id) for m in state["messages"][:-2]]
    return {"messages": to_delete}
```

`add_messages` reducer 收到 `RemoveMessage` 时按 ID 删除该消息（随后丢弃指令本身）。
更彻底的做法是自定义 reducer，接受 `{"type": "keep", "from": -5, "to": None}` 一类指令。

**② 总结过往对话**

```python
from langgraph.graph import MessagesState

class State(MessagesState):
    summary: str

def summarize_conversation(state: State):
    summary = state.get("summary", "")
    if summary:
        msg = f"这是目前的对话摘要：{summary}\n\n结合上面的新消息扩展它："
    else:
        msg = "总结上面的对话："

    messages = state["messages"] + [HumanMessage(content=msg)]
    response = model.invoke(messages)

    keep = [RemoveMessage(id=m.id) for m in state["messages"][:-2]]
    return {"summary": response.content, "messages": keep}
```

思路为：消息累积至阈值时执行总结，删除旧消息，以摘要作为后续上下文。
（相应增加一次 LLM 调用，成本需一并权衡。）

**③ 按 token 数裁剪**

使用 LangChain 的 `trim_messages`，指定 `strategy="last"`、`max_tokens=...`，
其会处理边界规则（历史须以 human 开头、可保留 system 消息等）。
这些边界规则正是自行实现裁剪时最易出错之处。

::: tip 触发时机
一个简单且可靠的触发条件是**统计 token**：接近模型上限时才执行裁剪，
较"每 N 轮清理一次"一类的经验规则更为稳妥。
:::

### 长期记忆的类型

文档借鉴了人类记忆的分类，该类比具有较好的指导意义：

| 类型 | 存储内容 | 人类示例 | 智能体示例 |
| --- | --- | --- | --- |
| **语义** | 事实 | 在学校习得的知识 | 关于用户的事实 |
| **情景** | 经验 | 曾经做过的事 | 智能体过往的行动 |
| **程序** | 指令 | 本能与运动技能 | 智能体的系统提示词 |

**语义记忆**有两种组织方式，其间存在实际权衡：

- **单一 Profile**（一份持续更新的 JSON）：信息集中、上下文完整。
  但每次均需模型在旧文档基础上修订，条目增多后易修订失败——严格解码可部分缓解。
- **Collection**（若干小文档，持续追加）：单条范围窄、易于生成、
  **信息丢失概率低**（LLM 生成新对象远比并入旧文档可靠），召回率通常更高。
  代价是更新逻辑复杂（涉及删除与修改），且模型在生成响应时缺乏全局上下文。

**情景记忆**实践中多以少样本提示（few-shot）实现：保存过往成功案例，
遇到相似输入时取出并注入提示词。"展示优于告知"。
案例选取本身是检索问题——Store 可以承担，LangSmith 的数据集亦可。

**程序记忆** = 模型权重 + 代码 + 提示词。前两者通常不由智能体修改，
因此实践中**实际被修改的是提示词**：由智能体携带当前指令与最近的对话或用户反馈，
自行重写指令（即"反思"或元提示）。文档中的推文生成器即属此类。

### 记忆的写入时机

- **热路径（hot path）**：在主流程中写入，响应前完成。
  优点是新记忆即时可用、对用户透明；代价是**增加延迟**，
  且智能体需在完成任务之余判断"该记什么"，分心可能导致记忆的数量与质量下降。
  ChatGPT 的 `save_memories` 工具即采用此模式。
- **后台写入**：由独立的异步任务生成记忆。
  主流程零延迟、逻辑解耦、调度灵活（定时 / cron / 手动触发）；
  代价是**频率难以确定**——写入过慢则其他线程无法获得新上下文，过频则造成浪费。

一般而言，除非场景确实要求"下一句话即须生效"，**优先考虑后台写入**。

## 四、Checkpointer 附带的四项能力

以下四点是本篇最具价值之处——一个 checkpointer 同时提供四种能力：

### 1. 人机协作

人工须在任意时刻查看状态、修改状态并使图继续执行——
**状态若未持久化，便无"继续"可言**。因此人机协作是 checkpointer 的直接推论。

### 2. 记忆

同 thread 的后续消息能够延续先前上下文，正是依靠检查点保存的消息历史。

### 3. 时间旅行

回放历史执行、从任意检查点分叉以探索其他轨迹，是有效的调试手段。

### 4. 容错

若某节点在某超步失败，**可从最后一个成功的步骤重启**。

更进一步的是 **pending writes**：一个超步中并行执行三个节点，
第三个失败时，LangGraph 会保存前两个**已完成的写入**，
恢复时**不会重跑它们**。节省的不只是时间，还包括重复调用 LLM 的费用。

## 五、检查点器的选型

| 实现 | 包 | 适用场景 |
| --- | --- | --- |
| `InMemorySaver` | 内置 | 实验与演示，重启即失效 |
| `SqliteSaver` | `langgraph-checkpoint-sqlite` | 本地与单机小项目 |
| `PostgresSaver` | `langgraph-checkpoint-postgres` | **生产环境**，LangGraph 平台同款 |

接口仅四个方法，自定义实现成本较低：

```text
.put            保存快照
.put_writes     保存超步内的中间写入（pending writes）
.get_tuple      读取单个快照（供 get_state 使用）
.list           列出快照（供 get_state_history 使用）
```

异步执行（`.ainvoke` / `.astream`）时使用对应的 `.aput` / `.aget_tuple` / `.alist`。

### 序列化与加密

状态须序列化后存储，默认的 `JsonPlusSerializer` 支持 LangChain / LangGraph 基本类型、
datetime、enum 等。启用加密：

```python
from langgraph.checkpoint.serde.encrypted import EncryptedSerializer
from langgraph.checkpoint.sqlite import SqliteSaver

serde = EncryptedSerializer.from_pycryptodome_aes()   # 读取 LANGGRAPH_AES_KEY
checkpointer = SqliteSaver(sqlite3.connect("checkpoint.db"), serde=serde)
```

在 LangGraph 平台上运行时，只要环境存在 `LANGGRAPH_AES_KEY` 即自动启用加密。
对话记录属用户隐私数据，建议启用该选项。

## 小结

```text
checkpointer  ──每超步存快照──→ thread
                 ├─ get_state / get_state_history   读取
                 ├─ invoke(checkpoint_id=...)        回放
                 ├─ update_state(..., as_node=...)   修改历史
                 └─ 附带能力：人机协作 / 记忆 / 时间旅行 / 容错

store         ──跨 thread──→ 长期记忆（namespace + key）
                 ├─ put / get / search
                 └─ 配置 embedding 后支持语义搜索

短期记忆：State + 线程内快照       长期记忆：Store + 命名空间
长对话三法：RemoveMessage 裁剪 / summary 总结 / trim_messages 按 token 裁剪
```

下一篇：[人机协作与流式输出](/langgraph/hil-streaming)。
