import Foundation

enum WindowGeometry {
    static func constrained(_ current: CGRect, size: CGSize, visible: CGRect) -> CGRect {
        let width = min(size.width, visible.width), height = min(size.height, visible.height)
        return CGRect(x: min(max(current.minX, visible.minX), visible.maxX - width),
                      y: min(max(current.maxY - height, visible.minY), visible.maxY - height),
                      width: width, height: height)
    }
}
