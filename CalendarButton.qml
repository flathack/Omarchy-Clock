import QtQuick
import qs.Commons

Rectangle {
  id: root
  property string label: ""
  property bool primary: false
  property bool danger: false
  property bool selected: false
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  signal clicked()

  implicitWidth: caption.implicitWidth + Style.space(22)
  implicitHeight: Style.space(32)
  radius: Style.cornerRadius
  color: selected || primary
    ? Style.selectedStateColor(foreground, Color.accent)
    : (mouse.containsMouse ? Style.hoverFillFor(foreground, Color.accent) : "transparent")
  border.width: selected || primary ? 0 : Style.spacing.hairline
  border.color: danger ? Color.urgent : Style.normalBorderFor(foreground, Color.accent)
  opacity: enabled ? 1 : 0.45

  Text {
    id: caption
    anchors.centerIn: parent
    textFormat: Text.PlainText
    text: root.label
    color: root.selected || root.primary
      ? Color.background
      : (root.danger ? Color.urgent : root.foreground)
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    font.bold: root.primary || root.selected
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    enabled: root.enabled
    cursorShape: root.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
    onClicked: root.clicked()
  }
}
