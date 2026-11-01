import QtQuick
import QtQuick.Shapes
import qs.Commons
import qs.Commons as Commons

// Crisp vector Google AI / Gemini 4-point sparkle with a companion
// Antigravity satellite star. Rendered natively with QtQuick.Shapes + 4x MSAA
// so it adapts dynamically to any Omarchy theme color at both bar and hero sizes.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Commons.Color.foreground
  property color badgeColor: Commons.Color.urgent
  property bool warning: false

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  Shape {
    anchors.fill: parent
    antialiasing: true
    layer.enabled: true
    layer.samples: 4

    // Primary 4-pointed Google AI / Gemini star (centered slightly top-left to balance satellite)
    Sparkle {
      cx: root.width * 0.44
      cy: root.height * 0.46
      radius: root.width * 0.42
      pinch: 0.17
      starColor: root.color
    }

    // Companion Antigravity satellite sparkle in bottom-right orbit
    Sparkle {
      cx: root.width * 0.80
      cy: root.height * 0.78
      radius: root.width * 0.19
      pinch: 0.20
      starColor: root.warning ? root.badgeColor : root.color
    }
  }

  component Sparkle: ShapePath {
    property real cx: 0
    property real cy: 0
    property real radius: 6
    property real pinch: 0.18
    property color starColor: root.color

    readonly property real waist: radius * pinch

    fillColor: starColor
    strokeWidth: 0
    startX: cx
    startY: cy - radius

    PathQuad {
      controlX: cx + waist
      controlY: cy - waist
      x: cx + radius
      y: cy
    }
    PathQuad {
      controlX: cx + waist
      controlY: cy + waist
      x: cx
      y: cy + radius
    }
    PathQuad {
      controlX: cx - waist
      controlY: cy + waist
      x: cx - radius
      y: cy
    }
    PathQuad {
      controlX: cx - waist
      controlY: cy - waist
      x: cx
      y: cy - radius
    }
  }
}
