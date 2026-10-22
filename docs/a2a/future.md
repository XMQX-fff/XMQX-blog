# 收尾：未来方向与资源清单

最后一篇分三部分：**A2A 正在往哪个方向走**、**扩展机制怎么用**、
**去哪里找资料**。

## 一、演进的主线

把 v0.1 到 v1.0 的变化串起来看，能看出三条清晰的演进主线。

### 1.1 主线一：从"能通"到"能互操作"

v0.1 解决的是"两个 Agent 能互相说话"。v1.0 解决的是"不同厂商的
Agent 实现能互相说话"。这条线上的动作：

| 版本 | 动作 | 解决的问题 |
| --- | --- | --- |
| v0.1 | JSON-RPC over HTTP | 基础通信 |
| v0.2 | `message/send` / `message/stream` 等斜杠方法名 | 方法名稳定下来 |
| v0.3 | gRPC 绑定 | 内部服务网格兼容、强类型 |
| v0.3 | HTTP+JSON/REST 绑定 | 已有 REST 网关兼容 |
| v0.3 | 能力等价性要求 | 三种绑定语义必须一致 |
| v0.3 | `/.well-known/agent-card.json` | 发现路径定名 |
| v1.0 | proto 成为唯一权威 | 消除规范漂移 |
| v1.0 | 方法名统一为 PascalCase | 跨绑定一致 |
| v1.0 | 游标分页（`pageSize` / `pageToken`） | 大规模任务列举 |
| v1.0 | 错误 detail 统一到 `google.rpc.ErrorInfo`（gRPC / HTTP 绑定用 `google.rpc.Status`） | 跨厂商错误语义一致 |
| v1.0 | RFC 8785 规范化 + JWS 签名 | 卡片可信 |
| v1.0 | 多租户 `tenant` | 单端点服务多租户 |
| v1.0 | 扩展的 `required` 机制 | 强约束的能力协商 |

**趋势判断**：规范的重心已经从"定义协议"转向"保证互操作"。
社区已经在这条线上动手：官方 roadmap 列出了 **A2A Inspector** 与
**A2A Protocol Technology Compatibility Kit（TCK）**两个验证项目，
目标是让不同厂商的实现跑同一套一致性测试。

### 1.2 主线二：从"能表达"到"能约束"

早期 A2A 的能力声明已经是声明式布尔，客户端要自己判断能不能用。
v1.0 把它变成了服务端侧的硬约束：

> 如果 `capabilities.streaming` 为 false 或缺失，
> `SendStreamingMessage` 和 `SubscribeToTask` **必须**返回
> `UnsupportedOperationError`。

同样地：

- `pushNotifications` 为 false → 推送配置操作**必须**报
  `PushNotificationNotSupportedError`；
- `extendedAgentCard` 为 false → 取扩展卡片**必须**报
  `UnsupportedOperationError`；声明支持但没配卡片 → **必须**报
  `ExtendedAgentCardNotConfiguredError`；
- 扩展标记 `required: true` → 客户端没声明支持**必须**报
  `ExtensionSupportRequiredError`。

**这条演进方向会继续**：从"能力开关"走向"能力契约"——
声明支持什么之外，还要声明**保证什么**（SLA、数据保真度、
副作用语义）。

### 1.3 主线三：从"能跑"到"能被平台管"

v1.0 加入多租户、签名验证、版本协商，说明 A2A 已经从"技术协议"
走向"企业平台构件"。后续大概率会补上：

| 方向 | 说明 |
| --- | --- |
| **一致性测试套件** | 跨厂商实现的互操作认证（A2A Inspector 与 TCK 已在推进） |
| **Agent 目录标准** | 跨组织的 Agent 注册与检索 |
| **能力语义词汇表** | 跨领域的技能分类标准（类似 CNCF 的标签约定） |
| **计费与配额语义** | Agent 之间的调用计费与结算 |
| **可观测性约定** | A2A 专属的 span 属性与指标命名 |

## 二、值得关注的四个方向

### 2.1 扩展机制

规范 4.6 节定义了扩展机制，这是协议保持稳定又能演进的关键。

**扩展的声明**（在 Agent Card 里）：

```json
"capabilities": {
  "extensions": [
    {
      "uri": "https://example.com/extensions/citations/v1",
      "description": "在产物中附带引用来源列表",
      "required": false,
      "params": { "maxCitations": 10 }
    }
  ]
}
```

**扩展的协商**：

```http
A2A-Extensions: https://example.com/extensions/citations/v1
```

**扩展的两个挂载点**：

| 挂载点 | 用途 |
| --- | --- |
| `Message.extensions` | 消息级扩展 URI 列表 |
| `Artifact.extensions` | 产物级扩展 URI 列表 |

配套约定是：**`extensions[]` 放 URI 列表，扩展数据放进同一对象的
`metadata`，key 就是那个扩展 URI**。

**写扩展的几条原则**：

1. **能用标准字段表达的，不要做成扩展。** 扩展越多，互操作性越差。
2. **URI 要稳定且可解析。** 用域名，不要用临时链接。
3. **`required: true` 要慎用。** 标成必需之后，不支持的客户端就完全
   不能用这个 Agent 了。
4. **版本放 URI 里。** `.../citations/v1`，不兼容时开 `/v2`。
5. **在 Agent Card 里写清楚 `description`。** 客户端据此判断能不能用。

**一个最小的扩展示例**。假设想扩展"结构化产物的模式声明"：

```json
{
  "message": {
    "role": "ROLE_USER",
    "parts": [{ "text": "给我开票列表" }],
    "extensions": ["https://example.com/extensions/schema-hint/v1"]
  }
}
```

配合 `metadata` 里的 schema 提示（key 用扩展 URI）：

```json
{
  "data": { "tickets": [] },
  "mediaType": "application/json",
  "metadata": {
    "https://example.com/extensions/schema-hint/v1": {
      "schema": {
        "type": "object",
        "properties": {
          "tickets": {
            "type": "array",
            "items": {
              "type": "object",
              "properties": {
                "id": { "type": "string" },
                "status": { "type": "string", "enum": ["open", "pending", "closed"] }
              }
            }
          }
        }
      }
    }
  }
}
```

**这个扩展解决的实际问题**：下游 Agent 知道该返回什么结构，
不需要靠自然语言约定。它是个扩展，因为标准字段里没有"schema 提示"
这个位置——`Part.metadata` 虽然能放，但 `Part` 不是规范的扩展挂载点，
放那里等于自造约定。

**更好的做法**：如果结构化产物是核心契约，考虑通过**自定义绑定**
在绑定层解决。做成扩展会弱化约束力。

### 2.2 自定义协议绑定

规范第 12 章定义了自定义绑定的准入要求。这是给"标准三种绑定都不
适合"的场景留的口子。

**自定义绑定必须满足的要求**：

| 要求 | 说明 |
| --- | --- |
| **功能等价** | 必须实现全部核心操作，语义与标准绑定一致 |
| **数据模型一致** | Task / Message / Artifact 的字段语义不能变 |
| **错误映射** | 必须定义到 A2A 错误类型的映射表 |
| **能力声明** | Agent Card 里必须声明这个绑定；`protocolBinding` 是开放字符串，自定义绑定建议用 URI 标识（规范 §5.8 / §12.7） |
| **互操作测试** | 应当通过与其他绑定的等价性测试 |

**什么时候值得做自定义绑定**：

- 现有的三种绑定都跑不进你的基础设施（比如某种特定的消息中间件）；
- 需要极致的性能特性，标准绑定的序列化开销不可接受；
- 有现成的企业级协议规范可以复用（比如某种内部 RPC 规范）。

**不值得做的原因**：每多一种绑定，生态就多一份互操作负担。
**绑定是最后的手段**，首选永远是标准的那三种。

### 2.3 A2A 与 MCP 的持续融合

两个协议起源不同，如今同在 Agentic AI Foundation 下，生态里的融合是必然的：

- **同一个 Agent 同时提供 A2A 和 MCP 端点**——已经是常见做法；
- **把 A2A Agent 暴露成 MCP 资源**——官方指南的 "Representing A2A Agents
  as MCP Resources" 一节专门讨论了这件事："一个 A2A Server（远程 Agent）
  可以把部分技能暴露成 MCP 兼容的资源"；
- **A2A 客户端从 MCP 的工具描述里发现 A2A Agent**——技术上可行，
  正在被探索。

**融合的技术基础**：A2A 的 Agent Card 里有 `skills[].description`、
`tags`、`examples`，这些字段和 MCP 的工具描述在语义上高度重合。
一个 MCP Server 可以把 A2A Agent 的技能包装成工具，
一个 Agent 也可以从 MCP Server 里发现并调用远端 Agent。

**这会带来一个有意思的推论**：A2A 的 Agent Card 未来可能会成为
**Agent 能力的通用描述格式**，被各种协议和平台引用。

### 2.4 与 Agentic AI Foundation 的关系

2026 年 8 月，A2A 加入 **Agentic AI Foundation**（AAIF）。
这个基金会同时托管多个互操作相关的项目。

**这件事的意义**：

| 方面 | 影响 |
| --- | --- |
| **治理** | 从单一厂商主导转向基金会治理，版本决策更中立 |
| **协作** | 与 MCP 等项目在同一治理框架下协调，边界更清晰 |
| **标准地位** | 更容易被企业采购清单和合规要求接受 |
| **中立性** | 不会有"某家云的私有扩展"变成事实标准 |

**对使用者的实际影响**：

- 规范的演进节奏可能加快，也可能出现几次破坏性变更；
- 跟着官方 SDK 走，升级成本最低；
- 关注 Release Notes，尤其是 JSON-RPC 方法名和数据模型的变化。

## 三、v1.0 到 v1.1 的可能方向

以下是基于 v1.0 现有设计的合理推测，仅供参考：

| 方向 | 依据 | 影响 |
| --- | --- | --- |
| **一致性测试套件** | 规范强调互操作性，缺少验证手段 | 各厂商实现兼容性提升 |
| **跨厂商 Agent 目录标准** | 发现机制目前只有 well-known URI 和自定义目录 | 跨组织发现变简单 |
| **语义化的能力分类** | `tags` 是自由字符串，跨组织路由不准 | 路由准确率提升 |
| **流式的事件回放协议** | backfill 语义未标准化 | 断线重连更可靠 |
| **Part 的 `raw` 分块传输** | 大文件只能走 `url` | 减少对对象存储的依赖 |
| **调用计费语义** | 跨组织调用的成本归属问题 | 商业化落地 |
| **跨 Agent 的引用与溯源** | `referenceTaskIds` 已有基础 | 可解释性增强 |

## 四、怎么跟进 A2A

### 4.1 三个信息源

| 来源 | 用途 | 频率 |
| --- | --- | --- |
| **Release Notes** | 版本变更的第一手信息 | 每次发版 |
| **规范正文** | 权威定义 | 每次发版 |
| **Roadmap / 社区讨论** | 了解方向 | 持续 |

**只读规范正文是不够的。** v1.0 的变更里，最影响代码的是
"Part 类型合并"和"枚举值改格式"这类数据模型变更——
只看正文容易漏掉迁移指南。

### 4.2 升级检查清单

每次升级 A2A 版本，按这张表过一遍：

```text
[ ] 读 Release Notes，列出所有 breaking changes
[ ] 全局搜索旧方法名（message/send、message/stream、tasks/get、
    tasks/cancel、tasks/resubscribe、tasks/list、
    tasks/pushNotificationConfig/{set,get,list,delete}、
    agent/getAuthenticatedExtendedCard）
[ ] 全局搜索 .kind 判别（part.kind、event.kind）
[ ] 全局搜索 fileWithUri / fileWithBytes / mimeType
[ ] 全局搜索小写枚举值（"completed"、"working"、"input-required"、
    "auth-required"、"user"、"agent"）
[ ] 检查 Agent Card 的 supportedInterfaces 改造
    （顶层 url / preferredTransport / additionalInterfaces / protocolVersion
      全部并入 supportedInterfaces）
[ ] 检查顶层 supportsAuthenticatedExtendedCard
    → capabilities.extendedAgentCard 的迁移
[ ] 检查 statusUpdateEvent.final 字段的移除
[ ] 检查 pushNotificationConfig 的模型变化（字段拍平）
[ ] 检查分页参数（page / perPage → pageSize / pageToken）
[ ] 检查 error.data 从对象改成数组
[ ] 更新 A2A-Version 头
[ ] 跑一遍端到端测试
```

**前三项的搜索是静默失效的高发区。** 旧代码在 v1.0 下不报错，
只是走到错误分支。

### 4.3 版本策略

| 你的情况 | 建议 |
| --- | --- |
| 内部自用，Agent 少 | 跟最新版，出问题好改 |
| 内部生产，Agent 多 | 锁版本，跟 SDK 的 LTS 走 |
| 对外提供 Agent 服务 | 暴露多个 `supportedInterfaces` 版本，让客户端选 |
| 跨组织集成 | 双方协商一个共同支持的版本 |

**注意 `supportedInterfaces` 的多版本能力是 v1.0 的正式特性**，
可以真的同时提供 v0.3 和 v1.0 端点。

## 五、资源清单

### 5.1 官方

| 资源 | 地址 |
| --- | --- |
| 官网 | [a2a-protocol.org](https://a2a-protocol.org/latest/) |
| 规范正文 | [a2a-protocol.org/latest/specification](https://a2a-protocol.org/latest/specification/) |
| v1.0 变更说明 | [What's New in v1.0](https://a2a-protocol.org/latest/whats-new-v1/) |
| 协议定义（proto） | [specification/a2a.proto](https://github.com/a2aproject/A2A/blob/main/specification/a2a.proto) |
| 主仓库 | [github.com/a2aproject/A2A](https://github.com/a2aproject/A2A) |
| Release Notes | [github.com/a2aproject/A2A/releases](https://github.com/a2aproject/A2A/releases) |
| Roadmap | [a2a-protocol.org/latest/roadmap](https://a2a-protocol.org/latest/roadmap/) |
| 社区 | [a2a-protocol.org/latest/community](https://a2a-protocol.org/latest/community/) |
| 博客 | [a2a-protocol.org/latest/blog](https://a2a-protocol.org/latest/blog/) |

### 5.2 SDK

| 语言 | 仓库 |
| --- | --- |
| Python | [a2a-python](https://github.com/a2aproject/a2a-python) |
| Java | [a2a-java](https://github.com/a2aproject/a2a-java) |
| JS / TS | [a2a-js](https://github.com/a2aproject/a2a-js) |
| Go | [a2a-go](https://github.com/a2aproject/a2a-go) |
| .NET | [a2a-dotnet](https://github.com/a2aproject/a2a-dotnet) |
| Rust | [a2a-rs](https://github.com/a2aproject/a2a-rs) |

**选 SDK 的建议**：优先选你主力语言的官方 SDK；
需要多语言互操作时，JSON-RPC 绑定是最通用的选择。

### 5.3 主题文档

| 主题 | 地址 |
| --- | --- |
| What is A2A | [/topics/what-is-a2a](https://a2a-protocol.org/latest/topics/what-is-a2a/) |
| A2A 与 MCP | [/topics/a2a-and-mcp](https://a2a-protocol.org/latest/topics/a2a-and-mcp/) |
| 核心概念 | [/topics/key-concepts](https://a2a-protocol.org/latest/topics/key-concepts/) |
| 任务生命周期 | [/topics/life-of-a-task](https://a2a-protocol.org/latest/topics/life-of-a-task/) |
| Agent 发现 | [/topics/agent-discovery](https://a2a-protocol.org/latest/topics/agent-discovery/) |
| 企业特性 | [/topics/enterprise-ready](https://a2a-protocol.org/latest/topics/enterprise-ready/) |
| 流式与异步 | [/topics/streaming-and-async](https://a2a-protocol.org/latest/topics/streaming-and-async/) |
| 多租户 | [/topics/multi-tenancy](https://a2a-protocol.org/latest/topics/multi-tenancy/) |
| 扩展 | [/topics/extensions](https://a2a-protocol.org/latest/topics/extensions/) |
| 自定义绑定 | [/topics/custom-protocol-bindings](https://a2a-protocol.org/latest/topics/custom-protocol-bindings/) |

### 5.4 教程与课程

| 资源 | 说明 |
| --- | --- |
| [Python 快速上手](https://a2a-protocol.org/latest/tutorials/python/1-introduction/) | 官方 8 篇连载，从安装到流式与多轮 |
| [DeepLearning.AI 课程](https://goo.gle/dlai-a2a) | 官方合作课程 |
| [A2A 规范 + 概念](https://a2a-protocol.org/latest/) | 站点提供 `llms.txt`，适合喂给 AI 助手 |

**`llms.txt` 值得提一句**：A2A 文档站提供了 `llms.txt`，
里面是给大模型用的精简版文档。读规范时如果上下文有限，
可以先让它读这个。

### 5.5 相关的其它协议

| 协议 | 解决的问题 | 关系 |
| --- | --- | --- |
| **MCP** | Agent ↔ 工具 | 互补，纵向 |
| **AGENTS.md** | Agent 的项目级说明文件 | 生态配套 |
| **W3C Trace Context** | 分布式追踪 | 可以直接用在 A2A 上 |
| **RFC 8785 (JCS)** | JSON 规范化 | Agent Card 签名依赖 |
| **RFC 7515 (JWS)** | JSON Web 签名 | Agent Card 签名依赖 |
| **RFC 8628** | OAuth 设备码流 | v1.0 新增支持 |
| **RFC 7636** | PKCE | v1.0 的 OAuth 增强 |
| **RFC 9111** | HTTP 缓存 | Agent Card 缓存语义依赖 |

## 六、写在最后

### 6.1 这个协议的三个优点

**第一，它解决了一个真实且普遍的问题。** 智能体一旦跨越组织边界，
"每个团队自己定协议"就是必然结果。A2A 把这件事标准化了，
而且标准定得足够克制——HTTP + JSON-RPC + SSE，没有发明新东西。

**第二，它的设计原则是清晰的。** 复用现有标准、企业就绪、异步优先、
模态无关、不透明执行。这五条原则在很多具体设计里都能对上号，
能推出规范里的绝大多数决定。

**第三，它的边界划得很干净。** 管通信不管编排，管 Agent 不管工具，
跨组织协作的场景收益最大。**清晰的边界让协议能长期稳定。**

### 6.2 两个需要注意的地方

**第一，生态还在早期。** v1.0 系列发布不到一年（v1.0.0 于 2026-03 发布，
v1.0.1 于 2026-05 发布），SDK 的成熟度、跨厂商的互操作性、真实的
生产案例，都需要时间积累。**选型时要考虑这一点。**

**第二，它解决不了的问题依然存在。** 流程编排、共享记忆、复杂的
错误恢复、跨 Agent 的调试——这些都需要你自己的基础设施。
**A2A 给你的是通信的地基，房子还得自己盖。**

### 6.3 给不同读者的建议

| 你是 | 建议 |
| --- | --- |
| **想快速了解** | 读[开篇](/a2a/why-a2a) + [核心认知](/a2a/core-concepts)，够了 |
| **要实现客户端** | [接口全解析](/a2a/interfaces) + [通信模型](/a2a/communication) + [附录](/a2a/appendix) |
| **要实现服务端** | [核心模型](/a2a/data-model) + [动手实战 1](/a2a/hands-on-minimal) + [生产落地](/a2a/production) |
| **要做架构设计** | [系统架构](/a2a/architecture) + [调用时序](/a2a/sequence) + [对比选型](/a2a/comparison) |
| **要接 RAG / 工具** | [动手实战 2](/a2a/hands-on-rag) |
| **正要上线** | [生产落地](/a2a/production) + [避坑专题](/a2a/pitfalls) |

### 6.4 回到最开始的问题

[开篇](/a2a/why-a2a)里问的是"我们为什么需要 A2A"。现在可以给出
更精确的答案了：

**A2A 存在的理由是：智能体生态正在跨出单个应用的边界，
而"跨边界协作"这件事此前只有约定，没有标准。**

如果你的智能体还都在一个进程里，A2A 帮不了你什么。
一旦你需要跟另一个团队的 Agent 打交道，A2A 就是目前最完整、
最中立、跨厂商互操作性最好的答案。

**这就是全部。** 剩下的都是工程量。

## 七、回顾

- 协议分三层：数据模型 → 抽象操作 → 协议绑定。
- 六个核心角色：Client、Server、Agent Card、Task、Message、Artifact。
- Task 有 9 个状态，4 个终态、2 个中断态。
- Message 用于交流，Artifact 用于交付。
- Agent Card 是能力发现的入口；卡片**可以**带 JWS 签名用于校验来源。
- 可靠性能靠 `GetTask` 拉状态 + 事件流做体验；`messageId` 可用于去重
  （规范写的是 MAY，不是保证）。
- 工具属于 Agent 内部，不属于协议。
- 跨边界是 A2A 唯一不可替代的价值所在。
- 落地的三个必要条件：网关做治理、编排器做流程、存储做持久化。

---

回到[栏目首页](/a2a/)，或者读[附录：核心 JSON Schema](/a2a/appendix)。
