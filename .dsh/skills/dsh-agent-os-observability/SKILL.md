---
name: dsh-agent-os-observability
description: 面向 Agent OS 可观测性、成本与质量门禁（AOS-004）的专家技能：阶段预算、质量门与哈希链 Ledger / Expert skill for the Agent OS Observability, Cost & Quality (AOS-004): stage budgets, quality gates, and hash-chained ledger
---

# Agent OS 可观测性、成本与质量门禁 / Agent OS Observability, Cost & Quality

本技能指导在 Agent OS 可观测性、成本与质量门禁中工作：声明被观测对象与阶段，预留并核算五维预算，复算质量门，并核验哈希链 Ledger。超预算、质量不合格或证据漂移一律 fail closed。

This skill guides work in the Agent OS Observability, Cost & Quality Gate: declaring observed subjects and stages, reserving and settling five-dimensional budgets, recomputing quality gates, and verifying the hash-chained Ledger. Budget overruns, quality failures, or evidence drift always fail closed.

## When to use / 何时使用

需要初始化观测、开始/结束阶段、评估质量门，或检查/恢复观测 Ledger 与 Snapshot 时。

Use when initializing an observation, starting/finishing stages, evaluating quality gates, or inspecting/recovering the observation Ledger and Snapshot.

## Workflow / 工作流

1. 阅读 `specs/Agent-OS-Observability-Cost-Quality-v0.1.md`，确认不变量与质量门语义。
2. 准备观测规格 JSON（`agent_os_observability_spec.schema.json`），执行 `Initialize`。
3. 依次执行 `StartStage` → `FinishStage`，最后 `Evaluate` 判定 `passed`。
4. 用 `Inspect` / `Recover` 检查或重建状态。
5. 用 `tests/AgentOSObservability.Tests.ps1` 回归验证。

1. Read `specs/Agent-OS-Observability-Cost-Quality-v0.1.md` to confirm invariants and quality-gate semantics.
2. Prepare an observation-spec JSON (`agent_os_observability_spec.schema.json`) and run `Initialize`.
3. Run `StartStage` → `FinishStage`, then `Evaluate` to decide `passed`.
4. Use `Inspect` / `Recover` to check or rebuild state.
5. Regress with `tests/AgentOSObservability.Tests.ps1`.

## References / 参考

- 项目 README: 见仓库根目录
- 作者: h565656445 (GitHub)