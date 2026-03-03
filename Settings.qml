import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Widgets

ColumnLayout {
  id: root

  property var pluginApi: null

  spacing: Style.marginM

  property string pythonCommandValue: "python3"
  property string socketPathValue: ""
  property bool notifyOnApprovalValue: true
  property bool autoInstallHooksValue: true

  function defaults() {
    return pluginApi?.manifest?.metadata?.defaultSettings || ({
                                                                 "pythonCommand": "python3",
                                                                 "socketPath": "",
                                                                 "notifyOnApproval": true,
                                                                 "autoInstallHooks": true
                                                               });
  }

  function loadFromSettings() {
    var cfg = pluginApi?.pluginSettings || ({});
    var d = defaults();
    root.pythonCommandValue = cfg.pythonCommand ?? d.pythonCommand ?? "python3";
    root.socketPathValue = cfg.socketPath ?? d.socketPath ?? "";
    root.notifyOnApprovalValue = cfg.notifyOnApproval ?? d.notifyOnApproval ?? true;
    root.autoInstallHooksValue = cfg.autoInstallHooks ?? d.autoInstallHooks ?? true;
  }

  function resetToDefaults() {
    var d = defaults();
    root.pythonCommandValue = d.pythonCommand || "python3";
    root.socketPathValue = d.socketPath || "";
    root.notifyOnApprovalValue = d.notifyOnApproval !== undefined ? d.notifyOnApproval : true;
    root.autoInstallHooksValue = d.autoInstallHooks !== undefined ? d.autoInstallHooks : true;
  }

  function saveSettings() {
    if (!pluginApi) {
      return;
    }

    pluginApi.pluginSettings.pythonCommand = root.pythonCommandValue.trim();
    pluginApi.pluginSettings.socketPath = root.socketPathValue.trim();
    pluginApi.pluginSettings.notifyOnApproval = root.notifyOnApprovalValue;
    pluginApi.pluginSettings.autoInstallHooks = root.autoInstallHooksValue;
    pluginApi.saveSettings();
  }

  Component.onCompleted: loadFromSettings()
  onPluginApiChanged: loadFromSettings()

  Connections {
    target: pluginApi
    function onPluginSettingsChanged() {
      root.loadFromSettings();
    }
  }

  NText {
    Layout.fillWidth: true
    text: "AI Monitor 设置"
    pointSize: Style.fontSizeXL
    font.weight: Font.Bold
  }

  NText {
    Layout.fillWidth: true
    text: "监控 Claude Code 会话状态并从 shell 审批权限请求。"
    color: Color.mOnSurfaceVariant
    wrapMode: Text.WordWrap
  }

  NTextInput {
    Layout.fillWidth: true
    label: "Python 命令"
    description: "用于运行 bridge.py，例如 python3"
    text: root.pythonCommandValue
    onTextChanged: root.pythonCommandValue = text
  }

  NTextInput {
    Layout.fillWidth: true
    label: "Socket 路径"
    description: "Unix socket 文件路径，留空则使用 $XDG_RUNTIME_DIR/ai-monitor.sock"
    text: root.socketPathValue
    onTextChanged: root.socketPathValue = text
  }

  NCheckbox {
    Layout.fillWidth: true
    label: "权限请求时通知"
    description: "当 Claude Code 请求权限审批时显示桌面通知"
    checked: root.notifyOnApprovalValue
    onToggled: value => root.notifyOnApprovalValue = value
  }

  NCheckbox {
    Layout.fillWidth: true
    label: "自动安装 Hooks"
    description: "插件启动时自动安装 Claude Code hooks"
    checked: root.autoInstallHooksValue
    onToggled: value => root.autoInstallHooksValue = value
  }

  RowLayout {
    Layout.fillWidth: true
    spacing: Style.marginS

    NButton {
      text: "保存"
      icon: "device-floppy"
      onClicked: root.saveSettings()
    }

    NButton {
      text: "重置"
      outlined: true
      icon: "restore"
      onClicked: root.resetToDefaults()
    }

    Item {
      Layout.fillWidth: true
    }

    NButton {
      text: "重装 Hooks"
      outlined: true
      icon: "refresh"
      onClicked: {
        if (pluginApi?.mainInstance) {
          pluginApi.mainInstance.installHook();
        }
      }
    }
  }
}
