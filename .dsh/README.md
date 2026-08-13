# DeepSeek Harness 衍生包 / DSH Derivative Package

本目录包含本项目作为 **DeepSeek Harness 额外补充衍生插件** 的组装文件。

This directory contains the assembly files that make this project an **extra supplementary derivative plugin** for DeepSeek Harness.

## 结构 / Structure

```
.dsh/
├── preset.yml          # Agent 预设元数据
├── agent.cordis.yml    # Cordis 组装（基于 standard，persona 已定制）
└── skills/
    └── dsh-agent-os-observability/
        └── SKILL.md    # 项目专属技能
```

## 安装 / Installation

### 方式一：作为用户预设（preset）

将 `.dsh` 目录复制到 `$DSH_HOME/.agent-presets/agent-os-observability/`：

```powershell
# Windows PowerShell 7
$dst = Join-Path $env:DSH_HOME ".agent-presets\agent-os-observability"
Copy-Item -Recurse -Force ".\dsh" $dst
```

重启 DeepSeek Harness 后，在会话预设列表选择 `Agent OS 可观测性`。

### 方式二：仅安装技能（skill）

将 SKILL.md 复制到 `$DSH_HOME/skills/dsh-agent-os-observability/`：

```powershell
$dst = Join-Path $env:DSH_HOME "skills\dsh-agent-os-observability"
New-Item -ItemType Directory -Force -Path $dst | Out-Null
Copy-Item ".\skills\dsh-agent-os-observability\SKILL.md" $dst -Force
```

## 作者 / Author

[h565656445](https://github.com/h565656445)

如有项目可以一起合作，欢迎联系。微信：`wohaishihenshuaide`。
If you have projects, let's collaborate. WeChat: `wohaishihenshuaide`.