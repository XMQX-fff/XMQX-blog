# 图 API 三要素：State、Node、Edge

本篇是全栏目理论密度最高的一篇，也是最值得精读的一篇。
掌握本篇之后，记忆、人机协作、多智能体等内容均可视为在此三要素之上的扩展。

## 怎么读本篇

- 本篇例子**全部不需要 API 密钥**，装个 `langgraph` 就能跑；
- 每个例子后面附**预期输出**，跑完对照控制台检查；
- 名词第一次出现时有"名词解释"小框，忘了随时回来查。

先装环境，后面每节都靠它：

```bash
pip install -U langgraph
```

## 核心命题

> **节点完成工作，边指示下一步该做什么。**

（原文：Nodes do the work, edges tell what to do next。）

LangGraph 以三个要素描述智能体工作流：

1. **State（状态）**：共享数据结构，表示程序的当前快照；
2. **Nodes（节点）**：执行逻辑的 Python 函数，接收 State，返回**对 State 的更新**；
3. **Edges（边）**：决定后续节点的 Python 函数，可为固定跳转或条件分支。

需要注意，Node 与 Edge 均为普通 Python 函数——内部既可调用 LLM，也可执行纯计算。

### 最小完整可运行例子

先把三要素跑起来，建立整体印象。存成 `mini.py` 直接运行：

```python
from typing_extensions import TypedDict
from langgraph.graph import StateGraph, START, END


class State(TypedDict):
    topic: str
    joke: str


def write_joke(state: State) -> dict:
    """节点 = 普通函数：第一个参数是状态，返回对状态的（部分）更新。"""
    print(f"[write_joke] 收到 topic={state['topic']}")
    return {"joke": f"关于 {state['topic']} 的笑话来咯"}


def review(state: State) -> dict:
    print(f"[review] 检查 joke：{state['joke']}")
    return {}  # 返回空 = 不改任何状态


builder = StateGraph(State)
builder.add_node("write_joke", write_joke)   # 节点：做事
builder.add_node("review", review)

builder.add_edge(START, "write_joke")        # 边：固定跳转，入口 → 第一个节点
builder.add_edge("write_joke", "review")     # write_joke 干完 → review
builder.add_edge("review", END)              # review 干完 → 结束

graph = builder.compile()                    # 编译后才能调用

result = graph.invoke({"topic": "程序员"})
print("最终状态:", result)
```

预期输出：

```text
[write_joke] 收到 topic=程序员
[review] 检查 joke：关于 程序员 的笑话来咯
最终状态: {'topic': '程序员', 'joke': '关于 程序员 的笑话来咯'}
```

三个观察：

1. 节点函数只返回**要改的键**（`{"joke": ...}`），没返回的 `topic`
   原样保留——这正是"部分更新 + 状态"模式的便利；
2. `print` 的顺序告诉你边的走向：`START → write_joke → review → END`；
3. `invoke` 的返回值是**图的完整最终状态**，所有节点的输出都在里面。

## 执行模型：超步

这个背景有助于理解后续诸多设计，故先行说明。

LangGraph 的执行模型受 Google **Pregel** 启发，以**消息传递**驱动程序，
按离散的**超步（superstep）** 推进：

- 一个超步即图中节点的一次迭代；
- **并行运行的节点属于同一超步**，顺序运行的节点分属不同超步；
- 初始时所有节点均为 `inactive`。节点在其入边（通道）上收到消息后转为 `active`，
  执行函数并返回更新；
- 超步结束时，未收到消息的节点投票 `halt`；
- **当全部节点均为 `inactive` 且无消息传递时，执行终止。**

**名词解释：超步（superstep）。** 你可以把它理解成"一轮群发"：
这一轮里所有被激活的节点**同时**跑（依赖的入边都有数据了），
等全部跑完、把各自的状态更新合进 state，才进入下一轮。
上面的例子里每个节点自成一超步：

```text
超步 0：START 把 {"topic": "程序员"} 写进状态
超步 1：write_joke 被激活（入边收到消息），写完投票 halt
超步 2：review 被激活，检查
超步 3：无人再有入边消息 → 全部 inactive → 执行终止
```

由此可直接推得两条行为：

- 节点若有两条出边，两个目标节点将在**下一超步中并行执行**；
- 图必须具备终止条件，否则将触发递归限制（默认 25 步，抛出 `GraphRecursionError`）。

## State：状态定义

**名词解释：状态（State）/ 状态模式（schema）。** State 是贯穿
整张图的"共享工作台"：每个节点往里写结果，边的判断从里面读数据。
**状态模式**就是这个工作台的字段清单，通常用 `TypedDict`，
亦支持 Pydantic `BaseModel`（可提供默认值与数据校验）：

```python
from typing_extensions import TypedDict


class State(TypedDict):
    foo: int
    bar: list[str]
```

**名词解释：通道（channel）。** 状态的每个键在底层对应一个"通道"——
它不只存值，还自带**归约逻辑**（见下）。"入边上收到消息"指的就是
通道里来了新数据。

### 节点只需返回“更新”

```python
def node_a(state: State):
    return {"foo": 2}          # 仅更新 foo，bar 保持不变
```

返回的部分更新会与现有状态合并，无需返回完整状态。

### Reducer：状态语义的关键

**名词解释：归约器（reducer）。** 决定"同一个状态键**同时/先后**收到
多个更新时怎么合并"的函数。State 中每个键都有独立的归约函数，
**未显式指定时，默认语义为“覆盖”**（后来的值直接顶掉旧值）。

下面两个程序只差一个 `Annotated`，对比运行：

程序 A（默认覆盖）：

```python
from typing_extensions import TypedDict
from langgraph.graph import StateGraph, START, END


class State(TypedDict):        # 没给 bar 指定归约器
    foo: int
    bar: list[str]


def node_a(state: State):
    return {"foo": 2, "bar": ["hi"]}


def node_b(state: State):
    return {"foo": 3, "bar": ["bye"]}


builder = StateGraph(State)
builder.add_node("a", node_a)
builder.add_node("b", node_b)
builder.add_edge(START, "a")
builder.add_edge("a", "b")
builder.add_edge("b", END)

print(builder.compile().invoke({"foo": 1, "bar": ["init"]}))
```

预期输出：

```text
{'foo': 3, 'bar': ['bye']}
```

程序 B（`bar` 用 `operator.add` 追加）：

```python
from typing import Annotated
from operator import add


class State(TypedDict):
    foo: int
    bar: Annotated[list[str], add]   # ← 只多这一行
```

（其余代码完全相同）

预期输出：

```text
{'foo': 3, 'bar': ['init', 'hi', 'bye']}
```

::: tip Reducer 的必要性
Reducer 决定了"两个节点同时更新同一键"时的合并规则。
在超步模型下，这种情况属于常态——缺少 reducer 时，
并行节点的结果会相互覆盖（后写赢），数据静默丢失且很难排查。
:::

### 应用于消息：`add_messages`

对话历史是最常见的状态。若仅使用 `operator.add`，
每轮新增的消息只能追加至旧列表，**无法修改已存在的消息**。
LangGraph 提供了专用 reducer：

```python
from typing import Annotated

from langchain_core.messages import AnyMessage
from langgraph.graph.message import add_messages


class GraphState(TypedDict):
    messages: Annotated[list[AnyMessage], add_messages]
```

`add_messages` 承担三项职责：

1. 新消息按 ID **追加**；
2. ID 已存在的消息**原地覆盖**（这正是人工介入时可"修改历史"的原因）；
3. 将 `{"type": "human", "content": "..."}` 形式的字典**反序列化**为 LangChain 消息对象。

跑一下感受第 2 条——同一 ID 的消息再发一次会替换旧内容，不会追加：

```python
from typing import Annotated

from langchain_core.messages import HumanMessage
from langgraph.graph import StateGraph, START, END
from langgraph.graph.message import add_messages


class State(TypedDict):
    messages: Annotated[list, add_messages]


def append_a(state: State):
    msg = HumanMessage(content="第一条", id="m1")
    return {"messages": [msg]}


def revise(state: State):
    # 同一条 ID 的消息，内容变了
    return {"messages": [HumanMessage(content="第一条（已修订）", id="m1")]}


builder = StateGraph(State)
builder.add_node("a", append_a)
builder.add_node("b", revise)
builder.add_edge(START, "a")
builder.add_edge("a", "b")
builder.add_edge("b", END)

for m in builder.compile().invoke({"messages": []})["messages"]:
    print(m.id, "→", m.content)
```

预期输出：

```text
m1 → 第一条（已修订）
```

只有一条消息——旧内容被覆盖了。如果换成裸 `operator.add`，
你会得到两条。

由于会执行反序列化，读取内容须使用点号：`state["messages"][-1].content`
（取到的是消息对象）。

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

**名词解释：input / output 模式。** 图对外"收什么、吐什么"的过滤器。
`OverallState` 是内部全部通道的并集；`input=InputState` 让调用方
只能传 InputState 里的键；`output=OutputState` 让 `invoke` 只返回
OutputState 里的键。中间结果（如 `foo`）对外不可见。

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
  （可从中读取 `thread_id` 及自定义的 `configurable` 字段）；
- 未指定名称时，默认采用函数名；
- 函数会被包装为 `RunnableLambda`，从而获得批处理、异步与链路追踪支持。

**名词解释：`config["configurable"]`。** 运行时传入的自定义参数统一存放处，
例如 `graph.invoke(..., config={"configurable": {"user_id": "u-1"}})`。
节点、边、工具都用它拿"这一次运行"的参数——不污染状态。

### 两个特殊节点

```python
from langgraph.graph import START, END


builder.add_edge(START, "node_a")   # 用户输入入口
builder.add_edge("node_b", END)     # 终止
```

`START` 表示"将用户输入送入图"，`END` 表示"该路径无后续节点"。
二者为虚拟节点，无需定义，但必须引用——至少有一条入边。

### 节点缓存

针对高开销节点，可按输入进行缓存：

```python
import time

from typing_extensions import TypedDict

from langgraph.cache.memory import InMemoryCache
from langgraph.graph import StateGraph, START, END
from langgraph.types import CachePolicy


class State(TypedDict):
    x: int
    result: int


def expensive_node(state: State) -> dict:
    time.sleep(2)                 # 模拟昂贵计算
    return {"result": state["x"] * 2}


builder = StateGraph(State)
builder.add_node("expensive_node", expensive_node,
                 cache_policy=CachePolicy(ttl=3))   # 3 秒内同输入命中缓存

graph = builder.compile(cache=InMemoryCache())

print(graph.invoke({"x": 5}, stream_mode="updates"))   # 第一次：真的算
print(graph.invoke({"x": 5}, stream_mode="updates"))   # 第二次：直接命中
```

预期输出：

```text
{'expensive_node': {'result': 10}}
{'expensive_node': {'result': 10}, '__metadata__': {'cached': True}}
```

第二次的结果里多了一个 `__metadata__` 键，标记这一跳直接走了缓存。
默认缓存键为输入的 pickle hash，亦可自定义 `key_func`。
**适用场景**：反复用相同入参调用外部 API / 昂贵计算的节点。

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
返回列表时，目标节点将**并行**执行（同一超步）。

**名词解释：映射表参数。** 路由函数返回布尔值之类的"决策码"时，
用字典把它翻成节点名（`{True: "node_b", False: "node_c"}`）。
不传字典就必须直接返回节点名字符串。

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

**名词解释：MapReduce。** 两阶段并行模式：Map = 对列表每个元素
跑同一个处理函数；Reduce = 把各结果汇总。`Send` 就是 LangGraph
里的 Map 阶段实现。

```python
from operator import add
from typing import Annotated

from typing_extensions import TypedDict
from langgraph.graph import StateGraph, START, END
from langgraph.types import Send


class OverallState(TypedDict):
    subjects: list[str]
    jokes: Annotated[list[str], add]      # 收集各并行结果


def generate_jokes(state: OverallState) -> dict:
    return {"subjects": ["程序员", "产品经理"]}


def continue_to_jokes(state: OverallState):
    # 每个 subject 发一条 Send：节点名 + 只给这个节点的独立状态
    return [Send("generate_joke", {"subject": s}) for s in state["subjects"]]


def generate_joke(state: dict) -> dict:   # 注意：这里 state 是 Send 给的独立状态
    subject = state["subject"]
    return {"jokes": [f"关于{subject}的笑话来咯"]}


builder = StateGraph(OverallState)
builder.add_node("generate_jokes", generate_jokes)
builder.add_node("generate_joke", generate_joke)
builder.add_conditional_edges("generate_jokes", continue_to_jokes)
builder.add_edge("generate_joke", END)   # 每个并行分支跑完各自到 END

print(builder.compile().invoke({"subjects": [], "jokes": []}))
```

预期输出（两个 generate_joke 并行跑，结果都被追加进来）：

```text
{'subjects': ['程序员', '产品经理'], 'jokes': ['关于程序员的笑话来咯', '关于产品经理的笑话来咯']}
```

注意第二个参数送入的是**该节点的独立状态**，与共享图状态不同——
这是 Send 与普通条件边的本质差别：每条并行分支拿到的输入
可以各不相同。

## Command：合并状态更新与控制流

若需在同一函数中既更新状态又决定去向：
条件边只负责路由，Node 只负责状态，`Command` 将二者合并：

```python
from typing import Literal

from langgraph.types import Command


def my_node(state: State) -> Command[Literal["my_other_node"]]:
    return Command(
        update={"foo": "bar"},     # 状态更新
        goto="my_other_node",      # 控制流
    )
```

::: warning 返回类型注解不可省略
`-> Command[Literal["my_other_node"]]` 必须书写。
该注解用于图的静态分析与渲染，使 LangGraph 得知 `my_node` 可能跳转的目标。
缺少该注解时，可视化结果不完整（某些版本直接报错）。
:::

### Command 与条件边的选用

- **仅路由、不更新状态** → 条件边；
- **既要更新状态又要路由**（典型场景：多智能体交接，需随控制权一并传递上下文） → `Command`。

### 两项实用能力

**跳转至父图节点**（子图内触发父图的其他分支）：

```python
return Command(goto="other_subgraph", update={"foo": "bar"}, graph=Command.PARENT)
```

**在工具内修改图状态**（如客户支持场景，查询客户资料后直接写回状态）：
使工具返回 `Command` 即可。LangChain 侧的完整例子见
[模型·消息·工具 3.3 节](/langchain/components#3-3-toolruntime访问运行时)。

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

**名词解释：为什么必须编译。** 编译时 LangGraph 会把"节点/边"的声明
固化成一张可执行的有向图，并做静态校验（孤立节点、不存在的跳转目标都在
这一步报错）。传进去的 checkpointer（持久化）、breakpoints（断点）
也都在此刻绑定，之后每次 invoke 都沿用。

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

**名词解释：递归限制（recursion_limit）。** 单次执行允许的最大超步数，
默认 25。它是防死循环的保险丝——图忘记设计终止条件时，
`GraphRecursionError` 会在第 25 步把你拦下，进程不会跑飞到天亮。
注意它是**独立的 config 键**，不进入 `configurable`：

```python
graph.invoke(inputs, config={"recursion_limit": 5, "configurable": {"llm": "anthropic"}})
```

## 图结构迁移

在已保存历史状态的前提下修改图结构，其兼容性规则如下：

| 变更 | 已完成的线程 | 中断中的线程 | 原因 |
| --- | --- | --- | --- |
| 增删节点、边 | 支持 | 支持 | 历史状态与新结构互不依赖 |
| 重命名/删除节点 | 支持 | **不支持** | 中断线程"下一步"可能正指向被删的节点 |
| 新增/删除状态键 | 支持 | 支持 | 旧线程读不到新键，用默认值兜底 |
| 重命名状态键 | **旧值丢失** | **旧值丢失** | 检查点里旧键名存的数据没人认领了 |

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
