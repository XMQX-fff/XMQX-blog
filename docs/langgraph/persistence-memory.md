# 持久化与记忆：Checkpointer、Store 与长对话

前面几篇一直在提"挂个 checkpointer 就能多轮了"，这一篇把它拆开讲。
搞清楚这一篇，你就能明白：断点续跑、时间旅行、人工介入、长期记忆，**其实都是同一套机制的不同用法**。

## 一、持久化层：Checkpointer

> 用 checkpointer 编译图之后，**每个超步**都会保存一份图状态的快照（checkpoint），
> 这些快照存进一个 **thread** 里。

三个词先分清：

| 词 | 是什么 |
| --- | --- |
| **Thread** | 一次会话/一次执行序列的唯一 ID，是快照的容器 |
| **Checkpoint** | 某个超步结束时的状态快照 |
| **StateSnapshot** | 读出来的快照对象（有 values / next / metadata / config / tasks） |

调用时**必须**给 `thread_id`：

```python
config = {"configurable": {"thread_id": "1"}}
```

::: tip LangGraph API 会自动处理
如果你用的是 LangGraph Platform / API，检查点器和存储都不用自己配，
它在幕后全办好了。下面的内容是自托管时要懂的。
:::

### 一个具体例子：到底存了几个快照

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

跑完会留下 **4 个**快照：

```text
1. 空快照                       next = (START 之后的 node_a)  等等，输入还没进来
2. 输入后  {'foo':'', 'bar':[]}  next = ('node_a',)
3. A 之后  {'foo':'a','bar':['a']}  next = ('node_b',)
4. B 之后  {'foo':'b','bar':['a','b']}  next = ()  → 结束
```

注意 `bar` 是 `['a', 'b']`——因为 `bar` 有 reducer，A 和 B 的贡献都留下了。
**没有 reducer 的 `foo` 只剩最后一个值。** 这就是上一篇死活要讲 reducer 的原因。

### 读状态

```python
# 最新状态
graph.get_state(config)

# 指定某个快照
graph.get_state({"configurable": {"thread_id": "1", "checkpoint_id": "1ef663ba-..."}})

# 完整历史（按时间倒序，最近的在最前）
list(graph.get_state_history(config))
```

`StateSnapshot` 里我最常看的是 `values`（当前状态）和 `next`（接下来要跑哪些节点）——
调试时一眼就能看出"卡在哪儿了"。

### 回放（Replay）

```python
config = {"configurable": {"thread_id": "1", "checkpoint_id": "0c62ca34-..."}}
graph.invoke(None, config=config)
```

含义是：**从这个 checkpoint 之后开始重新执行**，之前的步骤直接回放不重算。

坑在于：`checkpoint_id` **之后**的步骤，哪怕以前跑过，也会**重新执行**（相当于开了个新分支）。
这个特性往下延伸就是"时间旅行"——从任意历史点分叉，去探索另一条路径。

### 更新状态（可以手动改历史）

```python
graph.update_state(config, {"foo": 2, "bar": ["b"]}, as_node="node_a")
```

三个参数里有两个容易懵：

- **`values`**：更新走的是**和节点更新完全一样的路径**——有 reducer 的键会被归约，
  没 reducer 的才覆盖。假设当前 `{"foo": 1, "bar": ["a"]}`，更新 `{"foo": 2, "bar": ["b"]}`，
  结果是 `{"foo": 2, "bar": ["a", "b"]}`（`foo` 覆盖，`bar` 追加）。
- **`as_node`**：声明"这次更新算是哪个节点发出的"。**这决定了接下来跑哪个节点**——
  因为"下一步是什么"取决于"谁最后改的状态"。不给的话会取最后更新状态的那个节点，有歧义时会出乎意料。

## 二、Store：跨会话的长期记忆

问题来了：checkpointer 把状态存进 thread，**thread 之间互相看不见**。
"用户 A 不喜欢啰嗦"这条信息，怎么在 A 的第 1 次和第 50 次对话里都在？

答案是 **Store**，一个独立于 thread 的键值存储：

```python
from langgraph.store.memory import InMemoryStore

store = InMemoryStore()

namespace = (user_id, "memories")          # 类似文件夹
store.put(namespace, memory_id, {"food_preference": "I like pizza"})

memories = store.search(namespace)          # 读
```

编译时两者**同时**挂上：

```python
graph = workflow.compile(checkpointer=checkpointer, store=store)
```

分工非常清楚：

```text
checkpointer  →  线程内（短期）  "这场对话说到哪了"
store         →  跨线程（长期）  "这个用户是谁、喜欢什么"
```

### 在节点里访问 Store

节点多收一个 `store` 参数（用关键字注入），配置里的 `user_id` 决定命名空间：

```python
from langgraph.store.base import BaseStore

def call_model(state, config: RunnableConfig, *, store: BaseStore):
    user_id = config["configurable"]["user_id"]
    namespace = (user_id, "memories")
    memories = store.search(namespace, query=state["messages"][-1].content, limit=3)
    info = "\n".join([m.value["memory"] for m in memories])
    # 把 info 拼进提示词...
```

**语义搜索**：给 store 配上 embedding 之后，`search` 可以按自然语言查询找记忆，
而不是精确匹配：

```python
from langchain.embeddings import init_embeddings

store = InMemoryStore(index={
    "embed": init_embeddings("openai:text-embedding-3-small"),
    "dims": 1536,
    "fields": ["food_preference", "$"],   # 只对这些字段建索引
})
```

`fields` 里 `"$"` 表示整个文档。还能在 `put` 时用 `index=False` 把某条记忆排除出索引。

## 三、记忆：短期 vs 长期

前面是机制，这一节是**设计**。

```text
短期记忆（thread 范围）        长期记忆（跨 thread）
├─ 存在哪：图 State            ├─ 存在哪：Store
├─ 持久化：检查点              ├─ 持久化：任意命名空间
└─ 什么时候读写：每个步骤       └─ 任何时候、任何线程都能召回
```

### 短期记忆的真正难点：长对话

对话历史是短期记忆最常见的形式，而它会一直变长。后果有三层：

1. **塞不下**：超出上下文窗口直接报错（而且是不可恢复的错误）。
2. **效果变差**：模型在长上下文下会被过时的、跑题的内容"带偏"。
3. **又慢又贵**。

所以短期记忆管理本质上是一场**精确率 vs 召回率 vs 延迟 vs 成本**的权衡。三种常用手段：

**① 编辑消息列表**（最直接）

```python
from langchain_core.messages import RemoveMessage

def my_node(state: State):
    # 只留最近 2 条，其余按 ID 删掉
    to_delete = [RemoveMessage(id=m.id) for m in state["messages"][:-2]]
    return {"messages": to_delete}
```

`add_messages` reducer 看到 `RemoveMessage` 会按 ID 删除（然后自己被丢弃）。
更彻底的做法是自定义 reducer，接受 `{"type": "keep", "from": -5, "to": None}` 这种指令。

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

思路就是：攒够一定消息就总结一次，把旧的删掉，摘要作为下一轮的上下文。
（老规矩，多一次 LLM 调用，成本自己权衡。）

**③ 按 token 数裁剪**

用 LangChain 的 `trim_messages`，指定 `strategy="last"`、`max_tokens=...`，
它还会处理边界规则（历史要以 human 开头、可以保留 system 消息之类）。
这些边界规则就是那些"自己手写裁剪总会踩的坑"。

::: tip 什么时候裁？
一个简单可靠的触发条件是**数 token**：接近模型上限时才动手。
比"每 N 轮清一次"这种拍脑袋策略稳。
:::

### 长期记忆的类型

文档借用了人类记忆的分类，我觉得这个类比很好用：

| 类型 | 存什么 | 人类例子 | Agent 例子 |
| --- | --- | --- | --- |
| **语义** | 事实 | 在学校学的知识 | 关于用户的事实 |
| **情景** | 经验 | 我做过的事 | Agent 过去的行动 |
| **程序** | 指令 | 本能/运动技能 | Agent 的系统提示词 |

**语义记忆**有两种组织方式，这是个实打实的权衡：

- **单一 Profile**（一份持续更新的 JSON）：信息集中、上下文完整。
  但每次都要让模型在旧文档基础上改，条目多了容易改崩——严格解码能救一部分。
- **Collection**（一堆小文档，持续追加）：每条范围窄、好生成、
  **丢信息的概率低**（LLM 生成新对象比协调进旧文档容易得多），召回率通常更高。
  代价是更新逻辑复杂（要删要改），而且模型拼响应时缺乏全局上下文。

**情景记忆**实践中基本靠少样本提示（few-shot）：把过去成功的案例存起来，
遇到相似输入就取出来塞进提示词。"展示比告诉更有效"。
选哪几个例子是个检索问题——Store 本身能存，LangSmith 的数据集也行。

**程序记忆** = 模型权重 + 代码 + 提示词。前两个 Agent 一般不改，
所以实践中**改的其实是提示词**：让 Agent 拿着当前指令 + 最近的对话/用户反馈，
自己重写指令（"反思"或元提示）。文档给的推文生成器例子就是这个路子。

### 记忆什么时候写进去？

- **热路径（hot path）**：在主流程里写，响应之前就完成。
  好处是新记忆立刻可用、对用户透明；代价是**拖慢延迟**，而且 Agent 要一边干正事一边想"记什么"，
  分心之后记的质量和数量都可能下降。ChatGPT 的 `save_memories` 工具就是这个模式。
- **后台写**：单独任务异步生成记忆。
  主流程零延迟、逻辑解耦、时间安排灵活（定时/cron/手动触发）；
  代价是**频率不好定**——写太慢，别的线程拿不到新上下文；写太勤，浪费。

我的直觉是：**先用后台写**，除非你的场景确实要求"下一句话就得知道"。

## 四、Checkpointer 顺便带来的四个能力

这部分是我读文档时觉得最"值回票价"的地方——一个 checkpointer 白送四样东西：

### 1. 人机协作

人要在任意时刻看到状态、改状态、然后让图继续跑——
**没有持久化的状态就没法"继续"**。所以 HIL 是 checkpointer 的直接推论。

### 2. 记忆

同一 thread 的后续消息能接着上次聊，就是靠检查点把消息历史续上的。

### 3. 时间旅行

回放历史执行、从任意检查点分叉去探索别的轨迹——调试神器。

### 4. 容错

某个节点在某个超步挂了？**可以从最后一个成功的步骤重启。**

更妙的是 **pending writes**：一个超步里并行跑了 3 个节点，
第 3 个失败了——LangGraph 会把前两个**已经成功完成的写入**存下来，
恢复时**不会重跑它们**。省的不只是时间，还有重跑一次 LLM 的钱。

## 五、检查点器怎么选

| 实现 | 包 | 适用 |
| --- | --- | --- |
| `InMemorySaver` | 内置 | 实验、demo，重启就没 |
| `SqliteSaver` | `langgraph-checkpoint-sqlite` | 本地、单机小项目 |
| `PostgresSaver` | `langgraph-checkpoint-postgres` | **生产**，LangGraph 平台同款 |

接口就四个方法，自定义实现不难：

```text
.put            存快照
.put_writes     存超步内的中间写入（pending writes）
.get_tuple      读单个快照（喂给 get_state）
.list           列快照（喂给 get_state_history）
```

异步执行（`.ainvoke` / `.astream`）时用对应的 `.aput` / `.aget_tuple` / `.alist`。

### 序列化与加密

存状态就得序列化，默认的 `JsonPlusSerializer` 能处理 LangChain/LangGraph 基本类型、
datetime、enum 等。要加密的话：

```python
from langgraph.checkpoint.serde.encrypted import EncryptedSerializer
from langgraph.checkpoint.sqlite import SqliteSaver

serde = EncryptedSerializer.from_pycryptodome_aes()   # 读 LANGGRAPH_AES_KEY
checkpointer = SqliteSaver(sqlite3.connect("checkpoint.db"), serde=serde)
```

跑在 LangGraph 平台上时，只要环境里有 `LANGGRAPH_AES_KEY` 就自动开加密。
存聊天记录这种含用户隐私的东西，这个开关我建议直接打开。

## 小结

```text
checkpointer  ──每超步存快照──→ thread
                 ├─ get_state / get_state_history   读
                 ├─ invoke(checkpoint_id=...)        回放
                 ├─ update_state(..., as_node=...)   改历史
                 └─ 白送：HIL / 记忆 / 时间旅行 / 容错

store         ──跨 thread──→ 长期记忆（namespace + key）
                 ├─ put / get / search
                 └─ 配 embedding 后支持语义搜索

短期记忆：State + 线程内快照      长期记忆：Store + 命名空间
长对话三招：裁剪 RemoveMessage / 总结 summary / trim_messages 按 token
```

下一篇（本栏目最后一篇）：[人机协作与流式输出](/langgraph/hil-streaming)。
