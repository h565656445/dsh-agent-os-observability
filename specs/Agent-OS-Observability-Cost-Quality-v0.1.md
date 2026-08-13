---
type: specification
status: active
created: 2026-07-18
updated: 2026-07-18
---

# Agent OS 可观测性、成本与质量门禁 v0.1

## 结论

AOS-004 提供一个独立、可恢复的观测运行时。调用方先用不可变合同声明被观测对象、阶段依赖、统一预算和质量门，再通过唯一 Runner 记录阶段开始与阶段结果。所有可接受事件进入哈希链 Ledger；预算超限、质量不合格、证据漂移或 Ledger 损坏都必须 fail closed。

本阶段不修改 AOS-001、AOS-002、AOS-003 的既有事实源，也不自动给模型、发布或不可逆动作授权。AOS-006 才负责把五个业务项目接入这一接口。

## 公开接口与测试 seam

唯一入口：`runner/agent_os_observability.ps1`。

```text
Initialize -> StartStage -> FinishStage -> Evaluate -> passed
                    |              |
                    |              +-> blocked_budget / blocked_quality / failed
                    +-----------------> blocked_budget

Inspect / Recover 可在任意非损坏状态读取或重建 Snapshot。
```

- `Initialize`：校验观测规格，绑定被观测对象的不可变合同 SHA-256，生成观测合同、Ledger 和 Snapshot。
- `StartStage`：校验依赖和预算预留；只有不会突破任一预算维度时才记录 `stage_started`。
- `FinishStage`：记录实际耗时、模型调用、Token、成本、质量测量、失败原因和证据哈希；实际超预算或质量门失败立即进入阻断终态。
- `Evaluate`：从 Ledger 重新计算全部指标、质量门和证据哈希；所有声明阶段均成功后才写入 `evaluation_passed`。
- `Inspect`：只返回最后可信 Ledger 前缀的状态，不信任 Snapshot 声明。
- `Recover`：Ledger 完整时可重建丢失或陈旧 Snapshot；Ledger 损坏时只暴露可信前缀且不写回。

测试只通过这个公开 seam 验证行为，不调用模块内部函数。

被观测对象不是任意 JSON。`subject.kind` 决定必须通过的合同 Schema 和 ID 字段：`agent_os_task -> agent_os_runtime_task.schema.json/task_id`、`worker_job -> agent_os_worker_input.schema.json/job_id`、`graph -> agent_os_graph_contract.schema.json/graph_id`、`project_task -> task_contract.schema.json/task_id`。Schema、声明 ID 和文件 SHA-256 任一不一致都在创建运行态前拒绝。

## 统一指标

每个阶段使用五个非负整数维度：

- `duration_ms`
- `model_calls`
- `input_tokens`
- `output_tokens`
- `cost_microunits`

`cost_microunits` 是合同货币的百万分之一，避免浮点累计误差。单个观测合同只允许一种 ISO 三字母货币，不负责汇率换算。成本大于零时必须提供受合同根目录约束的成本依据及 SHA-256。

## 质量门

每个阶段可声明零个或多个质量门：`gate_id + metric + unit + operator + threshold`。v0.1 只支持整数的 `gte`、`lte`、`eq`。阶段结果必须逐一提交且不得额外提交未声明的门；要求证据的门至少绑定一份可复算文件。

缺少测量、指标或单位漂移、证据越界/变更、阈值不合格都不得降级为警告，必须阻断。

## 不变量

- 观测规格、观测合同、阶段请求和阶段结果均使用严格 JSON Schema，拒绝未声明字段。
- 观测合同、被观测合同、事件源文件和证据均绑定 SHA-256；JSON 的解析、Schema 校验与哈希必须来自同一次受限读取的字节，不能重新打开文件制造校验/记录窗口。
- 每个阶段只可开始一次、结束一次；依赖未成功时不可开始。
- 当前实际用量与所有运行中阶段的预算预留共同参与 StartStage 预算判断。
- 阶段实际耗时必须等于 `finished_at - started_at` 的毫秒数。
- 预算或质量阻断、显式失败和 `passed` 都是终态，不能继续写业务阶段事件。
- Ledger 是恢复事实源；每个事件的结构、哈希和状态迁移语义都在同一保护边界内校验，坏事件只截断为最后可信前缀且不能让 Inspect/Recover 抛出未受控类型转换错误；Snapshot 只可由可信 Ledger 重建。
- RuntimeRoot、观测目录、被观测合同和证据根不得通过联接点或重解析点逃逸。
- 输入中发现疑似密码、令牌、Cookie 或 API Key 时，在写盘前拒绝。
- AOS-004 实现完成后必须停在 `waiting_for_approval`；没有用户明确验收不得进入 `completed`，也不得启动 AOS-005。

## 验收映射

| 路线图验收 | v0.1 证据 |
|---|---|
| 每个阶段都有可核验事件 | 每阶段必须有哈希绑定的 `stage_started` 与一个终态事件；Evaluate 从 Ledger 重放验证 |
| 超预算时 fail closed | StartStage 对预留做前置阻断；FinishStage 对实际累计做终态阻断 |
| 质量不合格时 fail closed | FinishStage 对声明门逐项复算，不合格进入 `blocked_quality` |

返回：[[10-项目/Hermes-Harness/README|Hermes Harness]]。
