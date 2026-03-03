import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Services.UI

Item {
  id: root

  property var pluginApi: null

  // --- Exposed state ---
  property var sessions: ({})
  property var pendingApprovals: []
  property string globalPhase: "idle"
  property int activeSessionCount: 0
  property bool hasApprovalNeeded: false
  property bool bridgeRunning: bridgeProcess.running


  // --- Crash tracking ---
  property int _crashCount: 0
  property int _maxCrashes: 5

  // --- Helpers ---

  function effectivePython() {
    var value = pluginApi?.pluginSettings?.pythonCommand
                || pluginApi?.manifest?.metadata?.defaultSettings?.pythonCommand
                || "python3";
    return value.length > 0 ? value : "python3";
  }

  function effectiveSocketPath() {
    var value = pluginApi?.pluginSettings?.socketPath
                || pluginApi?.manifest?.metadata?.defaultSettings?.socketPath
                || "";
    if (value.length > 0)
      return value;
    // Default to $XDG_RUNTIME_DIR for security (only current user can access)
    // Fallback matches claude-hook.py: /run/user/<uid>
    var runtimeDir = Quickshell.env("XDG_RUNTIME_DIR");
    if (!runtimeDir)
      runtimeDir = "/run/user/" + (Quickshell.env("UID") || "1000");
    return runtimeDir + "/ai-monitor.sock";
  }

  function buildBridgeCommand() {
    return [effectivePython(), pluginApi.pluginDir + "/bridge.py",
            "serve", "--socket", effectiveSocketPath()];
  }

  function buildCommand(args) {
    var command = [effectivePython(), pluginApi.pluginDir + "/bridge.py"];
    for (var i = 0; i < args.length; i++) {
      command.push(args[i]);
    }
    return command;
  }

  // --- State computation ---

  function computeGlobalPhase() {
    var hasApproval = false;
    var hasProcessing = false;
    var hasCompacting = false;
    var hasWaiting = false;
    var count = 0;

    var ids = Object.keys(root.sessions);
    for (var i = 0; i < ids.length; i++) {
      var s = root.sessions[ids[i]];
      if (s.phase === "ended")
        continue;
      count++;
      if (s.phase === "waiting_for_approval")
        hasApproval = true;
      else if (s.phase === "processing")
        hasProcessing = true;
      else if (s.phase === "compacting")
        hasCompacting = true;
      else if (s.phase === "waiting_for_input")
        hasWaiting = true;
    }

    root.activeSessionCount = count;
    root.hasApprovalNeeded = hasApproval;

    if (hasApproval) root.globalPhase = "waiting_for_approval";
    else if (hasProcessing) root.globalPhase = "processing";
    else if (hasCompacting) root.globalPhase = "compacting";
    else if (hasWaiting) root.globalPhase = "waiting_for_input";
    else root.globalPhase = "idle";
  }

  function handleStateUpdate(data) {
    try {
      var obj = JSON.parse(data);
    } catch (e) {
      return;
    }

    if (obj.type === "state_update") {
      root.sessions = obj.sessions || {};
      root.pendingApprovals = obj.pending_approvals || [];
      computeGlobalPhase();
    }
  }

  // Notify when approval is newly needed
  onHasApprovalNeededChanged: {
    if (root.hasApprovalNeeded
        && pluginApi?.pluginSettings?.notifyOnApproval !== false) {
      var ids = Object.keys(root.sessions);
      var msg = "需要你的审批";
      for (var i = 0; i < ids.length; i++) {
        var s = root.sessions[ids[i]];
        if (s.phase === "waiting_for_approval" && s.tool) {
          var proj = (s.cwd || "").split("/").pop() || "";
          msg = "权限审批: " + s.tool + (proj ? " — " + proj : "");
          break;
        }
      }
      ToastService.showWarning(msg, "", 8000);
    }
  }

  // --- Public methods ---

  function approvePermission(sessionId, toolUseId) {
    if (!pluginApi) return;
    if (commandProcess.running) {
      ToastService.showWarning("操作进行中，请稍候");
      return;
    }

    commandProcess.command = buildCommand([
      "approve", "--socket", effectiveSocketPath(),
      "--session", sessionId, "--tool-use-id", toolUseId
    ]);
    commandProcess.running = true;
  }

  function denyPermission(sessionId, toolUseId, reason) {
    if (!pluginApi) return;
    if (commandProcess.running) {
      ToastService.showWarning("操作进行中，请稍候");
      return;
    }

    var args = ["deny", "--socket", effectiveSocketPath(),
                "--session", sessionId, "--tool-use-id", toolUseId];
    if (reason && reason.length > 0) {
      args.push("--reason", reason);
    }
    commandProcess.command = buildCommand(args);
    commandProcess.running = true;
  }

  function installHook() {
    if (!pluginApi) return;
    if (commandProcess.running) return;

    commandProcess.command = buildCommand([
      "install-hook", "--plugin-dir", pluginApi.pluginDir
    ]);
    commandProcess.running = true;
  }

  function refreshStatus() {
    if (!pluginApi) return;
    if (commandProcess.running) return;

    commandProcess.command = buildCommand([
      "status", "--socket", effectiveSocketPath()
    ]);
    commandProcess.running = true;
  }

  function focusTerminal(sessionId) {
    if (!pluginApi) return;
    if (commandProcess.running) {
      ToastService.showWarning("操作进行中，请稍候");
      return;
    }

    var session = root.sessions[sessionId];
    if (!session || !session.pid)
      return;

    var args = ["focus-terminal", "--pid", String(session.pid)];
    if (session.tty)
      args.push("--tty", session.tty);
    if (session.cwd)
      args.push("--cwd", session.cwd);

    commandProcess.command = buildCommand(args);
    commandProcess.running = true;
  }

  // --- Lifecycle ---

  function startBridge() {
    if (!pluginApi || bridgeProcess.running)
      return;
    bridgeProcess.command = buildBridgeCommand();
    bridgeProcess.running = true;
  }

  function stopBridge() {
    if (bridgeProcess.running)
      bridgeProcess.running = false;
  }

  Component.onCompleted: {
    if (pluginApi) {
      startBridge();
      if (pluginApi.pluginSettings?.autoInstallHooks)
        installHook();
    }
  }

  onPluginApiChanged: {
    if (pluginApi) {
      startBridge();
      if (pluginApi.pluginSettings?.autoInstallHooks)
        installHook();
    }
  }

  Component.onDestruction: {
    stopBridge();
  }

  // --- IPC ---

  IpcHandler {
    target: "plugin:ai-monitor"

    function togglePanel(screen, anchor) {
      pluginApi?.openPanel(screen, anchor);
    }

    function approve(sessionId, toolUseId) {
      root.approvePermission(sessionId, toolUseId);
    }

    function deny(sessionId, toolUseId, reason) {
      root.denyPermission(sessionId, toolUseId, reason || "");
    }
  }

  // --- Restart timer (exponential backoff: 2s, 4s, 8s, ... up to 60s) ---

  Timer {
    id: restartTimer
    interval: 2000
    repeat: false
    onTriggered: {
      if (!bridgeProcess.running) {
        root.startBridge();
      }
    }
  }

  // Reset crash count only after bridge has been stable for 10s
  Timer {
    id: crashResetTimer
    interval: 10000
    repeat: false
    onTriggered: root._crashCount = 0
  }

  // --- Bridge process (long-running) ---

  Process {
    id: bridgeProcess
    running: false

    onStarted: {
      // Delay crash count reset — only reset if bridge stays up for 10s
      crashResetTimer.restart();
    }

    onExited: function(exitCode) {
      root.sessions = ({});
      root.pendingApprovals = [];
      root.computeGlobalPhase();

      crashResetTimer.stop();
      if (root.pluginApi) {
        root._crashCount++;
        if (root._crashCount <= root._maxCrashes) {
          // Exponential backoff: 2s, 4s, 8s, 16s, 32s (capped at 60s)
          restartTimer.interval = Math.min(2000 * Math.pow(2, root._crashCount - 1), 60000);
          restartTimer.start();
        }
      }
    }

    stdout: SplitParser {
      onRead: data => root.handleStateUpdate(data)
    }

    stderr: StdioCollector {
      onStreamFinished: {
        if (text.trim()) {
          Logger.w("AiMonitor", "bridge stderr:", text.trim());
        }
      }
    }
  }

  // --- Command process (short-lived) ---

  Process {
    id: commandProcess
    running: false

    stdout: StdioCollector {
      id: cmdStdout
    }

    stderr: StdioCollector {
      id: cmdStderr
    }

    onExited: function(exitCode) {
      var stdoutText = (cmdStdout.text || "").trim();
      var stderrText = (cmdStderr.text || "").trim();

      if (exitCode !== 0) {
        var msg = "命令执行失败";
        if (stdoutText.length > 0) {
          try {
            var payload = JSON.parse(stdoutText);
            if (payload.error)
              msg = payload.error;
          } catch (e) {}
        } else if (stderrText.length > 0) {
          msg = stderrText;
        }
        ToastService.showError(msg);
      } else if (stdoutText.length > 0) {
        try {
          var result = JSON.parse(stdoutText);
          if (result.hook_installed) {
            ToastService.showNotice("Hooks 已安装");
          }
          // Handle status command response — update sessions from bridge
          if (result.sessions) {
            root.sessions = result.sessions;
            root.pendingApprovals = result.pending_approvals || [];
            root.computeGlobalPhase();
          }
        } catch (e) {
          Logger.w("AiMonitor", "Failed to parse command output:", stdoutText);
        }
      }
    }
  }
}
