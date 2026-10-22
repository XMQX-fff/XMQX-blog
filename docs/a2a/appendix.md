# 附录：核心 JSON Schema

本附录把 A2A v1.0 的核心数据对象整理成完整的 JSON Schema，方便写代码
时对照。所有字段以规范第 4 章（Protocol Data Model）为准。

**约定**：

- JSON 字段名统一 **camelCase**（Protobuf 里的 snake_case 在 JSON 序列化
  时转成 camelCase）；
- 枚举值统一 **SCREAMING_SNAKE_CASE**，且带类型前缀；
- 时间戳统一 ISO 8601 UTC 毫秒精度（`YYYY-MM-DDTHH:mm:ss.sssZ`）；
- `Part` 的 `text` / `raw` / `url` / `data` 互斥，恰好出现一个。

## 一、枚举

### 1.1 TaskState

```json
{
  "$comment": "Task 的生命周期状态",
  "enum": [
    "TASK_STATE_UNSPECIFIED",
    "TASK_STATE_SUBMITTED",
    "TASK_STATE_WORKING",
    "TASK_STATE_INPUT_REQUIRED",
    "TASK_STATE_AUTH_REQUIRED",
    "TASK_STATE_COMPLETED",
    "TASK_STATE_FAILED",
    "TASK_STATE_CANCELED",
    "TASK_STATE_REJECTED"
  ]
}
```

| 类别 | 取值 |
| --- | --- |
| 终态（吸收态，不可迁出） | `TASK_STATE_COMPLETED`、`TASK_STATE_FAILED`、`TASK_STATE_CANCELED`、`TASK_STATE_REJECTED` |
| 中断态（可恢复） | `TASK_STATE_INPUT_REQUIRED`、`TASK_STATE_AUTH_REQUIRED` |
| 进行中 | `TASK_STATE_SUBMITTED`、`TASK_STATE_WORKING` |

### 1.2 Role

```json
{
  "enum": ["ROLE_UNSPECIFIED", "ROLE_USER", "ROLE_AGENT"]
}
```

### 1.3 ProtocolBinding

```json
{
  "enum": ["JSONRPC", "GRPC", "HTTP+JSON"],
  "$comment": "开放字符串，可扩展其他绑定"
}
```

### 1.4 AuthenticationInfo（推送通知的认证信息）

`TaskPushNotificationConfig.authentication` 的形状：

```json
{
  "type": "object",
  "required": ["scheme"],
  "properties": {
    "scheme": {
      "type": "string",
      "description": "HTTP 认证方案名，取自 IANA 注册表，如 Bearer、Basic、Digest"
    },
    "credentials": {
      "type": "string",
      "description": "凭据内容，格式随 scheme 而定"
    }
  }
}
```

### 1.5 SecurityRequirement（安全要求）

```json
{
  "type": "object",
  "properties": {
    "schemes": {
      "type": "object",
      "description": "安全方案名 → 所需 scope 列表",
      "additionalProperties": {
        "type": "object",
        "properties": {
          "list": {
            "type": "array",
            "items": { "type": "string" }
          }
        }
      }
    }
  }
}
```

## 二、Part

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://a2a-protocol.org/schemas/v1/Part.json",
  "title": "Part",
  "description": "Message 或 Artifact 里的内容单元。text / raw / url / data 恰好出现一个。",
  "type": "object",
  "properties": {
    "text": {
      "type": "string",
      "description": "文本内容"
    },
    "raw": {
      "type": "string",
      "contentEncoding": "base64",
      "description": "内联字节内容，JSON 中用 base64 编码"
    },
    "url": {
      "type": "string",
      "format": "uri",
      "description": "文件内容的 URL 引用（建议用预签名 URL）"
    },
    "data": {
      "description": "任意结构化数据，JSON 值"
    },
    "mediaType": {
      "type": "string",
      "description": "MIME 类型，如 text/plain、application/json、image/png"
    },
    "filename": {
      "type": "string",
      "description": "文件名"
    },
    "metadata": {
      "type": "object",
      "description": "附加元数据"
    }
  },
  "oneOf": [
    { "required": ["text"] },
    { "required": ["raw"] },
    { "required": ["url"] },
    { "required": ["data"] }
  ],
  "additionalProperties": false
}
```

**示例**：

```json
{ "text": "分析结果如下", "mediaType": "text/plain" }
```

```json
{ "url": "https://s3.example.com/x.png", "filename": "x.png", "mediaType": "image/png" }
```

```json
{ "raw": "iVBORw0KGgoAAAANSUhEUg==", "filename": "x.png", "mediaType": "image/png" }
```

```json
{ "data": { "total": 42 }, "mediaType": "application/json" }
```

## 三、Message

```json
{
  "$id": "https://a2a-protocol.org/schemas/v1/Message.json",
  "title": "Message",
  "description": "客户端与服务端之间的一次通信轮次。",
  "type": "object",
  "required": ["messageId", "role", "parts"],
  "properties": {
    "messageId": {
      "type": "string",
      "description": "消息唯一标识，由消息创建方生成"
    },
    "contextId": {
      "type": "string",
      "description": "关联的上下文分组 ID"
    },
    "taskId": {
      "type": "string",
      "description": "关联的任务 ID"
    },
    "role": {
      "$ref": "#/definitions/Role"
    },
    "parts": {
      "type": "array",
      "minItems": 1,
      "items": { "$ref": "#/definitions/Part" }
    },
    "metadata": {
      "type": "object"
    },
    "extensions": {
      "type": "array",
      "items": { "type": "string", "format": "uri" },
      "description": "本条消息涉及的扩展 URI"
    },
    "referenceTaskIds": {
      "type": "array",
      "items": { "type": "string" },
      "description": "本条消息引用的其他任务 ID"
    }
  },
  "definitions": {
    "Role": {
      "enum": ["ROLE_UNSPECIFIED", "ROLE_USER", "ROLE_AGENT"]
    }
  },
  "additionalProperties": false
}
```

**字段约束补充**（规范 4.1.4 的文字条款）：

- 服务端消息**必须**带 `contextId`；
- 客户端消息的 `contextId` / `taskId` 都可选；
- 两者都提供时**必须**匹配（`contextId` 要等于任务上的那个）；
- 只提供 `taskId` 时，服务端**会**从任务推断 `contextId`。

## 四、Artifact

```json
{
  "$id": "https://a2a-protocol.org/schemas/v1/Artifact.json",
  "title": "Artifact",
  "description": "任务的产出物。",
  "type": "object",
  "required": ["artifactId", "parts"],
  "properties": {
    "artifactId": {
      "type": "string",
      "description": "产物唯一标识，在任务内唯一"
    },
    "name": {
      "type": "string",
      "description": "人类可读名称"
    },
    "description": {
      "type": "string",
      "description": "人类可读描述"
    },
    "parts": {
      "type": "array",
      "minItems": 1,
      "items": { "$ref": "#/definitions/Part" }
    },
    "metadata": {
      "type": "object"
    },
    "extensions": {
      "type": "array",
      "items": { "type": "string", "format": "uri" }
    }
  },
  "definitions": {
    "Part": { "$ref": "https://a2a-protocol.org/schemas/v1/Part.json" }
  },
  "additionalProperties": false
}
```

## 五、TaskStatus 与 Task

### 5.1 TaskStatus

```json
{
  "$id": "https://a2a-protocol.org/schemas/v1/TaskStatus.json",
  "title": "TaskStatus",
  "type": "object",
  "required": ["state"],
  "properties": {
    "state": {
      "$ref": "https://a2a-protocol.org/schemas/v1/TaskState.json"
    },
    "message": {
      "$ref": "https://a2a-protocol.org/schemas/v1/Message.json",
      "description": "与该状态相关的说明消息"
    },
    "timestamp": {
      "type": "string",
      "format": "date-time",
      "pattern": "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{3}Z$",
      "description": "ISO 8601 UTC 毫秒精度"
    }
  },
  "additionalProperties": false
}
```

### 5.2 Task

```json
{
  "$id": "https://a2a-protocol.org/schemas/v1/Task.json",
  "title": "Task",
  "description": "A2A 管理的工作单元，有状态，走状态机。",
  "type": "object",
  "required": ["id", "status"],
  "properties": {
    "id": {
      "type": "string",
      "description": "任务唯一标识，由服务端生成"
    },
    "contextId": {
      "type": "string",
      "description": "上下文分组标识，由服务端生成"
    },
    "status": {
      "$ref": "https://a2a-protocol.org/schemas/v1/TaskStatus.json"
    },
    "artifacts": {
      "type": "array",
      "items": { "$ref": "https://a2a-protocol.org/schemas/v1/Artifact.json" }
    },
    "history": {
      "type": "array",
      "items": { "$ref": "https://a2a-protocol.org/schemas/v1/Message.json" },
      "description": "交互历史。尽力而为，不保证完整。"
    },
    "metadata": {
      "type": "object"
    }
  },
  "additionalProperties": false
}
```

## 六、流式事件

### 6.1 StreamResponse

```json
{
  "$id": "https://a2a-protocol.org/schemas/v1/StreamResponse.json",
  "title": "StreamResponse",
  "description": "流式响应与推送通知的统一载荷包装。四个成员恰好出现一个。",
  "type": "object",
  "properties": {
    "task": { "$ref": "https://a2a-protocol.org/schemas/v1/Task.json" },
    "message": { "$ref": "https://a2a-protocol.org/schemas/v1/Message.json" },
    "statusUpdate": {
      "$ref": "https://a2a-protocol.org/schemas/v1/TaskStatusUpdateEvent.json"
    },
    "artifactUpdate": {
      "$ref": "https://a2a-protocol.org/schemas/v1/TaskArtifactUpdateEvent.json"
    }
  },
  "oneOf": [
    { "required": ["task"] },
    { "required": ["message"] },
    { "required": ["statusUpdate"] },
    { "required": ["artifactUpdate"] }
  ],
  "additionalProperties": false
}
```

### 6.2 TaskStatusUpdateEvent

```json
{
  "$id": "https://a2a-protocol.org/schemas/v1/TaskStatusUpdateEvent.json",
  "title": "TaskStatusUpdateEvent",
  "type": "object",
  "required": ["taskId", "contextId", "status"],
  "properties": {
    "taskId": { "type": "string" },
    "contextId": { "type": "string" },
    "status": { "$ref": "https://a2a-protocol.org/schemas/v1/TaskStatus.json" },
    "metadata": { "type": "object" }
  },
  "additionalProperties": false
}
```

### 6.3 TaskArtifactUpdateEvent

```json
{
  "$id": "https://a2a-protocol.org/schemas/v1/TaskArtifactUpdateEvent.json",
  "title": "TaskArtifactUpdateEvent",
  "type": "object",
  "required": ["taskId", "contextId", "artifact"],
  "properties": {
    "taskId": { "type": "string" },
    "contextId": { "type": "string" },
    "artifact": { "$ref": "https://a2a-protocol.org/schemas/v1/Artifact.json" },
    "append": {
      "type": "boolean",
      "description": "true 表示把内容追加到之前同 artifactId 的产物上"
    },
    "lastChunk": {
      "type": "boolean",
      "description": "true 表示这是该产物的最后一块"
    },
    "metadata": { "type": "object" }
  },
  "additionalProperties": false
}
```

## 七、AgentCard

```json
{
  "$id": "https://a2a-protocol.org/schemas/v1/AgentCard.json",
  "title": "AgentCard",
  "description": "A2A 服务端发布的自描述清单。",
  "type": "object",
  "required": [
    "name",
    "description",
    "supportedInterfaces",
    "capabilities",
    "defaultInputModes",
    "defaultOutputModes",
    "skills",
    "version"
  ],
  "properties": {
    "name": {
      "type": "string",
      "description": "人类可读名称"
    },
    "description": {
      "type": "string",
      "description": "一句话说明这个 Agent 做什么"
    },
    "supportedInterfaces": {
      "type": "array",
      "minItems": 1,
      "items": { "$ref": "#/definitions/AgentInterface" },
      "description": "支持的接口，按偏好排序，第一项是首选"
    },
    "provider": { "$ref": "#/definitions/AgentProvider" },
    "version": {
      "type": "string",
      "description": "Agent 业务版本，如 1.2.0"
    },
    "documentationUrl": { "type": "string", "format": "uri" },
    "iconUrl": { "type": "string", "format": "uri" },
    "capabilities": { "$ref": "#/definitions/AgentCapabilities" },
    "securitySchemes": {
      "type": "object",
      "additionalProperties": { "$ref": "#/definitions/SecurityScheme" }
    },
    "securityRequirements": {
      "type": "array",
      "items": { "$ref": "#/definitions/SecurityRequirement" }
    },
    "defaultInputModes": {
      "type": "array",
      "items": { "type": "string" },
      "description": "默认接受的输入媒体类型"
    },
    "defaultOutputModes": {
      "type": "array",
      "items": { "type": "string" },
      "description": "默认产出的媒体类型"
    },
    "skills": {
      "type": "array",
      "items": { "$ref": "#/definitions/AgentSkill" }
    },
    "signatures": {
      "type": "array",
      "items": { "$ref": "#/definitions/AgentCardSignature" }
    }
  },
  "definitions": {
    "AgentInterface": {
      "type": "object",
      "required": ["url", "protocolBinding", "protocolVersion"],
      "properties": {
        "url": {
          "type": "string",
          "description": "接口地址。HTTP 类必须是绝对 HTTPS URL；gRPC 用 host:port"
        },
        "protocolBinding": {
          "type": "string",
          "description": "JSONRPC / GRPC / HTTP+JSON，开放字符串"
        },
        "protocolVersion": {
          "type": "string",
          "pattern": "^\\d+\\.\\d+$",
          "description": "Major.Minor 格式"
        },
        "tenant": {
          "type": "string",
          "description": "多租户路由用的不透明串"
        }
      },
      "additionalProperties": false
    },
    "AgentProvider": {
      "type": "object",
      "required": ["url", "organization"],
      "properties": {
        "url": { "type": "string", "format": "uri" },
        "organization": { "type": "string" }
      },
      "additionalProperties": false
    },
    "AgentCapabilities": {
      "type": "object",
      "properties": {
        "streaming": { "type": "boolean" },
        "pushNotifications": { "type": "boolean" },
        "extendedAgentCard": { "type": "boolean" },
        "extensions": {
          "type": "array",
          "items": { "$ref": "#/definitions/AgentExtension" }
        }
      },
      "additionalProperties": false
    },
    "AgentExtension": {
      "type": "object",
      "properties": {
        "uri": { "type": "string", "format": "uri" },
        "description": { "type": "string" },
        "required": { "type": "boolean" },
        "params": { "type": "object" }
      },
      "additionalProperties": false
    },
    "AgentSkill": {
      "type": "object",
      "required": ["id", "name", "description", "tags"],
      "properties": {
        "id": { "type": "string" },
        "name": { "type": "string" },
        "description": { "type": "string" },
        "tags": {
          "type": "array",
          "items": { "type": "string" }
        },
        "examples": {
          "type": "array",
          "items": { "type": "string" }
        },
        "inputModes": {
          "type": "array",
          "items": { "type": "string" }
        },
        "outputModes": {
          "type": "array",
          "items": { "type": "string" }
        },
        "securityRequirements": {
          "type": "array",
          "items": { "$ref": "#/definitions/SecurityRequirement" }
        }
      },
      "additionalProperties": false
    },
    "SecurityScheme": {
      "type": "object",
      "properties": {
        "apiKeySecurityScheme": { "type": "object" },
        "httpAuthSecurityScheme": { "type": "object" },
        "oauth2SecurityScheme": { "type": "object" },
        "openIdConnectSecurityScheme": { "type": "object" },
        "mtlsSecurityScheme": { "type": "object" }
      },
      "additionalProperties": false
    },
    "SecurityRequirement": {
      "type": "object",
      "properties": {
        "schemes": {
          "type": "object",
          "additionalProperties": {
            "type": "object",
            "properties": {
              "list": {
                "type": "array",
                "items": { "type": "string" }
              }
            }
          }
        }
      },
      "additionalProperties": false
    },
    "AgentCardSignature": {
      "type": "object",
      "required": ["protected", "signature"],
      "properties": {
        "protected": {
          "type": "string",
          "description": "base64url 编码的 JWS Protected Header"
        },
        "signature": {
          "type": "string",
          "description": "base64url 编码的签名值"
        },
        "header": {
          "type": "object",
          "description": "JWS Unprotected Header"
        }
      },
      "additionalProperties": false
    }
  },
  "additionalProperties": false
}
```

## 八、完整示例

### 8.1 完整的 Agent Card

```json
{
  "name": "差旅报销审核 Agent",
  "description": "接收发票信息，对照差旅政策判定是否合规，产出结构化报销结论。",
  "supportedInterfaces": [
    {
      "url": "https://expense.corp.example.com/a2a",
      "protocolBinding": "JSONRPC",
      "protocolVersion": "1.0"
    },
    {
      "url": "https://expense.corp.example.com/a2a/grpc",
      "protocolBinding": "GRPC",
      "protocolVersion": "1.0"
    }
  ],
  "provider": {
    "organization": "Example Corp 财务共享中心",
    "url": "https://www.example.com"
  },
  "iconUrl": "https://expense.corp.example.com/icon.png",
  "version": "1.2.0",
  "documentationUrl": "https://docs.example.com/expense-agent",
  "capabilities": {
    "streaming": true,
    "pushNotifications": true,
    "extendedAgentCard": true,
    "extensions": [
      {
        "uri": "https://example.com/extensions/citations/v1",
        "description": "在产物中附带制度条款引用",
        "required": false
      }
    ]
  },
  "securitySchemes": {
    "oidc": {
      "openIdConnectSecurityScheme": {
        "openIdConnectUrl": "https://sso.example.com/.well-known/openid-configuration"
      }
    }
  },
  "securityRequirements": [
    { "schemes": { "oidc": { "list": ["openid", "email"] } } }
  ],
  "defaultInputModes": ["application/json", "text/plain", "image/png"],
  "defaultOutputModes": ["application/json", "text/plain"],
  "skills": [
    {
      "id": "expense-review",
      "name": "发票合规审核",
      "description": "输入发票明细（category / amount / date）或发票图片，输出是否合规、限额依据与理由。",
      "tags": ["expense", "invoice", "compliance", "reimbursement"],
      "examples": [
        "这张 1280 元的机票发票能报销吗？",
        "{\"category\": \"meal\", \"amount\": 260, \"date\": \"2026-02-18\"}"
      ],
      "inputModes": ["application/json", "text/plain", "image/png"],
      "outputModes": ["application/json"]
    }
  ]
}
```

### 8.2 一次完整的会话

**第一步：发消息（同步等待）**

```json
{
  "jsonrpc": "2.0",
  "id": "req-001",
  "method": "SendMessage",
  "params": {
    "message": {
      "messageId": "msg-8a3f",
      "role": "ROLE_USER",
      "parts": [
        {
          "data": {
            "category": "transport",
            "amount": 1280.5,
            "date": "2026-02-18"
          },
          "mediaType": "application/json"
        }
      ]
    },
    "configuration": {
      "acceptedOutputModes": ["application/json"],
      "returnImmediately": false
    }
  }
}
```

**第二步：响应**

```json
{
  "jsonrpc": "2.0",
  "id": "req-001",
  "result": {
    "task": {
      "id": "t-1a2b",
      "contextId": "c-9f3e",
      "status": {
        "state": "TASK_STATE_COMPLETED",
        "timestamp": "2026-03-01T10:00:03.120Z"
      },
      "artifacts": [
        {
          "artifactId": "a-1",
          "name": "报销结论",
          "description": "基于 2026-03-01 版差旅政策的判定结果",
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
          ],
          "metadata": {
            "decision": "approved",
            "policyDocId": "policy-2026"
          }
        }
      ],
      "history": [
        {
          "messageId": "msg-8a3f",
          "role": "ROLE_USER",
          "parts": [
            {
              "data": {
                "category": "transport",
                "amount": 1280.5,
                "date": "2026-02-18"
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

**第三步：多轮补充（Agent 反问后客户端补充）**

服务端先返回中断态：

```json
{
  "jsonrpc": "2.0",
  "id": "req-002",
  "result": {
    "task": {
      "id": "t-1a2b",
      "contextId": "c-9f3e",
      "status": {
        "state": "TASK_STATE_INPUT_REQUIRED",
        "message": {
          "messageId": "msg-agent-77",
          "contextId": "c-9f3e",
          "taskId": "t-1a2b",
          "role": "ROLE_AGENT",
          "parts": [
            { "text": "还需要发票日期才能判断是否在报销窗口内，请补充。", "mediaType": "text/plain" }
          ]
        },
        "timestamp": "2026-03-01T10:00:01.000Z"
      }
    }
  }
}
```

客户端带 `taskId` 补充：

```json
{
  "jsonrpc": "2.0",
  "id": "req-003",
  "method": "SendMessage",
  "params": {
    "message": {
      "messageId": "msg-9b4g",
      "taskId": "t-1a2b",
      "contextId": "c-9f3e",
      "role": "ROLE_USER",
      "parts": [
        { "text": "2026-02-18", "mediaType": "text/plain" }
      ]
    }
  }
}
```

### 8.3 流式完整帧序列

```
data: {"jsonrpc":"2.0","id":1,"result":{"task":{"id":"t-1a2b","contextId":"c-9f3e","status":{"state":"TASK_STATE_WORKING"}}}}

data: {"jsonrpc":"2.0","id":1,"result":{"statusUpdate":{"taskId":"t-1a2b","contextId":"c-9f3e","status":{"state":"TASK_STATE_WORKING","message":{"role":"ROLE_AGENT","parts":[{"text":"正在识别发票信息…"}]}}}}}

data: {"jsonrpc":"2.0","id":1,"result":{"artifactUpdate":{"taskId":"t-1a2b","contextId":"c-9f3e","artifact":{"artifactId":"a-1","name":"报销结论","parts":[{"text":"正在核对差旅政策…"}]},"append":false,"lastChunk":false}}}

data: {"jsonrpc":"2.0","id":1,"result":{"artifactUpdate":{"taskId":"t-1a2b","contextId":"c-9f3e","artifact":{"artifactId":"a-1","parts":[{"text":"符合差旅政策第 3.2 条，予以通过。"}]},"append":true,"lastChunk":true}}}

data: {"jsonrpc":"2.0","id":1,"result":{"statusUpdate":{"taskId":"t-1a2b","contextId":"c-9f3e","status":{"state":"TASK_STATE_COMPLETED","timestamp":"2026-03-01T10:00:05.000Z"}}}}
```

### 8.4 错误响应

```json
{
  "jsonrpc": "2.0",
  "id": "req-004",
  "error": {
    "code": -32001,
    "message": "Task not found",
    "data": [
      {
        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
        "reason": "TASK_NOT_FOUND",
        "domain": "a2a-protocol.org",
        "metadata": {
          "taskId": "t-nonexistent",
          "timestamp": "2026-03-01T10:00:00.000Z"
        }
      }
    ]
  }
}
```

**字段级校验错误**：

```json
{
  "jsonrpc": "2.0",
  "id": "req-005",
  "error": {
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
}
```

## 九、v0.3 → v1.0 迁移对照

### 9.1 方法名

| v0.3 | v1.0 | 备注 |
| --- | --- | --- |
| `message/send` | `SendMessage` | |
| `message/stream` | `SendStreamingMessage` | |
| `tasks/get` | `GetTask` | |
| `tasks/list` | `ListTasks` | v0.3 只在 gRPC / REST 绑定上存在（gRPC 方法名 `ListTask`），v1.0 补齐 JSON-RPC |
| `tasks/cancel` | `CancelTask` | |
| `tasks/resubscribe` | `SubscribeToTask` | v0.3 的 gRPC 方法名是 `TaskSubscription` |
| `agent/getAuthenticatedExtendedCard` | `GetExtendedAgentCard` | v0.3 的 gRPC 方法名是 `GetAgentCard` |
| `tasks/pushNotificationConfig/set` | `CreateTaskPushNotificationConfig` | v0.3 的 gRPC 方法名是 `CreateTaskPushNotification` |
| `tasks/pushNotificationConfig/get` | `GetTaskPushNotificationConfig` | v0.3 的 gRPC 方法名是 `GetTaskPushNotification` |
| `tasks/pushNotificationConfig/list` | `ListTaskPushNotificationConfigs` | v0.3 的 gRPC 方法名是 `ListTaskPushNotification` |
| `tasks/pushNotificationConfig/delete` | `DeleteTaskPushNotificationConfig` | v0.3 的 gRPC 方法名是 `DeleteTaskPushNotification` |

更早的 v0.1 用的也是斜杠式方法名：`tasks/send`、`tasks/sendSubscribe`、
`tasks/get`。v1.0 之前不存在 `submitTask` / `getTask` / `cancelTask`
这类小驼峰的线上方法名——那只是各家 SDK 客户端方法的名字。

### 9.2 数据结构

| v0.3 | v1.0 |
| --- | --- |
| `part.kind = "text"` + `part.text` | 有 `text` 字段 |
| `part.kind = "file"` + `part.file.fileWithUri` | 有 `url` 字段 |
| `part.kind = "file"` + `part.file.fileWithBytes` | 有 `raw` 字段 |
| `part.kind = "data"` + `part.data` | 有 `data` 字段 |
| `part.file.mimeType` | `part.mediaType` |
| `part.file.name` | `part.filename` |
| `event.kind = "status-update"` | `result.statusUpdate` |
| `event.kind = "artifact-update"` | `result.artifactUpdate` |
| `statusUpdateEvent.final` | 移除，用流的关闭表示结束 |
| `card.protocolVersion` | `supportedInterfaces[].protocolVersion` |
| `card.url` | `supportedInterfaces[0].url` |
| `card.preferredTransport` | 合并进 `supportedInterfaces` |
| `card.additionalInterfaces` | 合并进 `supportedInterfaces` |
| `card.supportsAuthenticatedExtendedCard` | `capabilities.extendedAgentCard` |
| `tasks/{taskId}` 复合 ID | 简单字面量，父子 ID 分字段 |
| `page` / `perPage` 分页 | `pageSize` / `pageToken` 游标分页 |
| `error.data` 是对象 | `error.data` 是数组，每项带 `@type` |
| HTTP `application/problem+json` | HTTP `application/a2a+json` + `google.rpc.Status` |

### 9.3 枚举值

| v0.3 | v1.0 |
| --- | --- |
| `"submitted"` | `"TASK_STATE_SUBMITTED"` |
| `"working"` | `"TASK_STATE_WORKING"` |
| `"input-required"` | `"TASK_STATE_INPUT_REQUIRED"` |
| `"auth-required"` | `"TASK_STATE_AUTH_REQUIRED"` |
| `"completed"` | `"TASK_STATE_COMPLETED"` |
| `"failed"` | `"TASK_STATE_FAILED"` |
| `"canceled"` | `"TASK_STATE_CANCELED"` |
| `"rejected"` | `"TASK_STATE_REJECTED"` |
| `"user"` | `"ROLE_USER"` |
| `"agent"` | `"ROLE_AGENT"` |

### 9.4 错误码对照

| v1.0 JSON-RPC | gRPC | HTTP | 错误类型 |
| --- | --- | --- | --- |
| `-32001` | `NOT_FOUND` | 404 | `TaskNotFoundError` |
| `-32002` | `FAILED_PRECONDITION` | 400 | `TaskNotCancelableError` |
| `-32003` | `FAILED_PRECONDITION` | 400 | `PushNotificationNotSupportedError` |
| `-32004` | `FAILED_PRECONDITION` | 400 | `UnsupportedOperationError` |
| `-32005` | `INVALID_ARGUMENT` | 400 | `ContentTypeNotSupportedError` |
| `-32006` | `INTERNAL` | 500 | `InvalidAgentResponseError` |
| `-32007` | `FAILED_PRECONDITION` | 400 | `ExtendedAgentCardNotConfiguredError` |
| `-32008` | `FAILED_PRECONDITION` | 400 | `ExtensionSupportRequiredError` |
| `-32009` | `FAILED_PRECONDITION` | 400 | `VersionNotSupportedError` |

## 十、HTTP 头与端点速查

| 头 | 说明 |
| --- | --- |
| `A2A-Version` | 协议版本，`Major.Minor` 格式 |
| `A2A-Extensions` | 客户端要用的扩展 URI，逗号分隔 |
| `Content-Type` | JSON-RPC 绑定用 `application/json`；REST 绑定用 `application/a2a+json`；流式用 `text/event-stream` |
| `Authorization` | 凭据，格式由 Agent Card 的 `securitySchemes` 决定 |
| `WWW-Authenticate` | 认证挑战（401 响应时） |
| `Retry-After` | 重试等待秒数（429 / 503 响应时） |
| `ETag` | Agent Card 缓存标识 |
| `Cache-Control` | Agent Card 缓存时长 |
| `X-Accel-Buffering: no` | 关掉 nginx 的响应缓冲，SSE 必需 |

| 端点 | 用途 |
| --- | --- |
| `GET /.well-known/agent-card.json` | 公开 Agent Card |
| `POST /rpc` | JSON-RPC 入口（规范不强制路径，这是常见约定） |
| `POST /rpc/stream` | 本专栏示例用的流式入口（同一端点按 `method` 分派也完全可以） |
| `GET /extendedAgentCard` | 鉴权后的扩展卡片（REST 绑定） |
| `POST /message:send` | REST 绑定：发消息 |
| `POST /message:stream` | REST 绑定：流式发消息 |
| `GET /tasks/{id}` | REST 绑定：取任务 |
| `GET /tasks` | REST 绑定：列任务 |
| `POST /tasks/{id}:cancel` | REST 绑定：取消任务 |
| `POST /tasks/{id}:subscribe` | REST 绑定：订阅任务 |

## 十一、完整示例集合

规范第 6 章"Common Workflows & Examples"里有一组完整示例，
包括：

- 6.1 基础任务执行
- 6.2 流式任务执行
- 6.3 多轮交互
- 6.4 版本协商错误
- 6.5 任务列举与管理（含分页、参数校验错误）
- 6.6 推送通知配置与投递
- 6.7 文件交换（上传与下载）
- 6.8 结构化数据交换
- 6.9 获取鉴权后的扩展卡片

**建议直接读原文**：[规范第 6 章](https://a2a-protocol.org/latest/specification/)。
本附录的数据模型部分可以直接用，示例部分原文更完整。

---

回到[栏目首页](/a2a/)。
