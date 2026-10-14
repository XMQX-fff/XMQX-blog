# 图 API 三件套：State、Node、Edge

这是本栏目最硬的一篇，也是我认为最值得慢读的一篇。
把这篇啃完，后面的记忆、人机协作、多智能体全都只是"在这三件套上加料"。

## 先记住这句话

> **节点完成工作，边指示下一步该做什么。**

官方原文是 "Nodes do the work, edges tell what to do next"。

LangGraph 用三个东西描述一个 Agent 工作流：

1. **State**：一个共享数据结构，代表程序的当前快照。
2. **Nodes**：干活的 Python 函数。接收 State，干完返回一个**对 State 的更新**。
3. **Edges**：决定接下来走哪个节点的 Python 函数。可以是固定跳转，也可以是条件分支。

注意 Nodes 和 Edges 就是普通 Python 函数——里面可以调 LLM，也可以纯计算。

## 底层其实是个超步机器

这段背景知识我觉得挺重要的，理解了它很多"为什么"就不用背了。

LangGraph 的执行模型受 Google 的 **Pregel** 启发，用**消息传递**来驱动程序，
以离散的**超步（superstep）** 为单位推进：

- 一个超步 = 图里节点的一次迭代。
- **并行运行的节点属于同一个超步**，顺序运行的属于不同超步。
- 开始时所有节点都是 `inactive`。某个节点在它的入边（通道）上收到新消息 → 变 `active` → 执行 → 返回更新。
- 超步结束时，没有收到消息的节点投票 `halt`。
- **当所有节点都是 inactive 且没有消息在传，图执行结束。**

所以下面这几个行为你就能推出来：

- 一个节点有两条出边 → 两个目标节点**在下一个超步里并行执行**。
- 图必须能"停下来"，否则就会撞上递归限制（默认 25 步，抛 `GraphRecursionError`）。

## State：先定义状态

```python
from typing_extensions import TypedDict

class State(TypedDict):
    foo: int
    bar: list[str]
```

State 的模式（schema）就是所有 Node 和 Edge 的输入模式。常用 `TypedDict`，
也支持 Pydantic `BaseModel`（能加默认值和校验）。

### Node 只需要返回"更新"，不是整个 State

```python
def node_a(state: State):
    return {"foo": 2}          # 只更新 foo，bar 不动
```

返回的部分更新会和现有状态合并。**这是最容易忘的一点**——
我一开始每次都在函数末尾手动把整个 state 复制一遍，纯属浪费。

### Reducer：State 真正的灵魂

每个 State 里的键都有自己独立的归约函数（reducer）。
**没指定 reducer → 默认是"覆盖"。**

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

用上面的例子跑一遍：输入 `{"foo": 1, "bar": ["hi"]}`，
节点 A 返回 `{"foo": 2}` → 状态变 `{"foo": 2, "bar": ["hi"]}`；
节点 B 返回 `{"bar": ["bye"]}`：

- 没有 reducer：`{"foo": 2, "bar": ["bye"]}` （覆盖）
- 有 `add`：`{"foo": 2, "bar": ["hi", "bye"]}` （追加）

::: tip 我当时的疑惑
为什么要搞个 reducer 出来？直接 append 不行吗？
后来想通了：**reducer 决定了"两个节点同时更新同一个键"时怎么合并**。
没有它，并行节点的结果就会互相覆盖——这在超步模型下是常态而不是例外。
:::

### 用在消息上：`add_messages`

对话历史是最常见的状态。如果只用 `operator.add`，
每轮新的消息列表会被追加到旧列表后面——但你**没法修改已经发出去的消息**。

LangGraph 提供了专门的 reducer：

```python
from langchain_core.messages import AnyMessage
from langgraph.graph.message import add_messages

class GraphState(TypedDict):
    messages: Annotated[list[AnyMessage], add_messages]
```

`add_messages` 做三件事：

1. 新消息按 ID **追加**；
2. ID 已存在的消息**原地覆盖**（这就是人工介入时能"改历史"的原因）；
3. 自动把 `{"type": "human", "content": "..."}` 这种字典**反序列化**成 LangChain 消息对象。

因为会被反序列化，访问内容要用点号：`state["messages"][-1].content`。

由于"只存一个 messages 列表"太常见了，官方直接给了个现成的：

```python
from langgraph.graph import MessagesState

class State(MessagesState):
    documents: list[str]    # 想加别的字段就继承着加
```

`MessagesState` = 一个用 `add_messages` 归约的 `messages` 键。

### 多套 schema（进阶）

有时候内部节点之间要传一些输入/输出根本用不上的中间信息，
或者你想让图的输入和输出长得不一样。可以这么写：

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

两个微妙但重要的点（文档专门强调了）：

1. 节点**可以写入图状态里的任何通道**，哪怕它的入参类型标注的是更窄的 `InputState`。
   图状态是初始化时所有状态通道的**并集**。
2. 没在 `StateGraph(...)` 里传的模式（比如 `PrivateState`），只要它**定义了**，
   节点照样能往里写——节点可以声明额外的状态通道。

实际效果：`bar` 只在节点 2、3 之间内部流转，对外不可见。

## Node：干活的人

```python
from langchain_core.runnables import RunnableConfig
from langgraph.graph import StateGraph

def my_node(state: State, config: RunnableConfig):
    print("In node:", config["configurable"]["user_id"])
    return {"results": f"Hello, {state['input']}!"}

builder = StateGraph(State)
builder.add_node("my_node", my_node)
```

- **第一个位置参数是 State**，可选的第二个是 config（里面能拿 `thread_id`、
  自定义的 `configurable` 字段）。
- 不指定名字时，默认用函数名。
- 背后被包装成 `RunnableLambda`，自动获得批处理、异步、trace 支持。

### 两个特殊节点

```python
from langgraph.graph import START, END

builder.add_edge(START, "node_a")   # 用户输入从这儿进
builder.add_edge("node_b", END)     # 走到这儿就结束
```

`START` 表示"把用户输入送进图"，`END` 表示"这条路径没有下一步了"。
它们是虚拟节点，你不定义，但必须引用。

### 节点缓存

对昂贵节点可以按输入做缓存：

```python
from langgraph.cache.memory import InMemoryCache
from langgraph.types import CachePolicy

builder.add_node(
    "expensive_node",
    expensive_node,
    cache_policy=CachePolicy(ttl=3),   # 缓存 3 秒
)
graph = builder.compile(cache=InMemoryCache())
```

第二次调用会直接命中，返回里带 `__metadata__: {cached: True}`。
默认缓存键是对输入做 pickle hash，也能自己写 `key_func`。

## Edge：路由的四种形态

### 1. 普通边

```python
graph.add_edge("node_a", "node_b")    # 永远从 a 到 b
```

### 2. 条件边

```python
graph.add_conditional_edges("node_a", routing_function)

# 或者带映射表
graph.add_conditional_edges("node_a", routing_function, {True: "node_b", False: "node_c"})
```

`routing_function` 接收当前 state，返回下一个节点名（或节点名列表）。
返回列表时，那些节点**并行**跑。

### 3. 入口点

```python
graph.add_edge(START, "node_a")
```

### 4. 条件入口点

```python
graph.add_conditional_edges(START, routing_function)
```

根据输入决定从哪个节点开始。

## Send：动态 MapReduce

预定义的边有个限制：边的数量是写死的。如果第一个节点生成了一个列表，
你想对**列表里每个元素**跑一次同一个节点（而且每个的输入都不一样），怎么办？

用 `Send`：

```python
from langgraph.types import Send

def continue_to_jokes(state: OverallState):
    return [Send("generate_joke", {"subject": s}) for s in state["subjects"]]

graph.add_conditional_edges("node_a", continue_to_jokes)
```

`Send(节点名, 该节点收到的状态)` —— 从条件边返回一个 Send 列表，
就是经典的 map 阶段。注意第二个参数是**给那个节点的独立状态**，
不是共享的图状态。

## Command：把"改状态"和"决定去哪"合成一件事

有时候你想在同一个函数里既更新状态又决定下一步去哪。
条件边只管路由，Node 只管状态——`Command` 把俩合并了：

```python
from langgraph.types import Command
from typing import Literal

def my_node(state: State) -> Command[Literal["my_other_node"]]:
    return Command(
        update={"foo": "bar"},     # 状态更新
        goto="my_other_node",      # 控制流
    )
```

::: warning 返回类型注解不能省
`-> Command[Literal["my_other_node"]]` 这个注解**必须写**。
它不是装饰——LangGraph 靠它做图的静态分析和渲染，知道 `my_node` 可能跳到哪儿。
我漏了这个注解时，画出来的图是残的。
:::

### Command vs 条件边，什么时候用哪个

- **只路由、不改状态** → 条件边。
- **既要改状态又要路由**（典型：多智能体交接，把上下文一并交出去） → `Command`。

### 两个实用技巧

**跳到父图的节点**（子图里想触发父图的另一个分支）：

```python
return Command(goto="other_subgraph", update={"foo": "bar"}, graph=Command.PARENT)
```

**在工具里改图状态**（比如客户支持场景，查完客户资料直接写回状态）：让工具返回 `Command`。

## 编译：图必须 compile 才能用

```python
graph = builder.compile(...)
```

编译做几件事：

- 结构检查（比如有没有孤立节点）；
- 挂上运行时参数——**检查点器、断点**都在这一步传。

```python
graph = builder.compile(checkpointer=checkpointer, cache=InMemoryCache())
```

## 配置与递归限制

```python
class ConfigSchema(TypedDict):
    llm: str

graph = StateGraph(State, config_schema=ConfigSchema)
# ...
graph.invoke(inputs, config={"configurable": {"llm": "anthropic"}})
```

节点里通过 `config["configurable"]["llm"]` 读。

递归限制是**独立的 config 键**，不进 `configurable`：

```python
graph.invoke(inputs, config={"recursion_limit": 5, "configurable": {"llm": "anthropic"}})
```

默认 25 步，超了抛 `GraphRecursionError`。写循环路由的图一定要留意这个值。

## 图的迁移

用检查点存了历史状态之后，改图结构会不会炸？文档给的结论是：

- **跑完的线程**（没中断的）：随便改拓扑，加删改节点边都行。
- **正在中断的线程**：除"重命名/删除节点"外都支持（因为它可能正准备进一个已经不存在的节点）。
- **状态键**：加键、删键向前后兼容；**重命名键会丢掉旧线程里存的值**。

所以：状态键起好名字，别上线了再改。

## 小结

```text
StateGraph(State)
  ├─ add_node(name, fn)                    fn(state, config) -> 部分更新
  ├─ add_edge(START, "a")                  固定跳转
  ├─ add_conditional_edges("a", route_fn)  条件路由（可返回 Send 列表并行）
  └─ compile(checkpointer=...)             必须编译才能 invoke/stream

State 的每个键有独立 reducer：
  无 reducer     → 覆盖
  Annotated[..., add]        → 追加
  Annotated[..., add_messages] → 按消息 ID 追加/覆盖（对话必备）

Node 想同时改状态+跳转 → 返回 Command(goto=..., update=...)
```

下一篇：[智能体架构](/langgraph/agent-architectures)——用这三件套能搭出哪些形状。
