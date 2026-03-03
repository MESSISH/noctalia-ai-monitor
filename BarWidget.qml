import QtQuick
import Quickshell
import qs.Commons
import qs.Services.UI
import qs.Widgets

NIconButton {
  id: root

  property var pluginApi: null
  property ShellScreen screen
  property string widgetId: ""
  property string section: ""

  readonly property var mainInstance: pluginApi?.mainInstance
  readonly property string globalPhase: mainInstance?.globalPhase || "idle"
  readonly property bool hasApproval: mainInstance?.hasApprovalNeeded || false
  readonly property int sessionCount: mainInstance?.activeSessionCount || 0

  baseSize: Style.getCapsuleHeightForScreen(screen?.name)
  applyUiScale: false
  icon: {
    if (hasApproval)
      return "alert-triangle";
    if (globalPhase === "processing" || globalPhase === "compacting")
      return "brain";
    if (globalPhase === "waiting_for_input")
      return "message-circle";
    return "brain";
  }
  tooltipText: {
    if (!mainInstance)
      return "AI Monitor";
    if (hasApproval)
      return "AI Monitor - 需要审批";
    if (sessionCount > 0)
      return "AI Monitor - " + sessionCount + " 个活跃会话";
    return "AI Monitor";
  }
  tooltipDirection: BarService.getTooltipDirection(screen?.name)
  customRadius: Style.radiusL

  colorBg: hasApproval ? Qt.alpha("#f59e0b", 0.25) : Style.capsuleColor
  colorFg: {
    if (hasApproval)
      return "#f59e0b";
    if (globalPhase === "processing" || globalPhase === "compacting")
      return "#06b6d4";
    return Color.mOnSurface;
  }
  colorBgHover: hasApproval ? Qt.alpha("#f59e0b", 0.35) : Color.mHover
  colorFgHover: {
    if (hasApproval)
      return "#fbbf24";
    if (globalPhase === "processing" || globalPhase === "compacting")
      return "#22d3ee";
    return Color.mOnHover;
  }
  colorBorder: hasApproval ? Qt.alpha("#f59e0b", 0.5) : Style.capsuleBorderColor
  colorBorderHover: hasApproval ? Qt.alpha("#f59e0b", 0.6) : Style.capsuleBorderColor
  border.width: Style.capsuleBorderWidth

  onClicked: {
    if (pluginApi) {
      pluginApi.openPanel(screen, root);
    }
  }

  onRightClicked: {
    PanelService.showContextMenu(contextMenu, root, screen);
  }

  // Pulse animation when approval needed
  SequentialAnimation on opacity {
    running: root.hasApproval
    loops: Animation.Infinite
    NumberAnimation {
      to: 0.5
      duration: 800
      easing.type: Easing.InOutSine
    }
    NumberAnimation {
      to: 1.0
      duration: 800
      easing.type: Easing.InOutSine
    }
    onRunningChanged: {
      if (!running)
        root.opacity = 1.0;
    }
  }

  NPopupContextMenu {
    id: contextMenu

    model: [{
        "label": "打开 AI Monitor",
        "action": "open-panel",
        "icon": "layout-dashboard"
      }, {
        "label": "安装 Hooks",
        "action": "install-hook",
        "icon": "download"
      }, {
        "label": "插件设置",
        "action": "plugin-settings",
        "icon": "settings"
      }]

    onTriggered: action => {
      contextMenu.close();
      PanelService.closeContextMenu(screen);

      if (action === "open-panel") {
        pluginApi?.openPanel(screen, root);
      } else if (action === "install-hook") {
        mainInstance?.installHook();
      } else if (action === "plugin-settings") {
        if (pluginApi && pluginApi.manifest) {
          BarService.openPluginSettings(screen, pluginApi.manifest);
        }
      }
    }
  }
}
