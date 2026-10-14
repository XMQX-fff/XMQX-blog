# 图 API 三要素：State、Node、Edge

本篇是本栏目理论密度最高的一篇，也是最值得精读的一篇。
掌握本篇之后，记忆、人机协作、多智能体等内容均可视为在此三要素之上的扩展。

## 核心命题

> **节点完成工作，边指示下一步该做什么。**

（原文：Nodes do the work, edges tell what to do next。）

LangGraph 以三个要素描述智能体工作流：

1. **State**：共享数据结构，表示程序的当前快照。
2. **Nodes**：执行逻辑的 Python 函数，接收 State，返回**对 State 的更新**。
3. **Edges**：决定后续节点的 Python 函数，可为固定跳转或条件分支。

需要注意，Node 与 Edge 均为普通 Python 函数——内部既可调用 LLM，也可执行纯计算。

## 执行模型：超步

该背景有助于理解后续诸多设计，故先行说明。

LangGraph 的执行模型受 Google **Pregel** 启发，以**消息传递**驱动程序，
按离散的**超步（superstep）** 推进：

- 一个超步即图中节点的一次迭代。
- **并行运行的节点属于同一超步**，顺序运行的节点分属不同超步。
- 初始时所有节点均为 `inactive`。节点在其入边（通道）上收到消息后转为 `active`，
  执行函数并返回更新。
- 超步结束时，未收到消息的节点投票 `halt`。
- **当全部节点均为 `inactive` 且无消息传递时，执行终止。**

由此可直接推得两条行为：

- 节点若有两条出边，两个目标节点将在**下一超步中并行执行**。
- 图必须具备终止条件，否则将触发递归限制（默认 25 步，抛出 `GraphRecursionError`）。

## State：状态定义

```python
from typing_extensions import TypedDict

class State(TypedDict):
    foo: int
    bar: list[str]
```

State 的模式（schema）即全部 Node 与 Edge 的输入模式。通常使用 `TypedDict`，
亦支持 Pydantic `BaseModel`（可提供默认值与数据校验）。

### 节点只需返回"更新"

```python
def node_a(state: State):
    return {"foo": 2}          # 仅更新 foo，bar 保持不变
```

返回的部分更新会与现有状态合并，无需返回完整状态。

### Reducer：状态语义的关键

State 中每个键都有独立的归约函数（reducer）。**未显式指定时，默认语义为"覆盖"。**

```python
# 默认：bar 被覆盖
class State(TypedDict):
    foo: int
    bar: list[str]

# 指定 reducer：bar 被追加
from typing import Annotated
from operator import add

class State(TypedDict):
    foo: int
    bar: Annotated[list[str], add]
```

以输入 `{"foo": 1, "bar": ["hi"]}` 为例，节点 A 返回 `{"foo": 2}`，
状态变为 `{"foo": 2, "bar": ["hi"]}`；随后节点 B 返回 `{"bar": ["bye"]}`：

- 无 reducer：`{"foo": 2, "bar": ["bye"]}`（覆盖）
- 指定 `add`：`{"foo": 2, "bar": ["hi", "bye"]}`（追加）

::: tip Reducer 的必要性
Reducer 决定了"两个节点同时更新同一键"时的合并规则。
在超步模型下，这种情况是常态而非例外——缺少 reducer 时，并行节点的结果会相互覆盖。
:::

### 应用于消息：`add_messages`

对话历史是最常见的状态。若仅使用 `operator.add`，
每轮新增的消息只能追加至旧列表，**无法修改已存在的消息**。
LangGraph 提供了专用 reducer：

```python
from langchain_core.messages import AnyMessage
from langgraph.graph.message import add_messages

class GraphState(TypedDict):
    messages: Annotated[list[AnyMessage], add_messages]
```

`add_messages` 承担三项职责：

1. 新消息按 ID **追加**；
2. ID 已存在的消息**原地覆盖**（这正是人工介入时可"修改历史"的原因）；
3. 将 `{"type": "human", "content": "..."}` 形式的字典**反序列化**为 LangChain 消息对象。

由于会执行反序列化，读取内容须使用点号：`state["messages"][-1].content`。

鉴于"仅保存一个 messages 列表"极为常见，官方提供了现成实现：

```python
from langgraph.graph import MessagesState

class State(MessagesState):
    documents: list[str]    # 需要额外字段时继承添加
```

`MessagesState` 即"使用 `add_messages` 归约的 `messages` 键"。

### 多套模式（进阶）

若内部节点之间需要传递输入输出均不涉及的中间信息，
或希望图的输入与输出结构不同，可采用如下形式：

```python
class InputState(TypedDict):
    user_input: str

class OutputState(TypedDict):
    graph_output: str

class OverallState(TypedDict):
    foo: str
    user_input: str
    graph_output: str

class PrivateState(TypedDict):
    bar: str

builder = StateGraph(OverallState, input=InputState, output=OutputState)
```

两点需要特别注意（文档对此有专门强调）：

1. 节点**可以写入图状态中的任意通道**，即便其参数类型标注为更窄的 `InputState`。
   图状态是初始化时全部状态通道的**并集**。
2. 未在 `StateGraph(...)` 中传入的模式（如 `PrivateState`），只要其**已定义**，
   节点同样可以向其写入——节点可声明额外的状态通道。

实际效果为：`bar` 仅在节点 2 与节点 3 之间流转，对外不可见。

## Node：执行单元

```python
from langchain_core.runnables import RunnableConfig
from langgraph.graph import StateGraph

def my_node(state: State, config: RunnableConfig):
    print("In node:", config["configurable"]["user_id"])
    return {"results": f"Hello, {state['input']}!"}

builder = StateGraph(State)
builder.add_node("my_node", my_node)
```

- **第一个位置参数为 State**，可选的第二个参数为 config
  （可从中读取 `thread_id` 及自定义的 `configurable` 字段）。
- 未指定名称时，默认采用函数名。
- 函数会被包装为 `RunnableLambda`，从而获得批处理、异步与链路追踪支持。

### 两个特殊节点

```python
from langgraph.graph import START, END

builder.add_edge(START, "node_a")   # 用户输入入口
builder.add_edge("node_b", END)     # 终止
```

`START` 表示"将用户输入送入图"，`END` 表示"该路径无后续节点"。
二者为虚拟节点，无需定义，但必须引用。

### 节点缓存

针对高开销节点，可按输入进行缓存：

```python
from langgraph.cache.memory import InMemoryCache
from langgraph.types import CachePolicy

builder.add_node(
    "expensive_node",
    expensive_node,
    cache_policy=CachePolicy(ttl=3),
)
graph = builder.compile(cache=InMemoryCache())
```

第二次调用将直接命中缓存，返回结果中带有 `__metadata__: {cached: True}`。
默认缓存键为输入的 pickle hash，亦可自定义 `key_func`。

## Edge：路由的四种形态

### 1. 普通边

```python
graph.add_edge("node_a", "node_b")    # 始终从 a 到 b
```

### 2. 条件边

```python
graph.add_conditional_edges("node_a", routing_function)

# 或附带映射表
graph.add_conditional_edges("node_a", routing_function, {True: "node_b", False: "node_c"})
```

`routing_function` 接收当前 state，返回下一节点名（或节点名列表）。
返回列表时，目标节点将**并行**执行。

### 3. 入口点

```python
graph.add_edge(START, "node_a")
```

### 4. 条件入口点

```python
graph.add_conditional_edges(START, routing_function)
```

依据输入决定起始节点。

## Send：动态 MapReduce

预定义边的局限在于边数固定。若首个节点生成一个列表，
需要对**其中每个元素**执行同一节点（且各元素输入不同），应使用 `Send`：

```python
from langgraph.types import Send

def continue_to_jokes(state: OverallState):
    return [Send("generate_joke", {"subject": s}) for s in state["subjects"]]

graph.add_conditional_edges("node_a", continue_to_jokes)
```

`Send(节点名, 该节点接收的状态)` ——从条件边返回 `Send` 列表即构成 Map 阶段。
注意第二个参数是**该节点的独立状态**，而非共享的图状态。

## Command：合并状态更新与控制流

若需在同一函数中既更新状态又决定去向：
条件边只负责路由，Node 只负责状态，`Command` 将二者合并：

```python
from langgraph.types import Command
from typing import Literal

def my_node(state: State) -> Command[Literal["my_other_node"]]:
    return Command(
        update={"foo": "bar"},     # 状态更新
        goto="my_other_node",      # 控制流
    )
```

::: warning 返回类型注解不可省略
`-> Command[Literal["my_other_node"]]` 必须书写。
该注解用于图的静态分析与渲染，使 LangGraph 得知 `my_node` 可能跳转的目标。
缺少该注解时，可视化结果不完整。
:::

### 何时选用 Command 而非条件边

- **仅路由、不更新状态** → 条件边。
- **既要更新状态又要路由**（典型场景：多智能体交接，需随控制权一并传递上下文） → `Command`。

### 两项实用能力

**跳转至父图节点**（子图内触发父图的其他分支）：

```python
return Command(goto="other_subgraph", update={"foo": "bar"}, graph=Command.PARENT)
```

**在工具内修改图状态**（如客户支持场景，查询客户资料后直接写回状态）：
使工具返回 `Command` 即可。

## 编译

```python
graph = builder.compile(...)
```

编译阶段完成两项工作：

- 结构检查（如是否存在孤立节点）；
- 绑定运行时参数——**检查点器与断点**均在此处传入。

```python
graph = builder.compile(checkpointer=checkpointer, cache=InMemoryCache())
```

图必须编译后方可调用。

## 配置与递归限制

```python
class ConfigSchema(TypedDict):
    llm: str

graph = StateGraph(State, config_schema=ConfigSchema)
# ...
graph.invoke(inputs, config={"configurable": {"llm": "anthropic"}})
```

节点内通过 `config["configurable"]["llm"]` 读取。

递归限制是**独立的 config 键**，不进入 `configurable`：

```python
graph.invoke(inputs, config={"recursion_limit": 5, "configurable": {"llm": "anthropic"}})
```

默认值为 25 步，超出后抛出 `GraphRecursionError`。含循环路由的图须留意该配置。

## 图结构迁移

在已保存历史状态的前提下修改图结构，其兼容性规则如下：

- **执行完毕的线程**（未中断）：拓扑可任意修改，增删改节点与边均受支持。
- **处于中断状态的线程**：除"重命名/删除节点"外均支持
  （因为该线程可能即将进入一个已不存在的节点）。
- **状态键**：新增与删除保持前后兼容；**重命名键将丢失旧线程中保存的值**。

因此：状态键应在初期确定命名，避免上线后再行调整。

## 小结

```text
StateGraph(State)
  ├─ add_node(name, fn)                    fn(state, config) -> 部分更新
  ├─ add_edge(START, "a")                  固定跳转
  ├─ add_conditional_edges("a", route_fn)  条件路由（可返回 Send 列表并行）
  └─ compile(checkpointer=...)             必须编译后方可调用

State 每个键有独立 reducer：
  无 reducer                  → 覆盖
  Annotated[..., add]         → 追加
  Annotated[..., add_messages]→ 按消息 ID 追加/覆盖（对话场景必备）

节点需同时更新状态并跳转 → 返回 Command(goto=..., update=...)
```

下一篇：[智能体架构](/langgraph/agent-architectures)——基于三要素可构建的各类拓扑。
