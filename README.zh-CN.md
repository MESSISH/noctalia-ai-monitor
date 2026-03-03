# noctalia-ai-monitor

[English](README.md) | **中文**

一个 [noctalia-shell](https://github.com/noctalia) 桌面插件，用于实时监控 Claude Code 会话状态，并直接从桌面 Shell 审批权限请求，无需切换到终端。

## 截图

<!-- TODO: 添加截图 -->

## 功能特性

### 会话监控
- 实时追踪所有活跃的 Claude Code 会话及其当前阶段（空闲、处理中、等待输入、上下文压缩、等待审批、已结束）
- 在面板中显示 Claude 最新回复的预览（Markdown 渲染）
- 自动过滤已结束的会话，保持列表简洁

### 权限审批
- 从 Shell 面板直接批准或拒绝 Claude Code 的工具使用权限请求
- 人类可读的工具调用预览：Bash 命令、文件路径、编辑差异、搜索查询等
- 审批到来时弹出桌面通知（Toast），操作进行中有进度提示

### 状态栏组件
- 系统栏中的紧凑状态按钮，图标随状态变化：
  - 🧠 空闲/处理中（默认色）
  - ⚡ 处理中（青色）
  - ⚠️ 等待审批（琥珀色 + 脉冲动画）
  - 💬 等待输入（绿色）
- 悬停时显示详细 Tooltip
- 右键菜单支持快捷操作

### 终端跳转
- 点击"跳转终端"直接聚焦对应 Claude Code 会话的终端窗口
- 支持多终端窗口消歧（通过 PTY 标题标记技术，适用于 kitty 等多窗口共享 PID 的终端）
- 仅支持 Linux + niri 合成器环境

### 自动化
- Bridge 进程崩溃后自动重启，采用指数退避策略（2s → 4s → 8s → ... → 60s，最多 5 次）
- 稳定运行 10 秒后重置崩溃计数
- 插件启动时自动安装 Claude Code Hooks

## 系统要求

- [noctalia-shell](https://github.com/noctalia) >= 3.7.0
- Python 3.10+
- Claude Code（需支持 Hooks 功能）
- Linux（终端跳转功能需要 niri 合成器）

## 安装

### 1. 获取插件

```bash
git clone https://github.com/MESSISH/noctalia-ai-monitor.git
```

### 2. 安装到 noctalia-shell

**方式一：复制（推荐生产使用）**

```bash
cp -r noctalia-ai-monitor ~/.config/quickshell/noctalia-shell/plugins/ai-monitor
```

**方式二：符号链接（推荐开发使用）**

```bash
ln -s $(pwd)/noctalia-ai-monitor ~/.config/quickshell/noctalia-shell/plugins/ai-monitor
```

### 3. 启用插件

打开 noctalia-shell 设置 → **插件** → 启用 **AI Monitor**。

### 4. 安装 Claude Code Hooks

如果在设置中启用了"自动安装 Hooks"（默认启用），插件启动时会自动安装。也可以手动安装：

- 右键状态栏图标 → **安装 Hooks**
- 或在插件设置面板中点击 **重装 Hooks**

Hook 文件会被复制到 `~/.claude/hooks/ai-monitor-hook.py`，并在 `~/.claude/settings.json` 中注册以下事件：

| 事件 | 超时时间 | 说明 |
|------|---------|------|
| SessionStart | 5s | 会话启动 |
| UserPromptSubmit | 5s | 用户提交提示 |
| PreToolUse | 5s | 工具调用前 |
| PostToolUse | 5s | 工具调用后 |
| PermissionRequest | 300s | 权限请求（需要等待用户审批） |
| Notification | 5s | 通知事件 |
| Stop | 5s | Claude 停止响应 |
| SubagentStop | 5s | 子代理停止 |
| PreCompact | 5s | 上下文压缩前 |
| SessionEnd | 5s | 会话结束 |

## 配置

在状态栏图标右键菜单中选择 **插件设置**，或在面板头部点击齿轮图标。

| 设置项 | 默认值 | 说明 |
|--------|--------|------|
| Python 命令 | `python3` | 用于运行 `bridge.py` 的 Python 可执行文件 |
| Socket 路径 | _(留空)_ | Unix socket 文件路径。留空则使用 `$XDG_RUNTIME_DIR/ai-monitor.sock` |
| 权限请求时通知 | 启用 | 权限请求到来时是否显示桌面 Toast 通知 |
| 自动安装 Hooks | 启用 | 插件启动时是否自动安装 Claude Code Hooks |

## 使用方法

### 基本流程

1. **启动 Claude Code** — 在任意终端中启动 Claude Code。状态栏图标会自动更新以反映会话状态。
2. **权限请求** — 当 Claude Code 需要执行工具调用（如运行 Bash 命令）并请求权限时，状态栏图标变为琥珀色并脉冲闪烁，同时弹出通知。
3. **审批操作** — 点击状态栏图标打开面板，选择需要审批的会话，查看工具调用详情，点击 **批准** 或 **拒绝**。
4. **查看回复** — 在面板中选择非审批状态的会话，可以查看 Claude 的最新回复内容（Markdown 渲染）。
5. **终端跳转** — 点击 **跳转终端** 按钮，直接聚焦到对应的终端窗口。

### IPC 接口

其他 Shell 组件可以通过 IPC 控制插件：

```qml
// 切换面板
IpcHandler.call("plugin:ai-monitor", "togglePanel", [screen, anchor])

// 批准权限
IpcHandler.call("plugin:ai-monitor", "approve", [sessionId, toolUseId])

// 拒绝权限
IpcHandler.call("plugin:ai-monitor", "deny", [sessionId, toolUseId, reason])
```

## 架构

```
Claude Code 进程
    │  Hook 事件 (stdin/stdout JSON)
    ▼
claude-hook.py            ← 安装到 ~/.claude/hooks/
    │  Unix socket (JSON)
    ▼
bridge.py serve           ← 长驻进程，由 Main.qml 管理
    │  JSONL state_update (stdout)
    ▼
Main.qml                  ← 插件核心：解析状态，暴露给 UI
    ├── BarWidget.qml     ← 系统栏按钮
    ├── Panel.qml         ← 会话列表 + 审批详情
    └── Settings.qml      ← 配置界面
```

### Bridge 架构

`bridge.py` 作为持久化的 asyncio 服务器运行，管理两个 Unix socket：

| Socket | 用途 |
|--------|------|
| `ai-monitor.sock` | 接收来自 Claude Code Hook 的事件 |
| `ai-monitor.sock.ctl` | 接收来自 Shell 的控制命令（approve/deny/status） |

**关键机制：**

- **PermissionRequest 事件**：Hook 连接保持打开，直到用户批准或拒绝。Bridge 将 writer 对象存储在 `pending_approvals` 字典中。
- **其他事件**：接收后立即关闭连接，更新会话状态，通过 stdout 输出 JSONL 快照。
- **自动清理**：已结束的会话在 5 分钟后从内存移除；超时的待审批请求在 5 分钟后自动拒绝。
- **状态快照**：每次事件触发后，输出包含所有会话的完整 JSON 快照到 stdout，由 QML 的 `SplitParser` 逐行解析。

### 文件说明

| 文件 | 说明 |
|------|------|
| `manifest.json` | 插件元数据：ID、版本、入口点、默认设置 |
| `bridge.py` | Python asyncio socket 服务器 + CLI 子命令 |
| `claude-hook.py` | Claude Code Hook 脚本，转发事件到 bridge |
| `Main.qml` | 插件入口：bridge 生命周期管理、状态维护、IPC |
| `BarWidget.qml` | 状态栏图标组件：相位感知图标、颜色、动画 |
| `Panel.qml` | 面板：会话列表、审批详情、Markdown 渲染 |
| `Settings.qml` | 配置界面 |

## 安全性

- **Socket 权限**：两个 socket 文件创建后立即设置为 `0600`（仅所有者可读写）
- **Symlink 防护**：启动时检查 socket 路径是否为符号链接，拒绝在符号链接上创建 socket
- **安全路径**：默认使用 `$XDG_RUNTIME_DIR`（`/run/user/<uid>/`），该目录仅当前用户可访问
- **数据截断**：工具输入超过 2000 字符时自动截断，防止 JSONL 输出过大
- **超时保护**：所有连接读取都有超时限制（Hook/Ctl 连接 30s，权限请求 300s）
- **原子写入**：`settings.json` 更新使用临时文件 + 重命名，防止写入中断导致文件损坏
- **响应大小限制**：Hook 端接收 bridge 响应时有 64KB 上限保护

## 开发

### 手动运行 Bridge

```bash
# 启动 bridge 服务器（用于测试）
python3 bridge.py serve --socket /run/user/$(id -u)/test-ai-monitor.sock

# 查询当前状态
python3 bridge.py status --socket /run/user/$(id -u)/test-ai-monitor.sock

# 批准一个待审批请求
python3 bridge.py approve --socket /run/user/$(id -u)/test-ai-monitor.sock \
  --session <session_id> --tool-use-id <tool_use_id>

# 拒绝一个待审批请求
python3 bridge.py deny --socket /run/user/$(id -u)/test-ai-monitor.sock \
  --session <session_id> --tool-use-id <tool_use_id> --reason "理由"

# 安装 Hook（指定插件目录）
python3 bridge.py install-hook --plugin-dir .

# 聚焦终端窗口
python3 bridge.py focus-terminal --pid <pid> --tty /dev/pts/N --cwd /path/to/project
```

所有子命令通过 stdout 输出单行 JSON 结果：

```json
{"ok": true, "...": "..."}
{"ok": false, "error": "错误描述", "detail": "详细信息"}
```

### 添加新的 Hook 事件

1. 在 `bridge.py` 的 `HOOK_EVENTS` 列表和 `_EVENT_HANDLERS` 字典中添加事件名
2. 在 `BridgeServer` 类中实现 `_on_<event_name>` 异步方法
3. 如果需要额外字段，在 `claude-hook.py` 中处理

### 项目结构

```
ai-monitor/
├── manifest.json          # 插件清单
├── Main.qml               # 插件入口
├── BarWidget.qml           # 状态栏组件
├── Panel.qml               # 面板 UI
├── Settings.qml            # 设置界面
├── bridge.py               # Python 后端服务
├── claude-hook.py          # Claude Code Hook
├── README.md               # 英文说明
└── README.zh-CN.md         # 中文说明
```

## 许可证

MIT — 详见 [LICENSE](LICENSE)。
