import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import qs.Commons
import qs.Services.UI
import qs.Widgets

Item {
  id: root

  property var pluginApi: null
  readonly property var mainInstance: pluginApi?.mainInstance

  readonly property var geometryPlaceholder: panelContainer
  property real contentPreferredWidth: 640 * Style.uiScaleRatio
  property real contentPreferredHeight: 560 * Style.uiScaleRatio
  readonly property bool allowAttach: true
  readonly property color panelOuterBackground: Qt.alpha(Color.mSurface, 0.05)
  readonly property color panelInnerBackground: Qt.alpha(Color.mPrimary, 0.1)
  readonly property color panelInnerBorder: Qt.alpha(Color.mPrimary, 0.35)
  readonly property color primaryDeepTone: Qt.tint(Color.mPrimary, Qt.rgba(0, 0, 0, 0.74))
  readonly property color primaryDeepToneHover: Qt.tint(Color.mPrimary, Qt.rgba(0, 0, 0, 0.82))
  readonly property color primaryDeepToneTrack: Qt.tint(Color.mPrimary, Qt.rgba(0, 0, 0, 0.62))

  anchors.fill: parent

  // Currently selected session for detail view
  property string selectedSessionId: ""

  // Cached properties — auto-updated when mainInstance.sessions changes
  readonly property var _selectedSession: {
    if (!mainInstance || !mainInstance.sessions || selectedSessionId.length === 0)
      return null;
    return mainInstance.sessions[selectedSessionId] || null;
  }

  readonly property var _sessionList: {
    if (!mainInstance || !mainInstance.sessions)
      return [];

    var ids = Object.keys(mainInstance.sessions);
    var list = [];
    for (var i = 0; i < ids.length; i++) {
      var s = mainInstance.sessions[ids[i]];
      if (s.phase === "ended")
        continue;
      list.push(s);
    }

    // Sort: waiting_for_approval first, then by last_activity descending
    list.sort(function(a, b) {
      if (a.phase === "waiting_for_approval" && b.phase !== "waiting_for_approval") return -1;
      if (b.phase === "waiting_for_approval" && a.phase !== "waiting_for_approval") return 1;
      return (b.last_activity || 0) - (a.last_activity || 0);
    });
    return list;
  }

  function phaseLabel(phase) {
    var labels = {
      "idle": "空闲",
      "processing": "处理中",
      "waiting_for_input": "等待输入",
      "waiting_for_approval": "等待审批",
      "compacting": "压缩上下文",
      "ended": "已结束"
    };
    return labels[phase] || phase;
  }

  function phaseColor(phase) {
    if (phase === "waiting_for_approval") return "#f59e0b";
    if (phase === "processing" || phase === "compacting") return "#06b6d4";
    if (phase === "waiting_for_input") return "#22c55e";
    if (phase === "ended") return Color.mOnSurfaceVariant;
    return Color.mOnSurface;
  }

  function projectName(cwd) {
    if (!cwd || cwd.length === 0) return "unknown";
    var parts = cwd.split("/");
    return parts[parts.length - 1] || cwd;
  }

  function formatTime(timestamp) {
    if (!timestamp) return "";
    var d = new Date(timestamp * 1000);
    return d.toLocaleTimeString(Qt.locale(), "HH:mm:ss");
  }

  function toolInputSummary(tool, toolInput) {
    if (!toolInput) return "";
    if (typeof toolInput === "string") return toolInput;

    var lines = [];
    var t = tool || "";

    if (t === "Bash") {
      if (toolInput.description)
        lines.push(toolInput.description);
      if (toolInput.command)
        lines.push("$ " + toolInput.command);
    } else if (t === "Read") {
      if (toolInput.file_path)
        lines.push("读取: " + toolInput.file_path);
    } else if (t === "Write") {
      if (toolInput.file_path)
        lines.push("写入: " + toolInput.file_path);
      if (toolInput.content)
        lines.push(toolInput.content.substring(0, 500));
    } else if (t === "Edit") {
      if (toolInput.file_path)
        lines.push("编辑: " + toolInput.file_path);
      if (toolInput.old_string)
        lines.push("- " + toolInput.old_string.substring(0, 200));
      if (toolInput.new_string)
        lines.push("+ " + toolInput.new_string.substring(0, 200));
    } else if (t === "Grep") {
      if (toolInput.pattern)
        lines.push("搜索: " + toolInput.pattern);
      if (toolInput.path)
        lines.push("路径: " + toolInput.path);
    } else if (t === "Glob") {
      if (toolInput.pattern)
        lines.push("查找: " + toolInput.pattern);
      if (toolInput.path)
        lines.push("路径: " + toolInput.path);
    } else if (t === "Task") {
      if (toolInput.subagent_type)
        lines.push("代理: " + toolInput.subagent_type);
      if (toolInput.description)
        lines.push(toolInput.description);
      else if (toolInput.prompt)
        lines.push(toolInput.prompt.substring(0, 300));
    } else if (t === "WebSearch") {
      if (toolInput.query)
        lines.push("搜索: " + toolInput.query);
    } else if (t === "WebFetch") {
      if (toolInput.url)
        lines.push("URL: " + toolInput.url);
    } else if (t === "AskUserQuestion") {
      var qs = toolInput.questions;
      if (qs && qs.length > 0) {
        for (var i = 0; i < qs.length; i++) {
          lines.push(qs[i].question || "");
          var opts = qs[i].options || [];
          for (var j = 0; j < opts.length; j++)
            lines.push("  " + (j + 1) + ". " + (opts[j].label || ""));
        }
      }
    } else {
      // 未知工具：提取常用字段
      var keys = ["command", "file_path", "pattern", "query", "prompt", "description", "url"];
      for (var k = 0; k < keys.length; k++) {
        if (toolInput[keys[k]])
          lines.push(keys[k] + ": " + String(toolInput[keys[k]]).substring(0, 300));
      }
      if (lines.length === 0) {
        try {
          return JSON.stringify(toolInput, null, 2);
        } catch (e) {
          return String(toolInput);
        }
      }
    }

    return lines.join("\n");
  }

  Rectangle {
    id: panelContainer
    anchors.fill: parent
    radius: Style.radiusL
    color: root.panelOuterBackground

    ColumnLayout {
      anchors.fill: parent
      anchors.margins: Style.marginM
      spacing: Style.marginM

      // --- Header ---
      RowLayout {
        Layout.fillWidth: true

        NIcon {
          icon: "brain"
          pointSize: Style.fontSizeXL
          color: Color.mPrimary
        }

        NText {
          text: "AI Monitor"
          font.pointSize: Style.fontSizeL
          font.weight: Font.Bold
          color: Color.mOnSurface
        }

        NText {
          text: {
            var count = mainInstance?.activeSessionCount || 0;
            if (count > 0)
              return count + " 个活跃会话";
            return "无活跃会话";
          }
          color: Color.mOnSurfaceVariant
          pointSize: Style.fontSizeS
        }

        Item { Layout.fillWidth: true }

        NIconButton {
          icon: "refresh"
          tooltipText: "刷新"
          onClicked: {
            if (mainInstance)
              mainInstance.refreshStatus();
          }
        }

        NIconButton {
          icon: "settings"
          tooltipText: "设置"
          onClicked: {
            if (pluginApi?.manifest && pluginApi?.panelOpenScreen) {
              BarService.openPluginSettings(pluginApi.panelOpenScreen, pluginApi.manifest);
            }
          }
        }
      }

      // --- Session List ---
      NBox {
        Layout.fillWidth: true
        Layout.fillHeight: root._selectedSession ? false : true
        Layout.preferredHeight: root._selectedSession ? 200 * Style.uiScaleRatio : -1
        color: root.panelInnerBackground
        border.color: root.panelInnerBorder
        border.width: Style.borderS

        ColumnLayout {
          anchors.fill: parent
          anchors.margins: Style.marginM
          spacing: Style.marginS

          NText {
            text: "会话列表"
            pointSize: Style.fontSizeL
            font.weight: Font.Bold
          }

          NScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            horizontalPolicy: ScrollBar.AlwaysOff
            gradientColor: Qt.alpha(root.primaryDeepTone, 0.72)
            handleColor: Qt.alpha(root.primaryDeepTone, 0.88)
            handleHoverColor: Qt.alpha(root.primaryDeepToneHover, 0.96)
            trackColor: Qt.alpha(root.primaryDeepToneTrack, 0.56)

            ColumnLayout {
              width: parent.width
              spacing: Style.marginXS

              Repeater {
                model: root._sessionList

                delegate: Rectangle {
                  Layout.fillWidth: true
                  Layout.preferredHeight: sessionRow.implicitHeight + Style.marginS * 2
                  radius: Style.iRadiusS
                  color: {
                    if (root.selectedSessionId === modelData.session_id)
                      return Qt.alpha(Color.mPrimary, 0.2);
                    if (sessionMouseArea.containsMouse)
                      return Qt.alpha(Color.mPrimary, 0.1);
                    return "transparent";
                  }
                  border.color: modelData.phase === "waiting_for_approval"
                                ? Qt.alpha("#f59e0b", 0.4) : "transparent"
                  border.width: modelData.phase === "waiting_for_approval" ? Style.borderS : 0

                  MouseArea {
                    id: sessionMouseArea
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: {
                      root.selectedSessionId = (root.selectedSessionId === modelData.session_id)
                                               ? "" : modelData.session_id;
                    }
                  }

                  RowLayout {
                    id: sessionRow
                    anchors.fill: parent
                    anchors.margins: Style.marginS
                    spacing: Style.marginS

                    // Status dot
                    Rectangle {
                      width: 8
                      height: 8
                      radius: 4
                      color: root.phaseColor(modelData.phase)
                    }

                    // Project name + phase + last response
                    ColumnLayout {
                      Layout.fillWidth: true
                      spacing: 2

                      RowLayout {
                        Layout.fillWidth: true
                        spacing: Style.marginXS

                        NText {
                          text: root.projectName(modelData.cwd)
                          font.weight: Font.DemiBold
                          elide: Text.ElideRight
                        }

                        NText {
                          text: root.phaseLabel(modelData.phase)
                          color: root.phaseColor(modelData.phase)
                          pointSize: Style.fontSizeS
                        }
                      }

                      NText {
                        Layout.fillWidth: true
                        visible: !!(modelData.last_response)
                        text: (modelData.last_response || "").split("\n")[0]
                        color: Color.mOnSurfaceVariant
                        pointSize: Style.fontSizeS
                        elide: Text.ElideRight
                        maximumLineCount: 1
                      }
                    }

                    // Time
                    NText {
                      text: root.formatTime(modelData.last_activity)
                      color: Color.mOnSurfaceVariant
                      pointSize: Style.fontSizeS
                    }
                  }
                }
              }

              // Empty state
              NText {
                Layout.fillWidth: true
                Layout.topMargin: Style.marginL
                visible: root._sessionList.length === 0
                text: mainInstance?.bridgeRunning
                      ? "暂无活跃 Claude Code 会话"
                      : "Bridge 未运行"
                color: Color.mOnSurfaceVariant
                horizontalAlignment: Text.AlignHCenter
              }
            }
          }
        }
      }

      // --- Approval Detail ---
      NBox {
        id: approvalDetail
        Layout.fillWidth: true
        Layout.fillHeight: true
        visible: {
          var s = root._selectedSession;
          return s !== null && s.phase === "waiting_for_approval";
        }
        color: Qt.alpha("#f59e0b", 0.08)
        border.color: Qt.alpha("#f59e0b", 0.4)
        border.width: Style.borderS

        ColumnLayout {
          anchors.fill: parent
          anchors.margins: Style.marginM
          spacing: Style.marginS

          RowLayout {
            Layout.fillWidth: true

            NIcon {
              icon: "alert-triangle"
              pointSize: Style.fontSizeL
              color: "#f59e0b"
            }

            NText {
              text: "权限审批"
              font.pointSize: Style.fontSizeL
              font.weight: Font.Bold
              color: "#f59e0b"
            }

            Item { Layout.fillWidth: true }
          }

          NText {
            Layout.fillWidth: true
            text: {
              var s = root._selectedSession;
              return "工具: " + (s?.tool || "unknown");
            }
            font.weight: Font.DemiBold
          }

          // Tool input display
          NScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            horizontalPolicy: ScrollBar.AsNeeded
            gradientColor: Qt.alpha(root.primaryDeepTone, 0.72)
            handleColor: Qt.alpha(root.primaryDeepTone, 0.88)
            handleHoverColor: Qt.alpha(root.primaryDeepToneHover, 0.96)
            trackColor: Qt.alpha(root.primaryDeepToneTrack, 0.56)

            NText {
              width: parent.width
              text: {
                var s = root._selectedSession;
                return root.toolInputSummary(s?.tool, s?.tool_input);
              }
              font.family: "monospace"
              pointSize: Style.fontSizeS
              color: Color.mOnSurface
              wrapMode: Text.WrapAnywhere
            }
          }

          // Action buttons
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.marginS

            NButton {
              text: "批准"
              icon: "check"
              onClicked: {
                var s = root._selectedSession;
                if (s && mainInstance) {
                  mainInstance.approvePermission(s.session_id, s.tool_use_id || "");
                }
              }
            }

            NButton {
              text: "拒绝"
              icon: "x"
              outlined: true
              onClicked: {
                var s = root._selectedSession;
                if (s && mainInstance) {
                  mainInstance.denyPermission(s.session_id, s.tool_use_id || "", "");
                }
              }
            }

            Item { Layout.fillWidth: true }

            NButton {
              text: "跳转终端"
              icon: "terminal-2"
              outlined: true
              onClicked: {
                var s = root._selectedSession;
                if (s && mainInstance) {
                  mainInstance.focusTerminal(s.session_id);
                }
              }
            }
          }
        }
      }

      // --- Non-approval session detail (when a non-approval session is selected) ---
      NBox {
        Layout.fillWidth: true
        Layout.fillHeight: true
        visible: {
          var s = root._selectedSession;
          return s !== null && s.phase !== "waiting_for_approval";
        }
        color: root.panelInnerBackground
        border.color: root.panelInnerBorder
        border.width: Style.borderS

        ColumnLayout {
          anchors.fill: parent
          anchors.margins: Style.marginM
          spacing: Style.marginS

          NText {
            text: "会话详情"
            font.pointSize: Style.fontSizeL
            font.weight: Font.Bold
          }

          NText {
            Layout.fillWidth: true
            text: {
              var s = root._selectedSession;
              if (!s) return "";
              return "路径: " + (s.cwd || "");
            }
            color: Color.mOnSurfaceVariant
            pointSize: Style.fontSizeS
            wrapMode: Text.WrapAnywhere
          }

          NText {
            Layout.fillWidth: true
            text: {
              var s = root._selectedSession;
              if (!s) return "";
              return "状态: " + root.phaseLabel(s.phase);
            }
            color: {
              var s = root._selectedSession;
              return root.phaseColor(s?.phase || "idle");
            }
          }

          NText {
            Layout.fillWidth: true
            visible: {
              var s = root._selectedSession;
              return s && s.tool;
            }
            text: {
              var s = root._selectedSession;
              if (!s) return "";
              var t = s.tool || "";
              if (t === "AskUserQuestion") return "当前工具: 用户交互";
              return "当前工具: " + t;
            }
            font.weight: Font.DemiBold
            color: Color.mOnSurfaceVariant
          }

          // Claude's last response
          NScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: {
              var s = root._selectedSession;
              return s && s.last_response && !s.tool;
            }
            horizontalPolicy: ScrollBar.AlwaysOff
            gradientColor: Qt.alpha(root.primaryDeepTone, 0.72)
            handleColor: Qt.alpha(root.primaryDeepTone, 0.88)
            handleHoverColor: Qt.alpha(root.primaryDeepToneHover, 0.96)
            trackColor: Qt.alpha(root.primaryDeepToneTrack, 0.56)

            NText {
              width: parent.width
              text: {
                var s = root._selectedSession;
                return s?.last_response || "";
              }
              markdownTextEnabled: true
              color: Color.mOnSurface
              pointSize: Style.fontSizeS
              wrapMode: Text.WrapAnywhere
            }
          }

          // AskUserQuestion hint
          Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: askHintRow.implicitHeight + Style.marginS * 2
            radius: Style.iRadiusS
            color: Qt.alpha("#f59e0b", 0.1)
            border.color: Qt.alpha("#f59e0b", 0.3)
            border.width: Style.borderS
            visible: {
              var s = root._selectedSession;
              return s && s.tool === "AskUserQuestion";
            }

            RowLayout {
              id: askHintRow
              anchors.fill: parent
              anchors.margins: Style.marginS
              spacing: Style.marginS

              NIcon {
                icon: "message-circle"
                pointSize: Style.fontSizeM
                color: "#f59e0b"
              }

              NText {
                Layout.fillWidth: true
                text: "此工具需要在终端中交互选择"
                color: "#f59e0b"
                pointSize: Style.fontSizeS
              }
            }
          }

          Item { Layout.fillHeight: true }

          // Focus terminal button
          RowLayout {
            Layout.fillWidth: true

            Item { Layout.fillWidth: true }

            NButton {
              text: "跳转终端"
              icon: "terminal-2"
              outlined: true
              onClicked: {
                var s = root._selectedSession;
                if (s && mainInstance) {
                  mainInstance.focusTerminal(s.session_id);
                }
              }
            }
          }
        }
      }

      // --- Bridge status bar ---
      Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: 28
        radius: Style.iRadiusS
        color: mainInstance?.bridgeRunning
               ? Qt.alpha("#22c55e", 0.1)
               : Qt.alpha(Color.mError, 0.1)
        border.color: mainInstance?.bridgeRunning
                      ? Qt.alpha("#22c55e", 0.3)
                      : Qt.alpha(Color.mError, 0.3)
        border.width: Style.borderS

        RowLayout {
          anchors.fill: parent
          anchors.leftMargin: Style.marginS
          anchors.rightMargin: Style.marginS

          Rectangle {
            width: 6
            height: 6
            radius: 3
            color: mainInstance?.bridgeRunning ? "#22c55e" : Color.mError
          }

          NText {
            text: mainInstance?.bridgeRunning ? "Bridge 运行中" : "Bridge 未运行"
            pointSize: Style.fontSizeS
            color: Color.mOnSurfaceVariant
          }

          Item { Layout.fillWidth: true }

          NText {
            text: {
              var approvals = mainInstance?.pendingApprovals || [];
              if (approvals.length > 0)
                return approvals.length + " 个待审批";
              return "";
            }
            pointSize: Style.fontSizeS
            color: "#f59e0b"
            visible: (mainInstance?.pendingApprovals || []).length > 0
          }
        }
      }
    }
  }
}
