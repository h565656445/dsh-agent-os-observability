# dsh-agent-os-observability

<!-- DeepSeek Harness 衍生声明 -->
> **DeepSeek Harness 个人适配声明（Personal Adaptation Notice）**
>
> 本项目是 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 的**个人适配产物（personal adaptation）**，**并非 DeepSeek Harness 官方文件（not an official DeepSeek Harness file）**。随附功能、使用说明与个人产物，可与 DeepSeek Harness 搭配使用，也可独立使用。
>
> This project is a **personal adaptation** for DeepSeek Harness, and is **NOT an official DeepSeek Harness file**. It is bundled with features, documentation, and personal artifacts, and can be used alongside DeepSeek Harness or standalone.

**作者 / Author**: [h565656445](https://github.com/h565656445)

**合作 / Collaboration**: 如有项目可以一起合作，欢迎联系。微信：`wohaishihenshuaide`。If you have projects, let's collaborate. WeChat: `wohaishihenshuaide`.


---

## 用途 / What this is for

Agent OS 可观测性、成本与质量门禁模块：统一观测账本、阶段预留、Token/微单位成本与质量阈值，不合格立即失败关闭。

Agent OS observability, cost & quality-gate module: unified observation ledger, stage reserves, token/micro-unit cost and quality thresholds that fail closed.

---
## Agent OS Observability, Cost & Quality v0.1 / Agent OS 可观测性、成本与质量门禁 v0.1

Agent OS 可观测性、成本与质量门禁（AOS-004）提供一个独立、可恢复的观测运行时。调用方先用不可变合同声明被观测对象、阶段依赖、统一预算和质量门，再通过唯一 Runner 记录阶段开始与阶段结果。所有可接受事件进入哈希链 Ledger；预算超限、质量不合格、证据漂移或 Ledger 损坏都必须 fail closed。

The Agent OS Observability, Cost & Quality Gate (AOS-004) provides an independent, recoverable observation runtime. Callers declare the observed subject, stage dependencies, unified budget, and quality gates in an immutable contract, then record stage starts and stage results through the single Runner. All accepted events enter a hash-chained Ledger; budget overruns, quality failures, evidence drift, or Ledger corruption must fail closed.

## Features / 功能

- **统一观测运行时**：`Initialize → StartStage → FinishStage → Evaluate`，唯一入口 `runner/agent_os_observability.ps1`。
- **五维统一指标**：`duration_ms` / `model_calls` / `input_tokens` / `output_tokens` / `cost_microunits`，整数非负，避免浮点累计误差。
- **预算前置阻断**：`StartStage` 预留、`FinishStage` 累计，任一维度超限立即进入阻断终态。
- **质量门复算**：声明 `gte`/`lte`/`eq` 整数门，缺测量、漂移或不合格一律阻断，不降级为警告。
- **严格 Schema 与哈希绑定**：拒绝未声明字段；解析、Schema 校验与哈希来自同一次受限读取的字节。
- **可恢复快照**：`Inspect` 只返回最后可信 Ledger 前缀；`Recover` 仅在 Ledger 完整时重建 Snapshot。

- **Unified observation runtime**: `Initialize → StartStage → FinishStage → Evaluate` through the single Runner.
- **Five unified metric dimensions**: `duration_ms` / `model_calls` / `input_tokens` / `output_tokens` / `cost_microunits` — non-negative integers, no float drift.
- **Fail-closed budget**: `StartStage` reserves, `FinishStage` sums; any dimension overrun blocks immediately.
- **Quality gate recomputation**: declared `gte`/`lte`/`eq` integer gates; missing measurements, drift, or failure block — never downgraded to warnings.
- **Strict schemas & hash binding**: unknown fields rejected; parsing, validation, and hashing use bytes from one restricted read.
- **Recoverable snapshots**: `Inspect` returns only the last trusted Ledger prefix; `Recover` rebuilds Snapshots only when the Ledger is intact.

## What's inside / 目录结构

```text
dsh-agent-os-observability/
├── README.md                      # 双语说明（本文件）
├── LICENSE                        # MIT
├── src/AgentOSObservability.psm1  # 观测运行时模块（预算、质量门、Ledger）
├── runner/agent_os_observability.ps1 # 唯一公开入口（Initialize/StartStage/FinishStage/Evaluate/Inspect/Recover）
├── schemas/                       # 观测合同/规格/阶段请求/阶段结果 Schema（4 个）
├── specs/Agent-OS-Observability-Cost-Quality-v0.1.md # AOS-004 规格
├── tests/AgentOSObservability.Tests.ps1              # Pester 5 测试
└── .dsh/                          # DeepSeek Harness 衍生包
```

## Quick start / 快速开始

```powershell
# Initialize：校验观测规格，生成观测合同、Ledger 与 Snapshot
pwsh -File .\runner\agent_os_observability.ps1 -Action Initialize `
  -ObservationSpecPath ".\spec.json" -RuntimeRoot ".\runtime\agent_os_observations" -AsJson

# StartStage：校验依赖与预算预留
pwsh -File .\runner\agent_os_observability.ps1 -Action StartStage `
  -ObservationPath "<obs_path>" -StageRequestPath ".\start.json" -AsJson

# FinishStage：记录实际用量、质量测量与证据哈希
pwsh -File .\runner\agent_os_observability.ps1 -Action FinishStage `
  -ObservationPath "<obs_path>" -StageResultPath ".\result.json" -AsJson

# Evaluate：从 Ledger 重算全部指标与质量门
pwsh -File .\runner\agent_os_observability.ps1 -Action Evaluate -ObservationPath "<obs_path>" -AsJson

# 运行测试（Pester 5）
Invoke-Pester .\tests\AgentOSObservability.Tests.ps1
```

## DeepSeek Harness 衍生 / DSH Derivative

本项目附带 DeepSeek Harness 衍生包，位于 `.dsh/` 目录：

- `preset.yml` — Agent 预设元数据
- `agent.cordis.yml` — Cordis 组装（基于 standard 预设，persona 已定制）
- `skills/dsh-agent-os-observability/SKILL.md` — 项目专属技能（skill）

安装与接入方式见 [`.dsh/README.md`](.dsh/README.md)（双语）。

## License / 许可证

[MIT](LICENSE)