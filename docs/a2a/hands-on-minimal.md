# 动手实战 1：最小 A2A Demo

前面五篇都是纸面知识。这一篇用**纯协议**实现一套最小可用的 A2A：
一个 Agent Card、一个 `SendMessage` 端点、两个 Agent 协同完成任务。

不引入 LangGraph、不引入 A2A SDK、不引入任何编排框架。全部手写，
这样能把协议本身看清楚。

## 一、目标与设计

### 1.1 要跑通什么

```text
用户 → 报销 Agent（接收发票并出结论）
          │  ① 读卡片
          ▼
       政策 Agent（判断费用是否符合差旅政策）
          │  ② 反问：需要发票日期
          ▼
       报销 Agent 补充信息 → 政策 Agent 给出结论
```

这个场景刻意设计成**双向的**：

1. 报销 Agent 发消息给政策 Agent；
2. 政策 Agent 判定信息不足，把任务切到 `TASK_STATE_INPUT_REQUIRED`
   并反问；
3. 报销 Agent 收到反问后，带上补充信息再发一次；
4. 政策 Agent 给出最终结论（Artifact）；
5. 报销 Agent 汇总成自己的 Artifact 返回用户。

这中间会用到：`SendMessage`、`GetTask`、多轮续做、`INPUT_REQUIRED`
中断态、Artifact 交付。

### 1.2 文件结构

```text
a2a-mini/
├── requirements.txt
├── protocol.py      # 数据模型与状态机（协议层）
├── server.py        # 通用 A2A 服务端（框架层）
├── client.py        # A2A 客户端
├── policy_agent.py  # 政策 Agent
├── expense_agent.py # 报销 Agent
└── run.py           # 启动脚本
```

## 二、协议层：数据模型与状态机

`protocol.py`：

```python
from __future__ import annotations

import time
import uuid
from dataclasses import asdict, dataclass, field
from typing import Any, Literal

TaskState = Literal[
    "TASK_STATE_SUBMITTED",
    "TASK_STATE_WORKING",
    "TASK_STATE_INPUT_REQUIRED",
    "TASK_STATE_AUTH_REQUIRED",
    "TASK_STATE_COMPLETED",
    "TASK_STATE_FAILED",
    "TASK_STATE_CANCELED",
    "TASK_STATE_REJECTED",
]

TERMINAL_STATES = {
    "TASK_STATE_COMPLETED",
    "TASK_STATE_FAILED",
    "TASK_STATE_CANCELED",
    "TASK_STATE_REJECTED",
}

INTERRUPTED_STATES = {"TASK_STATE_INPUT_REQUIRED", "TASK_STATE_AUTH_REQUIRED"}

ALLOWED_TRANSITIONS: dict[str, set[str]] = {
    "TASK_STATE_SUBMITTED": {
        "TASK_STATE_WORKING",
        "TASK_STATE_REJECTED",
        "TASK_STATE_CANCELED",
        "TASK_STATE_FAILED",
    },
    "TASK_STATE_WORKING": {
        "TASK_STATE_INPUT_REQUIRED",
        "TASK_STATE_AUTH_REQUIRED",
        "TASK_STATE_COMPLETED",
        "TASK_STATE_FAILED",
        "TASK_STATE_CANCELED",
    },
    "TASK_STATE_INPUT_REQUIRED": {"TASK_STATE_WORKING", "TASK_STATE_CANCELED"},
    "TASK_STATE_AUTH_REQUIRED": {"TASK_STATE_WORKING", "TASK_STATE_CANCELED"},
    "TASK_STATE_COMPLETED": set(),
    "TASK_STATE_FAILED": set(),
    "TASK_STATE_CANCELED": set(),
    "TASK_STATE_REJECTED": set(),
}


def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())


def new_id() -> str:
    return str(uuid.uuid4())


class ProtocolError(Exception):
    def __init__(self, code: int, message: str, data: list[dict[str, Any]] | None = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.data = data or []

    def to_jsonrpc(self, request_id: Any) -> dict[str, Any]:
        return {
            "jsonrpc": "2.0",
            "id": request_id,
            "error": {"code": self.code, "message": self.message, "data": self.data},
        }


def not_found(request_id: Any, message: str = "Task not found") -> dict[str, Any]:
    return ProtocolError(
        -32001,
        message,
        [
            {
                "@type": "type.googleapis.com/google.rpc.ErrorInfo",
                "reason": "TASK_NOT_FOUND",
                "domain": "a2a-protocol.org",
            }
        ],
    ).to_jsonrpc(request_id)


@dataclass
class Part:
    text: str | None = None
    url: str | None = None
    data: Any = None
    media_type: str | None = None
    filename: str | None = None

    def to_json(self) -> dict[str, Any]:
        out: dict[str, Any] = {}
        if self.text is not None:
            out["text"] = self.text
        if self.url is not None:
            out["url"] = self.url
        if self.data is not None:
            out["data"] = self.data
        if self.media_type is not None:
            out["mediaType"] = self.media_type
        if self.filename is not None:
            out["filename"] = self.filename
        return out

    @staticmethod
    def text_part(text: str) -> "Part":
        return Part(text=text, media_type="text/plain")

    @staticmethod
    def data_part(data: Any) -> "Part":
        return Part(data=data, media_type="application/json")

    @classmethod
    def from_json(cls, raw: dict[str, Any]) -> "Part":
        return cls(
            text=raw.get("text"),
            url=raw.get("url"),
            data=raw.get("data"),
            media_type=raw.get("mediaType"),
            filename=raw.get("filename"),
        )


@dataclass
class Message:
    role: str
    parts: list[Part]
    message_id: str = field(default_factory=new_id)
    context_id: str | None = None
    task_id: str | None = None
    metadata: dict[str, Any] | None = None

    def to_json(self) -> dict[str, Any]:
        out: dict[str, Any] = {
            "messageId": self.message_id,
            "role": self.role,
            "parts": [p.to_json() for p in self.parts],
        }
        if self.context_id:
            out["contextId"] = self.context_id
        if self.task_id:
            out["taskId"] = self.task_id
        if self.metadata:
            out["metadata"] = self.metadata
        return out

    @staticmethod
    def from_json(raw: dict[str, Any]) -> "Message":
        return Message(
            role=raw["role"],
            parts=[Part.from_json(p) for p in raw.get("parts", [])],
            message_id=raw.get("messageId", new_id()),
            context_id=raw.get("contextId"),
            task_id=raw.get("taskId"),
            metadata=raw.get("metadata"),
        )

    def first_text(self) -> str:
        for p in self.parts:
            if p.text:
                return p.text
        return ""

    def first_data(self) -> Any:
        for p in self.parts:
            if p.data is not None:
                return p.data
        return None


@dataclass
class Artifact:
    artifact_id: str
    parts: list[Part]
    name: str | None = None
    description: str | None = None
    metadata: dict[str, Any] | None = None

    def to_json(self) -> dict[str, Any]:
        out: dict[str, Any] = {
            "artifactId": self.artifact_id,
            "parts": [p.to_json() for p in self.parts],
        }
        if self.name:
            out["name"] = self.name
        if self.description:
            out["description"] = self.description
        if self.metadata:
            out["metadata"] = self.metadata
        return out


@dataclass
class TaskStatus:
    state: TaskState
    message: Message | None = None
    timestamp: str = field(default_factory=now_iso)

    def to_json(self) -> dict[str, Any]:
        out: dict[str, Any] = {"state": self.state, "timestamp": self.timestamp}
        if self.message:
            out["message"] = self.message.to_json()
        return out


@dataclass
class Task:
    id: str
    context_id: str
    status: TaskStatus
    artifacts: list[Artifact] = field(default_factory=list)
    history: list[Message] = field(default_factory=list)
    metadata: dict[str, Any] | None = None

    def to_json(self) -> dict[str, Any]:
        out: dict[str, Any] = {
            "id": self.id,
            "contextId": self.context_id,
            "status": self.status.to_json(),
        }
        if self.artifacts:
            out["artifacts"] = [a.to_json() for a in self.artifacts]
        if self.history:
            out["history"] = [m.to_json() for m in self.history]
        if self.metadata:
            out["metadata"] = self.metadata
        return out

    @property
    def is_terminal(self) -> bool:
        return self.status.state in TERMINAL_STATES

    @property
    def is_interrupted(self) -> bool:
        return self.status.state in INTERRUPTED_STATES
```

### 2.1 状态迁移校验

状态机必须在服务端强制执行，不能靠"大家记得别这么写"：

```python
def assert_transition(current: str, target: str) -> None:
    # 同态迁移 = 状态不变、只更新进度说明，规范允许：
    # TaskStatusUpdateEvent 每次都会带一份新的 TaskStatus。
    if current == target:
        return
    allowed = ALLOWED_TRANSITIONS.get(current, set())
    if target not in allowed:
        raise ProtocolError(
            -32004,
            f"Illegal task transition: {current} -> {target}",
            [
                {
                    "@type": "type.googleapis.com/google.rpc.ErrorInfo",
                    "reason": "UNSUPPORTED_OPERATION",
                    "domain": "a2a-protocol.org",
                    "metadata": {"from": current, "to": target},
                }
            ],
        )
```

**这一段是整个 Demo 里最值得抄走的东西。** 没有它，Agent 的代码里
到处会出现"任务已经完成了但状态又被改成 working"这类诡异 bug。

> 错误码这里用的是 `-32004 UnsupportedOperationError`。`-32002` 在规范里
> 专指"取消一个已经终态的任务"（`TaskNotCancelableError`），拿它表示
> 状态机非法迁移会让对端按错误的语义去分支。

## 三、服务端：通用 A2A 骨架

`server.py`。这一层跟业务无关，任何 Agent 都能复用。

```python
from __future__ import annotations

import asyncio
import json
import uuid
from typing import Any, AsyncIterator, Awaitable, Callable

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse

from protocol import (
    Artifact,
    INTERRUPTED_STATES,
    Message,
    Part,
    ProtocolError,
    Task,
    TaskStatus,
    TERMINAL_STATES,
    assert_transition,
    new_id,
    not_found,
    now_iso,
)

Handler = Callable[["RequestContext"], Awaitable[None]]


class RequestContext:
    def __init__(self, task: Task, message: Message, emitter: "EventEmitter"):
        self.task = task
        self.message = message
        self.emitter = emitter
        self.store = emitter.store

    async def transition(self, state: str, note: str | None = None) -> None:
        assert_transition(self.task.status.state, state)
        self.task.status.state = state
        self.task.status.timestamp = now_iso()
        if note:
            self.task.status.message = Message(
                role="ROLE_AGENT", parts=[Part.text_part(note)]
            )
        self.store.put(self.task)
        await self.emitter.emit_status(self.task)

    async def add_artifact(self, artifact: Artifact) -> None:
        self.task.artifacts.append(artifact)
        self.store.put(self.task)
        await self.emitter.emit_artifact(self.task, artifact)

    async def complete(self, note: str | None = None) -> None:
        await self.transition("TASK_STATE_COMPLETED", note)

    async def fail(self, note: str) -> None:
        await self.transition("TASK_STATE_FAILED", note)

    async def ask(self, question: str) -> None:
        await self.transition("TASK_STATE_INPUT_REQUIRED", question)


class TaskStore:
    def __init__(self) -> None:
        self._tasks: dict[str, Task] = {}
        self._lock = asyncio.Lock()

    def put(self, task: Task) -> None:
        self._tasks[task.id] = task

    def get(self, task_id: str) -> Task | None:
        return self._tasks.get(task_id)

    def list(self, context_id: str | None = None) -> list[Task]:
        items = list(self._tasks.values())
        if context_id:
            items = [t for t in items if t.context_id == context_id]
        return items


class EventEmitter:
    def __init__(self, store: TaskStore):
        self.store = store
        self.queue: asyncio.Queue[dict[str, Any] | None] = asyncio.Queue()
        self.closed = False

    async def emit_status(self, task: Task) -> None:
        await self.queue.put(
            {
                "statusUpdate": {
                    "taskId": task.id,
                    "contextId": task.context_id,
                    "status": task.status.to_json(),
                }
            }
        )

    async def emit_artifact(self, task: Task, artifact: Artifact) -> None:
        await self.queue.put(
            {
                "artifactUpdate": {
                    "taskId": task.id,
                    "contextId": task.context_id,
                    "artifact": artifact.to_json(),
                    "append": False,
                    "lastChunk": True,
                }
            }
        )

    async def close(self) -> None:
        self.closed = True
        await self.queue.put(None)


class A2AServer:
    def __init__(self, card: dict[str, Any], handler: Handler):
        self.card = card
        self.handler = handler
        self.store = TaskStore()
        self.app = FastAPI()
        self._register_routes()

    def _register_routes(self) -> None:
        app = self.app

        @app.get("/.well-known/agent-card.json")
        async def agent_card() -> JSONResponse:
            return JSONResponse(
                self.card,
                headers={"Cache-Control": "public, max-age=300", "ETag": f'"{self.card["version"]}"'},
            )

        @app.post("/rpc")
        async def rpc(request: Request) -> Any:
            body = await request.json()
            request_id = body.get("id")
            method = body.get("method")
            params = body.get("params") or {}

            if method == "SendMessage":
                return await self._send_message(request_id, params)
            if method == "GetTask":
                return self._get_task(request_id, params)
            if method == "CancelTask":
                return self._cancel_task(request_id, params)
            if method == "ListTasks":
                return self._list_tasks(request_id, params)
            return JSONResponse(
                ProtocolError(-32601, "Method not found").to_jsonrpc(request_id),
                status_code=200,
            )

        @app.post("/rpc/stream")
        async def rpc_stream(request: Request) -> Any:
            body = await request.json()
            request_id = body.get("id")
            params = body.get("params") or {}
            return await self._stream(request_id, params)

    async def _send_message(self, request_id: Any, params: dict[str, Any]) -> JSONResponse:
        raw = params.get("message")
        if not raw:
            return JSONResponse(
                ProtocolError(-32602, "Invalid params").to_jsonrpc(request_id),
                status_code=200,
            )
        message = Message.from_json(raw)

        existing: Task | None = None
        if message.task_id:
            existing = self.store.get(message.task_id)
            if existing is None:
                return JSONResponse(not_found(request_id), status_code=200)
            if existing.context_id and message.context_id and existing.context_id != message.context_id:
                return JSONResponse(
                    ProtocolError(-32602, "contextId does not match task").to_jsonrpc(request_id),
                    status_code=200,
                )
            if existing.is_terminal:
                return JSONResponse(
                    ProtocolError(-32004, "Task is in a terminal state").to_jsonrpc(request_id),
                    status_code=200,
                )

        if existing is None:
            task = Task(
                id=new_id(),
                context_id=message.context_id or new_id(),
                status=TaskStatus(state="TASK_STATE_SUBMITTED"),
            )
            self.store.put(task)
        else:
            task = existing
            assert_transition(task.status.state, "TASK_STATE_WORKING")
            task.status.state = "TASK_STATE_WORKING"
            task.status.timestamp = now_iso()

        task.history.append(message)
        self.store.put(task)

        emitter = EventEmitter(self.store)
        ctx = RequestContext(task, message, emitter)

        config = params.get("configuration") or {}
        immediate = config.get("returnImmediately", False)

        if immediate:
            asyncio.create_task(self._run_handler(ctx))
            return JSONResponse(
                {"jsonrpc": "2.0", "id": request_id, "result": {"task": task.to_json()}}
            )

        await self._run_handler(ctx)
        return JSONResponse(
            {"jsonrpc": "2.0", "id": request_id, "result": {"task": task.to_json()}}
        )

    async def _run_handler(self, ctx: RequestContext) -> None:
        try:
            await self.handler(ctx)
        except ProtocolError as exc:
            ctx.task.status.state = "TASK_STATE_FAILED"
            ctx.task.status.timestamp = now_iso()
            ctx.task.status.message = Message(
                role="ROLE_AGENT", parts=[Part.text_part(exc.message)]
            )
            ctx.store.put(ctx.task)
            await ctx.emitter.emit_status(ctx.task)
        except Exception as exc:  # noqa: BLE001
            ctx.task.status.state = "TASK_STATE_FAILED"
            ctx.task.status.timestamp = now_iso()
            ctx.task.status.message = Message(
                role="ROLE_AGENT", parts=[Part.text_part(f"internal error: {exc}")]
            )
            ctx.store.put(ctx.task)
            await ctx.emitter.emit_status(ctx.task)
        finally:
            await ctx.emitter.close()

    def _get_task(self, request_id: Any, params: dict[str, Any]) -> JSONResponse:
        task = self.store.get(params.get("id", ""))
        if task is None:
            return JSONResponse(not_found(request_id), status_code=200)
        return JSONResponse(
            {"jsonrpc": "2.0", "id": request_id, "result": task.to_json()}
        )

    def _list_tasks(self, request_id: Any, params: dict[str, Any]) -> JSONResponse:
        tasks = self.store.list(params.get("contextId"))
        return JSONResponse(
            {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {
                    "tasks": [t.to_json() for t in tasks],
                    "totalSize": len(tasks),
                    "pageSize": params.get("pageSize", 50),
                    "nextPageToken": "",
                },
            }
        )

    def _cancel_task(self, request_id: Any, params: dict[str, Any]) -> JSONResponse:
        task = self.store.get(params.get("id", ""))
        if task is None:
            return JSONResponse(not_found(request_id), status_code=200)
        if task.is_terminal:
            return JSONResponse(
                ProtocolError(-32002, "Task is not cancelable").to_jsonrpc(request_id),
                status_code=200,
            )
        assert_transition(task.status.state, "TASK_STATE_CANCELED")
        task.status.state = "TASK_STATE_CANCELED"
        task.status.timestamp = now_iso()
        self.store.put(task)
        return JSONResponse(
            {"jsonrpc": "2.0", "id": request_id, "result": task.to_json()}
        )

    async def _stream(self, request_id: Any, params: dict[str, Any]) -> StreamingResponse:
        raw = params.get("message") or {}
        message = Message.from_json(raw)
        task = Task(
            id=new_id(),
            context_id=message.context_id or new_id(),
            status=TaskStatus(state="TASK_STATE_SUBMITTED"),
        )
        task.history.append(message)
        self.store.put(task)

        emitter = EventEmitter(self.store)
        ctx = RequestContext(task, message, emitter)

        async def frames() -> AsyncIterator[str]:
            first = {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {"task": task.to_json()},
            }
            yield f"data: {json.dumps(first, ensure_ascii=False)}\n\n"
            runner = asyncio.create_task(self._run_handler(ctx))
            while True:
                item = await emitter.queue.get()
                if item is None:
                    break
                frame = {"jsonrpc": "2.0", "id": request_id, "result": item}
                yield f"data: {json.dumps(frame, ensure_ascii=False)}\n\n"
            await runner

        return StreamingResponse(
            frames(),
            media_type="text/event-stream",
            headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
        )
```

### 3.1 服务端骨架的四个关键点

**第一，错误也用 HTTP 200。** JSON-RPC 2.0 的错误在响应体里，
HTTP 状态码保持 200。只有协议层错误（比如 JSON 解析失败）才用 4xx/5xx。

**第二，任务存储用内存字典 + 锁。** 生产环境换成数据库，
接口形状不变。

**第三，`returnImmediately` 决定是否后台执行。** 立即返回时用
`asyncio.create_task` 起后台协程。

**第四，SSE 响应头带 `X-Accel-Buffering: no`。** nginx 默认会缓冲
SSE 响应，不关掉的话客户端会等缓冲满了才看到内容，流式就废了。

## 四、客户端

`client.py`：

```python
from __future__ import annotations

import json
from typing import Any, AsyncIterator

import httpx


class A2AError(Exception):
    def __init__(self, code: int, message: str, data: list[dict[str, Any]] | None = None):
        super().__init__(f"[{code}] {message}")
        self.code = code
        self.message = message
        self.data = data or []


class A2AClient:
    def __init__(self, base_url: str, token: str | None = None, version: str = "1.0"):
        self.base_url = base_url.rstrip("/")
        self.token = token
        self.version = version

    def _headers(self, extra: dict[str, str] | None = None) -> dict[str, str]:
        headers = {
            "Content-Type": "application/json",
            "A2A-Version": self.version,
        }
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        if extra:
            headers.update(extra)
        return headers

    async def get_card(self) -> dict[str, Any]:
        async with httpx.AsyncClient() as http:
            resp = await http.get(f"{self.base_url}/.well-known/agent-card.json")
            resp.raise_for_status()
            return resp.json()

    async def call(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        payload = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
        async with httpx.AsyncClient(timeout=300) as http:
            resp = await http.post(
                f"{self.base_url}/rpc", json=payload, headers=self._headers()
            )
            resp.raise_for_status()
            body = resp.json()
        if "error" in body:
            err = body["error"]
            raise A2AError(err["code"], err.get("message", ""), err.get("data"))
        return body["result"]

    async def send_message(
        self,
        parts: list[dict[str, Any]],
        task_id: str | None = None,
        context_id: str | None = None,
        message_id: str | None = None,
        return_immediately: bool = False,
        accepted_output_modes: list[str] | None = None,
    ) -> dict[str, Any]:
        message: dict[str, Any] = {
            "role": "ROLE_USER",
            "parts": parts,
        }
        if message_id:
            message["messageId"] = message_id
        if task_id:
            message["taskId"] = task_id
        if context_id:
            message["contextId"] = context_id

        configuration: dict[str, Any] = {"returnImmediately": return_immediately}
        if accepted_output_modes:
            configuration["acceptedOutputModes"] = accepted_output_modes

        result = await self.call(
            "SendMessage",
            {"message": message, "configuration": configuration},
        )
        if "task" in result:
            return result["task"]
        return result["message"]

    async def get_task(self, task_id: str) -> dict[str, Any]:
        return await self.call("GetTask", {"id": task_id})

    async def cancel_task(self, task_id: str) -> dict[str, Any]:
        return await self.call("CancelTask", {"id": task_id})

    async def stream_message(
        self, parts: list[dict[str, Any]], context_id: str | None = None
    ) -> AsyncIterator[dict[str, Any]]:
        message: dict[str, Any] = {"role": "ROLE_USER", "parts": parts}
        if context_id:
            message["contextId"] = context_id
        payload = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "SendStreamingMessage",
            "params": {"message": message},
        }
        headers = self._headers({"Accept": "text/event-stream"})
        async with httpx.AsyncClient(timeout=300) as http:
            async with http.stream(
                "POST", f"{self.base_url}/rpc/stream", json=payload, headers=headers
            ) as resp:
                resp.raise_for_status()
                async for line in resp.aiter_lines():
                    if not line.startswith("data: "):
                        continue
                    body = json.loads(line[6:])
                    if "result" in body:
                        yield body["result"]
```

## 五、两个 Agent

### 5.1 政策 Agent

`policy_agent.py`：

```python
from __future__ import annotations

from protocol import Artifact, Part, new_id
from server import A2AServer, RequestContext

DOMESTIC_FLIGHT_LIMIT = 3000.0
REQUIRED_FIELDS = ("category", "amount", "date")


async def policy_handler(ctx: RequestContext) -> None:
    await ctx.transition("TASK_STATE_WORKING", "正在核对差旅政策…")
    data = ctx.message.first_data() or {}

    missing = [f for f in REQUIRED_FIELDS if f not in data]
    if missing:
        await ctx.ask(f"还需要这些信息才能判定：{'、'.join(missing)}。")
        return

    category = data["category"]
    amount = float(data["amount"])
    limit = DOMESTIC_FLIGHT_LIMIT if category == "transport" else 1000.0
    approved = amount <= limit

    await ctx.add_artifact(
        Artifact(
            artifact_id=new_id(),
            name="政策判定",
            parts=[
                Part.data_part(
                    {
                        "approved": approved,
                        "category": category,
                        "amount": amount,
                        "limit": limit,
                        "policyVersion": "2026-03-01",
                        "reason": (
                            f"{category} 类费用 {amount} 元未超过限额 {limit} 元，予以通过。"
                            if approved
                            else f"{category} 类费用 {amount} 元超过限额 {limit} 元，不予通过。"
                        ),
                    }
                )
            ],
        )
    )
    await ctx.complete("政策核对完成")


POLICY_CARD = {
    "name": "差旅政策 Agent",
    "description": "根据差旅政策判断单笔费用是否合规，输出结构化判定结论。",
    "supportedInterfaces": [
        {
            "url": "http://127.0.0.1:9101/rpc",
            "protocolBinding": "JSONRPC",
            "protocolVersion": "1.0",
        }
    ],
    "version": "1.0.0",
    "capabilities": {"streaming": True, "pushNotifications": False},
    "defaultInputModes": ["application/json", "text/plain"],
    "defaultOutputModes": ["application/json"],
    "skills": [
        {
            "id": "expense-policy-check",
            "name": "差旅费用合规判定",
            "description": "输入费用明细（category / amount / date），输出是否合规、限额与理由。",
            "tags": ["expense", "policy", "compliance"],
            "inputModes": ["application/json"],
            "outputModes": ["application/json"],
        }
    ],
}

policy_server = A2AServer(POLICY_CARD, policy_handler)
```

### 5.2 报销 Agent

`expense_agent.py`。它是"编排者"——收到用户消息后，调用政策 Agent，
处理反问，最后汇总。

```python
from __future__ import annotations

from protocol import Artifact, Message, Part, new_id
from server import A2AServer, RequestContext
from client import A2AClient

POLICY_CLIENT = A2AClient("http://127.0.0.1:9101")

MAX_POLICY_ROUNDS = 3


async def expense_handler(ctx: RequestContext) -> None:
    await ctx.transition("TASK_STATE_WORKING", "正在解析发票…")

    payload = ctx.message.first_data() or {}
    invoice = payload.get("invoice", payload)

    rounds = 0
    while rounds < MAX_POLICY_ROUNDS:
        rounds += 1
        result = await POLICY_CLIENT.send_message(
            parts=[Part.data_part(invoice).to_json()],
            return_immediately=False,
            accepted_output_modes=["application/json"],
        )
        state = result["status"]["state"]

        if state == "TASK_STATE_COMPLETED":
            decision = _extract_data(result)
            await ctx.add_artifact(
                Artifact(
                    artifact_id=new_id(),
                    name="报销结论",
                    parts=[Part.data_part(decision)],
                    metadata={"decision": "approved" if decision.get("approved") else "rejected"},
                )
            )
            await ctx.complete("报销审核完成")
            return

        if state == "TASK_STATE_INPUT_REQUIRED":
            question = _extract_text(result)
            await ctx.task.__setattr__("metadata", {"policyQuestion": question})
            ctx.store.put(ctx.task)
            missing = _guess_missing(invoice, question)
            invoice = {**invoice, **missing}
            continue

        await ctx.fail(f"政策 Agent 返回异常状态：{state}")
        return

    await ctx.fail("与政策 Agent 的交互轮次超限")


def _extract_data(task: dict) -> dict:
    for artifact in task.get("artifacts", []):
        for part in artifact.get("parts", []):
            if "data" in part:
                return part["data"]
    return {}


def _extract_text(task: dict) -> str:
    message = task.get("status", {}).get("message") or {}
    for part in message.get("parts", []):
        if part.get("text"):
            return part["text"]
    return ""


def _guess_missing(invoice: dict, question: str) -> dict:
    filled = {}
    for field in ("category", "amount", "date"):
        if field not in invoice and field in question:
            filled[field] = "2026-02-28" if field == "date" else "transport"
    return filled


EXPENSE_CARD = {
    "name": "报销 Agent",
    "description": "接收发票信息，调用差旅政策 Agent 判定，产出报销结论。",
    "supportedInterfaces": [
        {
            "url": "http://127.0.0.1:9102/rpc",
            "protocolBinding": "JSONRPC",
            "protocolVersion": "1.0",
        }
    ],
    "version": "1.0.0",
    "capabilities": {"streaming": True, "pushNotifications": False},
    "defaultInputModes": ["application/json", "text/plain", "image/png"],
    "defaultOutputModes": ["application/json"],
    "skills": [
        {
            "id": "expense-review",
            "name": "发票报销审核",
            "description": "输入发票信息，输出是否可报销、理由与结构化结论。",
            "tags": ["expense", "invoice", "reimbursement"],
            "inputModes": ["application/json"],
            "outputModes": ["application/json"],
        }
    ],
}

expense_server = A2AServer(EXPENSE_CARD, expense_handler)
```

**这段代码里藏着两个问题**：一是 `ctx.task.__setattr__("metadata", ...)`
是丑陋的写法，而且逻辑上有点绕；二是**每轮都新建一个政策任务**——
`send_message` 没带 `taskId` / `contextId`，政策 Agent 每轮都从
`TASK_STATE_SUBMITTED` 重新开始，问的问题也重来一遍。

靠 `_guess_missing` 去猜字段同样是下策。

下面这个版本更贴近真实做法——报销 Agent 手里有发票信息，它能自己判断
缺什么：

```python
async def expense_handler(ctx: RequestContext) -> None:
    await ctx.transition("TASK_STATE_WORKING", "正在解析发票…")

    payload = ctx.message.first_data() or {}
    invoice = dict(payload.get("invoice", payload))
    invoice.setdefault("date", "2026-02-28")
    invoice.setdefault("category", "transport")

    policy_task = await POLICY_CLIENT.send_message(
        parts=[Part.data_part(invoice).to_json()],
        return_immediately=False,
        accepted_output_modes=["application/json"],
    )
    state = policy_task["status"]["state"]

    if state != "TASK_STATE_COMPLETED":
        await ctx.fail(f"政策 Agent 返回异常状态：{state}")
        return

    decision = _extract_data(policy_task)
    await ctx.add_artifact(
        Artifact(
            artifact_id=new_id(),
            name="报销结论",
            parts=[Part.data_part(decision)],
            metadata={"decision": "approved" if decision.get("approved") else "rejected"},
        )
    )
    await ctx.complete("报销审核完成")
```

但这样就演示不到 `INPUT_REQUIRED` 了。**两种写法各有价值**：

- 上面这版是"生产写法"——Agent 自己知道缺什么，直接补齐再问一次。
- 下面这版是"协议演示写法"——严格按协议的多轮续做来走：

```python
async def expense_handler(ctx: RequestContext) -> None:
    await ctx.transition("TASK_STATE_WORKING", "正在解析发票…")

    payload = ctx.message.first_data() or {}
    invoice = dict(payload.get("invoice", payload))
    context_id = None
    task_id = None

    for _ in range(MAX_POLICY_ROUNDS):
        result = await POLICY_CLIENT.send_message(
            parts=[Part.data_part(invoice).to_json()],
            task_id=task_id,
            context_id=context_id,
            return_immediately=False,
        )
        context_id = result["contextId"]
        task_id = result["id"]
        state = result["status"]["state"]

        if state == "TASK_STATE_COMPLETED":
            decision = _extract_data(result)
            await ctx.add_artifact(
                Artifact(
                    artifact_id=new_id(),
                    name="报销结论",
                    parts=[Part.data_part(decision)],
                )
            )
            await ctx.complete("报销审核完成")
            return

        if state == "TASK_STATE_INPUT_REQUIRED":
            question = _extract_text(result)
            invoice = {**invoice, **_guess_missing(invoice, question)}
            continue

        await ctx.fail(f"政策 Agent 返回异常状态：{state}")
        return

    await ctx.fail("与政策 Agent 的交互轮次超限")
```

**注意 `task_id=task_id` 这一行**——它就是"续做同一个任务"的做法：
第二次调用带上第一次返回的 `taskId`，政策 Agent 那边就当成续做处理，
不会新建任务。这正是[核心模型详解](/a2a/data-model)里说的
"同一个任务的多轮"。

## 六、启动与验证

### 6.1 启动脚本

`run.py`：

```python
import asyncio

import uvicorn

from expense_agent import expense_server
from policy_agent import policy_server


async def main() -> None:
    config = uvicorn.Config(policy_server.app, host="127.0.0.1", port=9101, log_level="warning")
    server = uvicorn.Server(config)
    task = asyncio.create_task(server.serve())

    await asyncio.sleep(0.5)
    config2 = uvicorn.Config(expense_server.app, host="127.0.0.1", port=9102, log_level="warning")
    server2 = uvicorn.Server(config2)
    await server2.serve()
    await task


if __name__ == "__main__":
    asyncio.run(main())
```

`requirements.txt`：

```text
fastapi>=0.115
uvicorn>=0.30
httpx>=0.27
```

### 6.2 验证第一步：读卡片

```bash
curl -s http://127.0.0.1:9102/.well-known/agent-card.json | python3 -m json.tool
```

预期输出（节选）：

```json
{
  "name": "报销 Agent",
  "description": "接收发票信息，调用差旅政策 Agent 判定，产出报销结论。",
  "supportedInterfaces": [
    {
      "url": "http://127.0.0.1:9102/rpc",
      "protocolBinding": "JSONRPC",
      "protocolVersion": "1.0"
    }
  ],
  "version": "1.0.0",
  "capabilities": { "streaming": true, "pushNotifications": false },
  "defaultInputModes": ["application/json", "text/plain", "image/png"],
  "defaultOutputModes": ["application/json"],
  "skills": [
    {
      "id": "expense-review",
      "name": "发票报销审核",
      "description": "输入发票信息，输出是否可报销、理由与结构化结论。",
      "tags": ["expense", "invoice", "reimbursement"]
    }
  ]
}
```

### 6.3 验证第二步：手工发一次请求

```bash
curl -s -X POST http://127.0.0.1:9102/rpc \
  -H 'Content-Type: application/json' \
  -H 'A2A-Version: 1.0' \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "SendMessage",
    "params": {
      "message": {
        "messageId": "msg-8a3f",
        "role": "ROLE_USER",
        "parts": [
          {"data": {"invoice": {"category": "transport", "amount": 1280.5, "date": "2026-02-28"}}, "mediaType": "application/json"}
        ]
      },
      "configuration": {"returnImmediately": false}
    }
  }' | python3 -m json.tool
```

预期输出：

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "task": {
      "id": "...",
      "contextId": "...",
      "status": {
        "state": "TASK_STATE_COMPLETED",
        "timestamp": "2026-03-01T10:00:00.000Z"
      },
      "artifacts": [
        {
          "artifactId": "...",
          "name": "报销结论",
          "parts": [
            {
              "data": {
                "approved": true,
                "category": "transport",
                "amount": 1280.5,
                "limit": 3000.0,
                "policyVersion": "2026-03-01",
                "reason": "transport 类费用 1280.5 元未超过限额 3000.0 元，予以通过。"
              },
              "mediaType": "application/json"
            }
          ]
        }
      ]
    }
  }
}
```

### 6.4 验证第三步：流式

```bash
curl -N -X POST http://127.0.0.1:9102/rpc/stream \
  -H 'Content-Type: application/json' \
  -H 'A2A-Version: 1.0' \
  -H 'Accept: text/event-stream' \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "SendStreamingMessage",
    "params": {
      "message": {
        "messageId": "msg-9b4g",
        "role": "ROLE_USER",
        "parts": [
          {"data": {"invoice": {"category": "transport", "amount": 8800, "date": "2026-02-28"}}, "mediaType": "application/json"}
        ]
      }
    }
  }'
```

预期看到这样的帧序列：

```text
data: {"jsonrpc": "2.0", "id": 1, "result": {"task": {"id": "...", "contextId": "...", "status": {"state": "TASK_STATE_SUBMITTED"}}}}

data: {"jsonrpc": "2.0", "id": 1, "result": {"statusUpdate": {"taskId": "...", "contextId": "...", "status": {"state": "TASK_STATE_WORKING", "message": {"role": "ROLE_AGENT", "parts": [{"text": "正在解析发票…"}]}}}}}

data: {"jsonrpc": "2.0", "id": 1, "result": {"artifactUpdate": {"taskId": "...", "contextId": "...", "artifact": {"artifactId": "...", "name": "报销结论", "parts": [{"data": {"approved": false, "...": "..."}, "mediaType": "application/json"}]}, "append": false, "lastChunk": true}}}

data: {"jsonrpc": "2.0", "id": 1, "result": {"statusUpdate": {"taskId": "...", "contextId": "...", "status": {"state": "TASK_STATE_COMPLETED"}}}}
```

> 政策 Agent 那边的"正在核对差旅政策…"出现在**它自己的** SSE 流里。两个
> Agent 各自维护自己的事件队列，客户端只会看到自己这一侧的事件。

注意金额 8800 超过了 transport 的 3000 限额，所以 `approved` 是 `false`。
**金额改一下就能看到不同的判定结果**——这是验证 Demo 是否跑通的最快方式。

## 七、这个 Demo 演示了什么

| 协议能力 | 在代码里的位置 |
| --- | --- |
| Agent Card 与 well-known URI | `POLICY_CARD` / `EXPENSE_CARD` + `_register_routes` |
| `SendMessage`（发起 + 续做） | `_send_message` 里根据 `taskId` 分支 |
| Task 状态机 | `ALLOWED_TRANSITIONS` + `assert_transition` |
| `INPUT_REQUIRED` 中断态 | `ctx.ask()` + 报销 Agent 的续做循环 |
| Artifact 交付 | `ctx.add_artifact()` |
| `GetTask` / `CancelTask` / `ListTasks` | `_get_task` / `_cancel_task` / `_list_tasks` |
| SSE 流式 | `_stream` + `EventEmitter` |
| JSON-RPC 错误 | `ProtocolError` + `to_jsonrpc` |
| 客户端与 `A2A-Version` 头 | `client.py` 的 `_headers` |

## 八、这个 Demo 缺了什么

对照[系统架构](/a2a/architecture)，这套 Demo 只实现了协议骨架。
生产环境还缺：

| 缺失 | 说明 |
| --- | --- |
| **持久化** | 任务在内存里，进程重启全丢 |
| **鉴权** | 没有 token 校验 |
| **限流** | 没有 |
| **审计日志** | 没有 |
| **真实取消** | `CancelTask` 只改状态，不中断执行 |
| **消息总线** | 同步执行，长任务会占住连接 |
| **重试与退避** | 客户端没有重试逻辑 |
| **幂等去重** | 同一个 `messageId` 发两次会建两个任务 |
| **Agent Card 签名** | 卡片没有签名 |
| **多租户** | `tenant` 字段没实现 |

**下一节先补两个最关键的：幂等去重和真实取消。**

### 8.1 补幂等去重

```python
class IdempotencyIndex:
    def __init__(self) -> None:
        self._by_message: dict[str, str] = {}

    def lookup(self, message_id: str) -> str | None:
        return self._by_message.get(message_id)

    def record(self, message_id: str, task_id: str) -> None:
        self._by_message[message_id] = task_id
```

在 `_send_message` 里，创建任务之前查一次：

```python
existing_id = idempotency.lookup(message.message_id)
if existing_id:
    existing = self.store.get(existing_id)
    if existing:
        return JSONResponse(
            {"jsonrpc": "2.0", "id": request_id, "result": {"task": existing.to_json()}}
        )
```

任务创建成功后再记一笔：

```python
idempotency.record(message.message_id, task.id)
```

这样客户端用同一个 `messageId` 重发时，拿回的是同一个任务。

### 8.2 补真实取消

```python
class ExecutionRegistry:
    def __init__(self) -> None:
        self._cancels: dict[str, asyncio.Event] = {}

    def event_for(self, task_id: str) -> asyncio.Event:
        if task_id not in self._cancels:
            self._cancels[task_id] = asyncio.Event()
        return self._cancels[task_id]
```

`CancelTask` 时 `event.set()`，Agent 的执行循环里检查这个事件：

```python
async def expense_handler(ctx: RequestContext) -> None:
    cancel_event = ctx.registry.event_for(ctx.task.id)
    ...
    for step in steps:
        if cancel_event.is_set():
            await ctx.transition("TASK_STATE_CANCELED", "已被取消")
            return
        await do_step(step)
```

（`ExecutionRegistry` 是服务端的一个单例，挂在 `RequestContext` 上供
handler 取用；也可以直接用模块级变量，两种都行。）

**这就是 `CancelTask` 从"纸面承诺"变成"真取消"的关键改动。**
生产环境里通常还要加上超时兜底和进程级终止。

## 九、跑起来之后的自检

1. `GET /.well-known/agent-card.json` 能拿到卡片吗？
2. 卡片里 `supportedInterfaces[0].url` 指向的地址能连上吗？
3. `SendMessage` 返回的 `result` 里是 `task` 还是 `message`？
4. 任务状态是不是按 `SUBMITTED → WORKING → COMPLETED` 走的？
5. 报错的任务状态是不是 `TASK_STATE_FAILED`，并且 `status.message` 里有原因？
6. 流式响应有没有一帧一帧地出来？（不能等到最后才一次性吐出）
7. 故意发一个不存在的 `taskId`，是不是返回 `-32001`？
8. 故意给一个终态任务发消息，是不是返回 `-32004`？

## 十、换成官方 SDK 之后

这套手写实现的价值在于把协议看清。实际项目里应该用官方 SDK：

```python
from a2a.helpers import new_task_from_user_message, new_text_message
from a2a.server.agent_execution import AgentExecutor, RequestContext
from a2a.server.events import EventQueue
from a2a.server.tasks import TaskUpdater
```

> `new_task_from_user_message` / `new_text_message` 在 `a2a.helpers`
> （`a2a.helpers.proto_helpers`）里，不在 `a2a.utils`。
> `new_text_part` 是更晚的版本才补上的，早期版本请直接构造 `Part`。

差别在哪：

| 维度 | 手写版（本篇） | 官方 SDK |
| --- | --- | --- |
| 协议正确性 | 自己保证 | 官方保证 |
| 状态机 | 自己写 | SDK 提供状态设置方法（终态锁定），迁移表仍要自己定 |
| 流式 | 自己管理队列 | `EventQueue` + `TaskUpdater` |
| 序列化 | 自己写 `to_json` | 自动 |
| 代码量 | 多 | 少 |
| 协议演进 | 要自己跟 | SDK 跟 |

**建议的路径**：先跑通本篇的手写版，把协议理解到位；然后换 SDK 写
生产代码。本篇的价值在于——**出问题时你知道该改哪儿**。

## 十一、小结

- 最小 A2A 实现只需要四样东西：Agent Card、Task 存储、状态机、
  一个 JSON-RPC 入口。
- 状态机校验是服务端最该抄走的部分。
- 多轮续做的关键：第二次 `SendMessage` 带上第一次返回的 `taskId`。
- SSE 的关键：响应头要关缓冲，帧内容是 `StreamResponse`。
- JSON-RPC 错误在响应体里，HTTP 状态码保持 200。
- 幂等靠 `messageId` 去重，真实取消靠执行器协作式检查取消信号。
- 理解了协议之后，换官方 SDK 会非常轻松。

下一篇：[动手实战 2：A2A 对接 RAG 与工具调用](/a2a/hands-on-rag)。
