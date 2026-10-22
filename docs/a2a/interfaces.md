# 标准接口全解析

上一篇把数据模型讲完了。这一篇把模型映射到具体的操作上：**每个方法
长什么样、返回什么、流式怎么走、错误怎么回。**

写客户端时对着这一篇抄，写服务端时对着这一篇实现。

## 一、方法命名：先解决一个历史遗留问题

A2A 的方法名改过一轮。三个版本阶段的 JSON-RPC 方法名都不一样：

| 版本 | v0.1 的方法名 | v0.2 / v0.3 的方法名 | v1.0 正式名 | gRPC | REST |
| --- | --- | --- | --- | --- | --- |
| 发消息 | `tasks/send` | `message/send` | `SendMessage` | `SendMessage` | `POST /message:send` |
| 流式发消息 | `tasks/sendSubscribe` | `message/stream` | `SendStreamingMessage` | `SendStreamingMessage` | `POST /message:stream` |
| 取任务 | `tasks/get` | `tasks/get` | `GetTask` | `GetTask` | `GET /tasks/{id}` |
| 列任务 | — | `tasks/list`（仅 gRPC / REST） | `ListTasks` | `ListTasks` | `GET /tasks` |
| 取消任务 | — | `tasks/cancel` | `CancelTask` | `CancelTask` | `POST /tasks/{id}:cancel` |
| 重订阅 | — | `tasks/resubscribe` | `SubscribeToTask` | `SubscribeToTask` | `POST /tasks/{id}:subscribe` |
| 取扩展卡片 | — | `agent/getAuthenticatedExtendedCard` | `GetExtendedAgentCard` | `GetExtendedAgentCard` | `GET /extendedAgentCard` |
| 建推送配置 | — | `tasks/pushNotificationConfig/set` | `CreateTaskPushNotificationConfig` | 同名 | `POST /tasks/{id}/pushNotificationConfigs` |
| 读推送配置 | — | `tasks/pushNotificationConfig/get` | `GetTaskPushNotificationConfig` | 同名 | `GET /tasks/{id}/pushNotificationConfigs/{configId}` |
| 列推送配置 | — | `tasks/pushNotificationConfig/list` | `ListTaskPushNotificationConfigs` | 同名 | `GET /tasks/{id}/pushNotificationConfigs` |
| 删推送配置 | — | `tasks/pushNotificationConfig/delete` | `DeleteTaskPushNotificationConfig` | 同名 | `DELETE /tasks/{id}/pushNotificationConfigs/{configId}` |

**v1.0 的规则：JSON-RPC 与 gRPC 的方法名完全一致，都用 PascalCase。**
REST 绑定用 Google AIP 风格的自定义动词（`:send`、`:cancel`、`:subscribe`）。

两个容易被忽略的细节：

- v0.3 的 `tasks/list` 只在 gRPC 与 REST 绑定上存在，JSON-RPC 侧当时
  是 N/A；v1.0 才把它补齐成三种绑定都有的 `ListTasks`。
- gRPC 侧的方法名在 v0.3 已经用过 PascalCase，但与 v1.0 并不完全相同：
  v0.3 是 `ListTask`、`TaskSubscription`、`CreateTaskPushNotification`、
  `GetAgentCard`，v1.0 统一改成了 `ListTasks`、`SubscribeToTask`、
  `CreateTaskPushNotificationConfig`、`GetExtendedAgentCard`。

取历史从来不是独立方法，它一直是 `GetTask` 的 `historyLength` 参数。

如果你在网上看到 `message/send`、`tasks/get` 这类写法，那是 v0.3 或更早
的代码。v0.3 的斜杠式方法名在 v1.0 里全部改成了 PascalCase。

## 二、请求与响应的骨架

### 2.1 JSON-RPC 基础结构

```json
{
  "jsonrpc": "2.0",
  "id": "req-001",
  "method": "SendMessage",
  "params": { }
}
```

- `id`：请求标识，服务端原样带回。**流式场景下，同一条流里的所有帧
  共用同一个 `id`。**
- `method`：方法名。
- `params`：参数对象。各方法的形状见下。

### 2.2 头部：服务参数走 HTTP 头

A2A 定义了两个 HTTP 头字段：

| 头 | 作用 | 格式 |
| --- | --- | --- |
| `A2A-Version` | 声明客户端使用的协议版本 | `Major.Minor`，如 `1.0` |
| `A2A-Extensions` | 声明本次请求要用的扩展 | 逗号分隔的 URI 列表 |

```http
POST /rpc HTTP/1.1
Host: agent.example.com
Content-Type: application/json
Authorization: Bearer eyJhbGciOi...
A2A-Version: 1.0
A2A-Extensions: https://example.com/extensions/citations/v1

{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "SendMessage",
  "params": { }
}
```

`A2A-Version` 的规则：

- 客户端**必须**在每个请求里带上（0.3 客户端除外，空头按 0.3 处理）；
- 值**必须**是 `Major.Minor` 格式，补丁号**不应当**出现在请求里；
- 服务端**必须**按请求的版本语义处理；
- 版本不支持时**必须**返回 `VersionNotSupportedError`（`-32009`）。

**同一份服务在同一个域名下暴露不同版本**是允许的——只要在
`supportedInterfaces` 里声明不同的 `protocolVersion`：

```json
"supportedInterfaces": [
  { "url": "https://a.example.com/a2a", "protocolBinding": "JSONRPC", "protocolVersion": "1.0" },
  { "url": "https://a.example.com/a2a/v03", "protocolBinding": "JSONRPC", "protocolVersion": "0.3" }
]
```

客户端从 `supportedInterfaces` 里挑一个自己能处理的版本即可。

### 2.3 请求参数对象

`SendMessage` 的参数 `SendMessageRequest`：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `message` | Message | **必填**，要发的消息 |
| `configuration` | SendMessageConfiguration | 可选，行为配置 |
| `metadata` | object | 可选，透传给 Agent 的自定义数据 |
| `tenant` | string | 可选，多租户路由 |

`SendMessageConfiguration`：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `acceptedOutputModes` | string[] | 期望的输出媒体类型，Agent 应尽量满足 |
| `historyLength` | int | 期望返回的历史长度 |
| `taskPushNotificationConfig` | TaskPushNotificationConfig | 推送通知配置 |
| `returnImmediately` | bool | `true` 表示立刻返回 Task，`false`/未设置表示阻塞到终态或中断态 |

`returnImmediately` 是 v1.0 新增的执行模式开关：

- `false` 或未设置（**默认**）：操作**必须**等到任务进入终态
  （`COMPLETED` / `FAILED` / `CANCELED` / `REJECTED`）或中断态
  （`INPUT_REQUIRED` / `AUTH_REQUIRED`）才返回，返回体包含最新的任务状态、
  全部产物与状态信息。
- `true`：创建任务后**立即**返回，处理在后台继续。

注意这个默认值和直觉相反：**默认是阻塞的**。长任务场景下要显式设置
`returnImmediately: true` 或者干脆用流式。

## 三、SendMessage：发起与继续任务

### 3.1 请求

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "SendMessage",
  "params": {
    "message": {
      "messageId": "msg-8a3f",
      "role": "ROLE_USER",
      "parts": [
        { "text": "帮我看看这张发票能不能报" },
        { "url": "https://s3.example.com/inv/inv-2026-0031.png", "filename": "inv.png", "mediaType": "image/png" }
      ]
    },
    "configuration": {
      "acceptedOutputModes": ["text/plain", "application/json"]
    }
  }
}
```

### 3.2 响应：二选一

`SendMessageResponse` 里 `task` 和 `message` **互斥**，必须恰好有一个。

**情况 A：建了任务**（异步处理中）

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "task": {
      "id": "t-1a2b",
      "contextId": "c-9f3e",
      "status": {
        "state": "TASK_STATE_SUBMITTED",
        "timestamp": "2026-03-01T10:00:00.000Z"
      }
    }
  }
}
```

**情况 B：直接回消息**（秒回，无任务追踪）

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "message": {
      "messageId": "msg-agent-77",
      "contextId": "c-9f3e",
      "role": "ROLE_AGENT",
      "parts": [{ "text": "当前 25℃，晴。" }]
    }
  }
}
```

**什么时候用哪种？** 规范给了判断依据：

- 简单交互、结果能立刻给出 → 返回 Message；
- 需要跟踪、需要产物、需要多轮 → 返回 Task。

客户端**必须**同时处理这两种情况。只处理 Task 的客户端在遇到纯问答
Agent 时会崩。

### 3.3 三类错误

| 错误 | 触发条件 |
| --- | --- |
| `ContentTypeNotSupportedError` | 消息里的 mediaType 超出 Agent 支持范围 |
| `UnsupportedOperationError` | 向终态任务继续发消息 |
| `TaskNotFoundError` | 消息里带的 `taskId` 不存在或不可见 |

第二条容易踩：**已完成的 Task 不接受新消息**。想在同一上下文里做新事情，
带 `contextId` 但**不带** `taskId`。

### 3.4 续做与新建的区分

```json
{ "message": { "role": "ROLE_USER", "parts": [...] } }
```
→ 新任务（服务端生成新 `taskId`）

```json
{ "message": { "taskId": "t-1a2b", "role": "ROLE_USER", "parts": [...] } }
```
→ 继续任务 `t-1a2b`

```json
{ "message": { "contextId": "c-9f3e", "role": "ROLE_USER", "parts": [...] } }
```
→ 同一上下文里的**新**任务

```json
{ "message": { "taskId": "t-1a2b", "contextId": "c-9f3e", "role": "ROLE_USER", "parts": [...] } }
```
→ 继续任务 `t-1a2b`，且服务端会校验 `contextId` 与任务匹配，不匹配直接拒绝

## 四、SendStreamingMessage：流式执行

### 4.1 请求

请求体与 `SendMessage` 完全一样，方法名换成 `SendStreamingMessage`，
响应 `Content-Type` 变成 `text/event-stream`：

```http
POST /rpc HTTP/1.1
Content-Type: application/json
Accept: text/event-stream
A2A-Version: 1.0

{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "SendStreamingMessage",
  "params": { "message": { "role": "ROLE_USER", "parts": [{ "text": "写一份气候变化的报告" }] } }
}
```

### 4.2 响应：两种流形态

**形态 A：任务生命周期流**（Agent 返回了 Task）

```
data: {"jsonrpc":"2.0","id":1,"result":{"task":{"id":"t-1a2b","contextId":"c-9f3e","status":{"state":"TASK_STATE_WORKING"}}}}

data: {"jsonrpc":"2.0","id":1,"result":{"artifactUpdate":{"taskId":"t-1a2b","contextId":"c-9f3e","artifact":{"artifactId":"a-1","name":"报告","parts":[{"text":"# 气候变化报告\n\n"}]}}}}

data: {"jsonrpc":"2.0","id":1,"result":{"artifactUpdate":{"taskId":"t-1a2b","contextId":"c-9f3e","artifact":{"artifactId":"a-1","parts":[{"text":"第一章 …"}]},"append":true,"lastChunk":false}}}}

data: {"jsonrpc":"2.0","id":1,"result":{"statusUpdate":{"taskId":"t-1a2b","contextId":"c-9f3e","status":{"state":"TASK_STATE_COMPLETED","timestamp":"2026-03-01T10:05:12.000Z"}}}}
```

**形态 B：消息流**（Agent 直接回消息）

```
data: {"jsonrpc":"2.0","id":1,"result":{"message":{"role":"ROLE_AGENT","parts":[{"text":"当前 25℃，晴。"}]}}}
```

规范对流的形态有硬性要求：

| 要求 | 内容 |
| --- | --- |
| 消息流 | 恰好一帧 Message，然后**立即关闭** |
| 任务流 | 首帧是 Task，随后若干 statusUpdate / artifactUpdate，任务到达终态时**关闭** |
| 顺序 | 所有实现**必须**按生成顺序投递事件，**不得**重排 |

### 4.3 两种流式事件

**`TaskStatusUpdateEvent`**（任务状态变了）

| 字段 | 类型 | 必填 |
| --- | --- | --- |
| `taskId` | string | 是 |
| `contextId` | string | 是 |
| `status` | TaskStatus | 是 |
| `metadata` | object | 否 |

**`TaskArtifactUpdateEvent`**（产物更新了）

| 字段 | 类型 | 必填 |
| --- | --- | --- |
| `taskId` | string | 是 |
| `contextId` | string | 是 |
| `artifact` | Artifact | 是 |
| `append` | bool | 否 |
| `lastChunk` | bool | 否 |
| `metadata` | object | 否 |

`append: true` 表示"把这次的内容追加到之前同 `artifactId` 的产物上"。
这让服务端可以分块推送大产物，客户端边收边渲染。

`lastChunk: true` 表示这是该产物的最后一块。

v1.0 里 `TaskStatusUpdateEvent` **移除了 `final` 字段**——用"流关闭"表示
任务结束，不再用布尔标记。

### 4.4 事件判别方式变了

v0.3 用 `kind` 字段区分，v1.0 用**成员名**：

```python
# v0.3
if event["kind"] == "status-update":
    handle_status(event)
elif event["kind"] == "artifact-update":
    handle_artifact(event)

# v1.0
if "statusUpdate" in event:
    handle_status(event["statusUpdate"])
elif "artifactUpdate" in event:
    handle_artifact(event["artifactUpdate"])
```

注意判别发生在 **`result` 里面**（`StreamResponse` 的四个成员）。
事件对象本身不带判别字段。

## 五、GetTask 与 ListTasks

### 5.1 GetTask

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "GetTask",
  "params": {
    "id": "t-1a2b",
    "historyLength": 10
  }
}
```

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | string | 任务 ID |
| `historyLength` | int | 返回最近多少条历史。语义由 `SendMessageConfiguration` 的同名参数统一规定 |

响应是 `Task` 对象本身：

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "id": "t-1a2b",
    "contextId": "c-9f3e",
    "status": { "state": "TASK_STATE_COMPLETED", "timestamp": "2026-03-01T10:05:12.000Z" },
    "artifacts": [ ],
    "history": [ ]
  }
}
```

**`GetTask` 天然幂等**，重复调用没有副作用。

**鉴权范围**：服务端**只能**返回调用方有权访问的任务。越权访问返回
`TaskNotFoundError`（`-32001`）——规范要求不要通过错误码
差异泄露"资源是否存在"。

### 5.2 ListTasks

v1.0 新增的操作。

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "ListTasks",
  "params": {
    "contextId": "c-9f3e",
    "status": "TASK_STATE_WORKING",
    "pageSize": 50,
    "pageToken": "cursor-token"
  }
}
```

响应：

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "result": {
    "tasks": [ ],
    "totalSize": 15,
    "pageSize": 10,
    "nextPageToken": "base64-encoded-next-cursor-token"
  }
}
```

**游标分页**取代了 v0.3 的页码分页。翻页循环：

```python
page_token = None
while True:
    resp = client.list_tasks(context_id="c-9f3e", page_size=50, page_token=page_token)
    for task in resp.tasks:
        handle(task)
    page_token = resp.next_page_token
    if not page_token:
        break
```

`ListTasks` 也是 v1.0 里**多租户**能力的主要落点——一个端点服务多个租户
时，用 `tenant` 字段做隔离。

## 六、CancelTask

```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "method": "CancelTask",
  "params": { "id": "t-1a2b" }
}
```

响应返回**更新后的 Task**，状态是 `TASK_STATE_CANCELED`：

```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "result": {
    "id": "t-1a2b",
    "contextId": "c-9f3e",
    "status": { "state": "TASK_STATE_CANCELED", "timestamp": "2026-03-01T10:03:00.000Z" }
  }
}
```

要点：

- **取消是幂等的**。多次取消效果相同。
- 任务已在终态时取消，返回 `TaskNotCancelableError`（`-32002`）。
- 任务已被清理后取消，可能返回 `TaskNotFoundError`。
- **取消是协作式的**。服务端收到取消请求后需要主动停止执行。
  如果 Agent 内部跑的是一个不可中断的长任务，状态可能长时间停在
  `WORKING`——这是实现方要解决的问题。

## 七、SubscribeToTask：重连与补发

流式连接断掉之后，用这个方法重新订阅：

```json
{
  "jsonrpc": "2.0",
  "id": 5,
  "method": "SubscribeToTask",
  "params": { "id": "t-1a2b" }
}
```

响应与 `SendStreamingMessage` 相同格式的 SSE 流。

规范对重连有几条明确要求：

| 要求 | 内容 |
| --- | --- |
| 终态任务 | 返回 `UnsupportedOperationError` |
| 多路订阅 | 允许同一任务有**多个并发订阅**，所有流收到**相同顺序**的相同事件 |
| 关闭一个流 | **不得**影响同一任务的其他流 |
| 任务生命周期 | 独立于任何单个流的生命周期 |
| 事件顺序 | **必须**按生成顺序，不重排 |

"多路订阅"这一条在生产上很有用：多个团队成员可以同时盯同一个长任务，
运维面板和业务面板可以各订阅各的。

**断线期间的事件补发（backfill）**是各实现自由度较大的部分。规范没有
强制规定补发多少，但明确了责任边界：

> 客户端**不得**把消息当作关键信息的可靠投递机制。

稳妥的做法是：**关键状态靠 `GetTask` 拉，事件流只用于增强体验。**

## 八、推送通知（Webhook）

适合"客户端会断线"或"服务器到服务器"的场景。

### 8.1 注册

在 `SendMessage` 的 `configuration` 里带上：

```json
{
  "message": {
    "role": "ROLE_USER",
    "parts": [{ "text": "生成 Q1 销售报告，完了通知我" }],
    "messageId": "6dbc13b5-bd57-4c2b-b503-24e381b6c8d6"
  },
  "configuration": {
    "taskPushNotificationConfig": {
      "url": "https://client.example.com/webhook/a2a-notifications",
      "authentication": {
        "scheme": "Bearer",
        "credentials": "secure-client-token-for-task-aaa"
      }
    }
  }
}
```

`TaskPushNotificationConfig` 的字段：

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `url` | string | 是 | webhook 地址 |
| `token` | string | 否 | 校验用 token |
| `authentication` | AuthenticationInfo | 否 | 认证信息 |
| `tenant` | string | 否 | 多租户 |
| `id` | string | 否 | 配置 ID |
| `taskId` | string | 否 | 关联任务 |

也可以事后单独管理：

| 方法 | 作用 |
| --- | --- |
| `CreateTaskPushNotificationConfig` | 创建 |
| `GetTaskPushNotificationConfig` | 读单个 |
| `ListTaskPushNotificationConfigs` | 列出 |
| `DeleteTaskPushNotificationConfig` | 删除 |

### 8.2 投递

Agent 向 webhook 发 POST：

```http
POST /webhook/a2a-notifications HTTP/1.1
Host: client.example.com
Authorization: Bearer secure-client-token-for-task-aaa
Content-Type: application/a2a+json

{
  "statusUpdate": {
    "taskId": "43667960-d455-4453-b0cf-1bae4955270d",
    "contextId": "c295ea44-7543-4f78-b524-7a38915ad6e4",
    "status": {
      "state": "TASK_STATE_COMPLETED",
      "timestamp": "2024-03-15T18:30:00.000Z"
    }
  }
}
```

**载荷格式与流式响应一致**，都是 `StreamResponse` 的四选一。

规范的责任划分：

**服务端（Agent 侧）**

- **必须**至少尝试投递一次；
- **可以**实现指数退避重试；
- **应当**设置合理超时（建议 10–30 秒）；
- **可以**在连续失败达到阈值后放弃。

**客户端（webhook 接收方）**

- **必须**用 2xx 状态码确认收到；
- **应当**幂等处理（重复投递会发生）；
- **必须**校验 `taskId` 与预期一致；
- **应当**验证通知来源。

**无论用哪种协议绑定，webhook 走的都是普通 HTTP + JSON 载荷。**

### 8.3 四个推送配置方法的细节

| 方法 | params | 返回 |
| --- | --- | --- |
| `CreateTaskPushNotificationConfig` | `TaskPushNotificationConfig` | `TaskPushNotificationConfig` |
| `GetTaskPushNotificationConfig` | `{ taskId, id }` | `TaskPushNotificationConfig` |
| `ListTaskPushNotificationConfigs` | `{ taskId, pageSize, pageToken }` | `{ configs, nextPageToken }` |
| `DeleteTaskPushNotificationConfig` | `{ taskId, id }` | 空 |

v1.0 把 `tasks/{taskId}/pushNotificationConfigs/{configId}` 这种复合 ID
拆成了 `taskId` 和 `id` 两个独立字段——**所有 ID 现在都是简单字面量**，
可以直接映射到数据库主键。

## 九、GetExtendedAgentCard

```json
{
  "jsonrpc": "2.0",
  "id": 6,
  "method": "GetExtendedAgentCard",
  "params": { "tenant": "acme-corp" }
}
```

返回一张完整的 `AgentCard`，内容比公开卡片详细。

| 情况 | 返回 |
| --- | --- |
| `capabilities.extendedAgentCard` 为 false 或缺失 | `UnsupportedOperationError` |
| 声明支持但没配置 | `ExtendedAgentCardNotConfiguredError` |

取到的扩展卡片**应当**替换缓存的公开卡片（有效期到本次鉴权会话结束
或卡片 `version` 变化为止）。

## 十、错误处理

### 10.1 错误响应结构

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "error": {
    "code": -32001,
    "message": "Task not found",
    "data": [
      {
        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
        "reason": "TASK_NOT_FOUND",
        "domain": "a2a-protocol.org",
        "metadata": {
          "taskId": "nonexistent-task-id",
          "timestamp": "2025-11-09T10:30:00.000Z"
        }
      }
    ]
  }
}
```

`data` 数组里的每个对象**必须**有 `@type`。推荐用 `google.rpc` 里的
标准类型：

| 类型 | 用途 |
| --- | --- |
| `google.rpc.ErrorInfo` | 机器可读的错误原因、域、附加元数据 |
| `google.rpc.BadRequest` | 字段级校验失败明细 |

字段级错误的完整例子：

```json
{
  "code": -32602,
  "message": "Invalid parameters",
  "data": [
    {
      "@type": "type.googleapis.com/google.rpc.BadRequest",
      "fieldViolations": [
        { "field": "message.parts", "description": "At least one part is required" }
      ]
    }
  ]
}
```

### 10.2 五类错误语义

| 类别 | HTTP | gRPC | JSON-RPC | 含义 |
| --- | --- | --- | --- | --- |
| 认证失败 | 401 | `UNAUTHENTICATED` | -32000 段 | 凭据缺失或无效 |
| 授权失败 | 403 | `PERMISSION_DENIED` | -32000 段 | 权限不足 |
| 校验失败 | 400 | `INVALID_ARGUMENT` | `-32602` | 参数非法 |
| 资源不存在 | 404 | `NOT_FOUND` | `-32001` | 任务不存在或不可见 |
| 系统错误 | 500 / 503 | `INTERNAL` / `UNAVAILABLE` | `-32603` | 内部故障、限流、超时 |

规范对每类错误都给了服务端的**必须 / 应当**要求，几个要点：

- 认证失败时**应当**带上认证挑战信息，说明需要哪种认证方案；
- 授权失败时**应当**指出缺哪个权限/作用域，但**不得**泄露无权访问的
  资源的存在性；
- 校验失败时**应当**指出哪个参数错了、为什么错、正确格式是什么；
- 资源不存在时**不应当**区分"不存在"和"无权访问"；
- 系统错误**应当**区分临时故障和永久故障，**可以**带上 `Retry-After`。

## 十一、三种绑定对照

### 11.1 完整映射表

| 功能 | JSON-RPC | gRPC | REST |
| --- | --- | --- | --- |
| 发消息 | `SendMessage` | `SendMessage` | `POST /message:send` |
| 流式发消息 | `SendStreamingMessage` | `SendStreamingMessage` | `POST /message:stream` |
| 取任务 | `GetTask` | `GetTask` | `GET /tasks/{id}` |
| 列任务 | `ListTasks` | `ListTasks` | `GET /tasks` |
| 取消任务 | `CancelTask` | `CancelTask` | `POST /tasks/{id}:cancel` |
| 订阅任务 | `SubscribeToTask` | `SubscribeToTask` | `POST /tasks/{id}:subscribe` |
| 建推送配置 | `CreateTaskPushNotificationConfig` | 同名 | `POST /tasks/{id}/pushNotificationConfigs` |
| 读推送配置 | `GetTaskPushNotificationConfig` | 同名 | `GET /tasks/{id}/pushNotificationConfigs/{configId}` |
| 列推送配置 | `ListTaskPushNotificationConfigs` | 同名 | `GET /tasks/{id}/pushNotificationConfigs` |
| 删推送配置 | `DeleteTaskPushNotificationConfig` | 同名 | `DELETE /tasks/{id}/pushNotificationConfigs/{configId}` |
| 取扩展卡片 | `GetExtendedAgentCard` | 同名 | `GET /extendedAgentCard` |

::: warning 规范自身的一处不一致
`SubscribeToTask` 的 REST 端点，规范正文 §5.3 与 §11.3.2 都写作
`POST /tasks/{id}:subscribe`，而权威的 `a2a.proto` 里
`google.api.http` 标注是 `get: "/tasks/{id=*}:subscribe"`。本表按
规范正文写 POST；实现时以所用 SDK 的实际路由为准，两者都要能接受。
:::

### 11.2 三个绑定的定位

| | JSON-RPC | gRPC | HTTP+JSON |
| --- | --- | --- | --- |
| 传输 | HTTP/1.1 或 2 | HTTP/2 | HTTP/1.1 或 2 |
| 内容类型 | `application/json` | Protobuf | `application/a2a+json` |
| 流式 | SSE | 服务端流式 RPC | SSE |
| 强类型 | 无 | 有（proto 生成） | 无 |
| 网关友好度 | 一般 | 差 | 好 |
| 跨语言成本 | 低 | 中（需 protoc） | 低 |
| 适用 | 跨厂商首选 | 内部服务网格 | 已有 REST 网关 |

**选型建议**：对外跨组织用 JSON-RPC 或 REST；内部同构服务网格用 gRPC；
不要为了"性能"把对外接口换成 gRPC——跨组织的瓶颈通常在模型调用和
人工等待，不在序列化。

### 11.3 REST 绑定的查询参数规则

GET / DELETE 没有请求体，参数走查询串，命名用 **camelCase**（跟 JSON
序列化保持一致）：

| Protobuf 字段 | 查询参数 | 示例 |
| --- | --- | --- |
| `context_id` | `contextId` | `?contextId=uuid` |
| `page_size` | `pageSize` | `?pageSize=50` |
| `page_token` | `pageToken` | `?pageToken=cursor` |
| `task_id` | `taskId` | `?taskId=uuid` |

类型转换规则：

| 类型 | 表示 |
| --- | --- |
| 字符串 | 直接传 |
| 布尔 | 小写 `true` / `false` |
| 数字 | 十进制字符串 |
| 枚举 | 字符串值，如 `status=TASK_STATE_WORKING` |
| 重复字段 | 重复参数名 `?tag=v1&tag=v2` 或逗号分隔 `?tag=v1,v2` |
| 嵌套对象 | **不支持**，必须用 POST + 请求体 |
| 时间戳 | ISO 8601 字符串 |

### 11.4 REST 绑定的错误格式

```http
HTTP/1.1 404 Not Found
Content-Type: application/a2a+json

{
  "error": {
    "code": 404,
    "status": "NOT_FOUND",
    "message": "The specified task ID does not exist or is not accessible",
    "details": [
      {
        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
        "reason": "TASK_NOT_FOUND",
        "domain": "a2a-protocol.org",
        "metadata": { "taskId": "task-123", "timestamp": "2026-03-01T10:30:00.000Z" }
      }
    ]
  }
}
```

注意 v1.0 把 HTTP+JSON 的错误模型从 RFC 9457（Problem Details）换成了
`google.rpc.Status` 的 ProtoJSON 表示，错误内容类型随之改为
`application/a2a+json`（官方 "What's New in v1.0" 摘要里写作
`application/json`，规范正文 §11.6 的示例用的是 `application/a2a+json`）。
规范里仍有一些旧示例用 `application/problem+json`，那属于遗留。

## 十二、多租户

v1.0 新增的原生多租户支持，机制很轻：

| 位置 | 字段 | 作用 |
| --- | --- | --- |
| `AgentInterface` | `tenant` | 该接口默认的租户 |
| `SendMessageRequest` | `tenant` | 每次请求指定租户 |

规范要求：

- 客户端**必须**把选中接口的 `tenant` 值原样填进每个请求消息；
- 接口没设 `tenant` 时，该字段省略；
- `tenant` 是**不透明串**，协议不定义它的格式和语义，解释权在服务端。

**最典型的用法**：一个端点后面挂多个 Agent 实例，用 `tenant` 路由：

```json
"supportedInterfaces": [
  {
    "url": "https://agents.example.com/a2a",
    "protocolBinding": "JSONRPC",
    "protocolVersion": "1.0",
    "tenant": "acme"
  }
]
```

## 十三、扩展机制

### 13.1 声明

Agent Card 里声明支持的扩展：

```json
"capabilities": {
  "extensions": [
    {
      "uri": "https://example.com/extensions/citations/v1",
      "description": "支持在产物中附带引用来源",
      "required": false,
      "params": { "maxCitations": 10 }
    }
  ]
}
```

| 字段 | 说明 |
| --- | --- |
| `uri` | 扩展的唯一标识 |
| `description` | 这个 Agent 怎么用这个扩展 |
| `required` | true 表示客户端**必须**理解并遵守 |
| `params` | 扩展相关配置 |

### 13.2 协商

客户端在请求头里声明要用的扩展：

```http
A2A-Extensions: https://example.com/extensions/citations/v1
```

服务端在响应头里回它实际启用的：

```http
A2A-Extensions: https://example.com/extensions/citations/v1
```

**硬约束**：服务端要求某个 `required: true` 的扩展，而客户端没声明支持时，
服务端**必须**返回 `ExtensionSupportRequiredError`（`-32008`）。

### 13.3 扩展点

规范定义了消息级和产物级两个扩展点：

| 扩展点 | 用途 |
| --- | --- |
| `Message.extensions` | 消息级扩展 URI 列表 |
| `Artifact.extensions` | 产物级扩展 URI 列表 |

配套的约定是：**`extensions[]` 放 URI 列表，扩展数据放进同一对象的
`metadata`，key 就是那个扩展 URI**：

```json
{
  "role": "ROLE_USER",
  "parts": [{ "text": "Find restaurants near me" }],
  "extensions": ["https://example.com/extensions/geolocation/v1"],
  "metadata": {
    "https://example.com/extensions/geolocation/v1": {
      "latitude": 37.7749,
      "longitude": -122.4194
    }
  }
}
```

选择原则：**能用标准字段表达的，不要做成扩展。** 扩展是给标准表达不了的
东西留的口子，滥用会让互操作性归零。

## 十四、小结

- v1.0 的方法名是 PascalCase，与 gRPC 完全一致；v0.1 / v0.3 的斜杠式
  方法名（`message/send`、`tasks/get`、`tasks/cancel`、
  `tasks/resubscribe`）已被取代。
- `SendMessage` 返回 `Task` 或 `Message`，客户端**必须**两种都处理。
- 默认 `returnImmediately` 为 false，即阻塞等待；长任务要显式设置或用流式。
- 流式用 SSE，帧内容是 `StreamResponse`（四选一），事件顺序有保证，
  同一任务支持多路并发订阅。
- 关键状态靠 `GetTask` 拉，事件流只做体验增强——消息不保证可靠投递。
- 推送走普通 HTTP POST，载荷同样是 `StreamResponse`。
- 错误有 A2A 专属码段（`-32001` ~ `-32009`），细节走 `google.rpc`。
- 三种绑定功能等价，选型看组织网关生态，不看序列化性能。

下一篇：[通信模型：智能体之间怎么对话](/a2a/communication)。
