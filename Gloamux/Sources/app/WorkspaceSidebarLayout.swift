import AppKit
import SwiftUI

enum SidebarWidth {
    case left, right

    var range: ClosedRange<Double> {
        switch self {
        case .left: return 200...520
        // One width for every right panel; a web page needs room, so it can take all but the terminal's minimum.
        case .right: return 240...4000
        }
    }

    var direction: Double { self == .left ? 1 : -1 }

    func clamp(_ width: Double, upTo available: Double = .infinity) -> Double {
        min(max(width, range.lowerBound), range.upperBound, max(0, available))
    }
}

struct WorkspaceSidebarWidths: Equatable {
    var left: Double
    var right: Double

    /// Fits the sidebars into the space left after reserving the center pane and the dividers.
    func fitting(in available: Double, reservingRight minimum: Double) -> Self {
        let left = min(left, max(0, available - minimum))
        return Self(left: left, right: min(right, max(0, available - left)))
    }
}

/// Owns the live widths so a drag relays out the columns without updating workspace preferences or toolbar content.
struct WorkspaceSidebarLayout<Leading: View, Center: View, Trailing: View>: View {
    let showsLeading: Bool
    let showsTrailing: Bool
    let sidebarColor: Color
    let dividerColor: Color
    let leadingContent: Leading
    let centerContent: Center
    let trailingContent: Trailing

    @AppStorage("leftSidebarWidth") private var savedLeft = 254.0
    /// The width of every right panel: the browser, files, quick commands, and color themes.
    @AppStorage("filesSidebarWidth") private var savedRight = 252.0
    @State private var liveWidths: WorkspaceSidebarWidths?

    var body: some View {
        GeometryReader { geometry in
            let dividerWidth = (showsLeading ? 1.0 : 0) + (showsTrailing ? 1.0 : 0)
            let available = max(0, geometry.size.width - 340 - dividerWidth)
            let widths = preferredWidths.fitting(in: available, reservingRight: minimumRightWidth)
            HStack(spacing: 0) {
                if showsLeading {
                    leadingContent
                        .frame(width: widths.left)
                        .background(sidebarColor)
                        .transition(.move(edge: .leading))
                    handle(.left, widths: widths, available: available)
                }
                centerContent.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                if showsTrailing {
                    HStack(spacing: 0) {
                        handle(.right, widths: widths, available: available)
                        trailingContent.frame(width: widths.right)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .onChange(of: showsLeading) { _, _ in liveWidths = nil }
        .onChange(of: showsTrailing) { _, _ in liveWidths = nil }
    }

    private var preferredWidths: WorkspaceSidebarWidths {
        if let liveWidths { return liveWidths }
        let right = showsTrailing ? SidebarWidth.right.clamp(savedRight) : 0
        return WorkspaceSidebarWidths(left: showsLeading ? SidebarWidth.left.clamp(savedLeft) : 0, right: right)
    }

    private var minimumRightWidth: Double { showsTrailing ? SidebarWidth.right.range.lowerBound : 0 }

    private func handle(_ side: SidebarWidth, widths: WorkspaceSidebarWidths, available: Double) -> some View {
        let width = side == .left ? widths.left : widths.right
        let opposite = side == .left ? widths.right : widths.left
        return SidebarResizeHandle(width: width, available: available - opposite, side: side, color: dividerColor) { width in
            var updated = widths
            if side == .left { updated.left = width } else { updated.right = width }
            guard updated != (liveWidths ?? widths) else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { liveWidths = updated }
        } finish: {
            guard let liveWidths else { return }
            if showsLeading, savedLeft != liveWidths.left { savedLeft = liveWidths.left }
            if showsTrailing, savedRight != liveWidths.right { savedRight = liveWidths.right }
            self.liveWidths = nil
        }
    }
}

/// A one-point divider with a wider grab area.
private struct SidebarResizeHandle: View {
    let width: Double
    let available: Double
    let side: SidebarWidth
    let color: Color
    let resize: (Double) -> Void
    let finish: () -> Void
    @State private var startWidth: Double?
    @State private var hovering = false

    var body: some View {
        Rectangle().fill(hovering || startWidth != nil ? Color.accentColor.opacity(0.6) : color).frame(width: 1)
            .overlay {
                Color.clear.frame(width: 9).contentShape(Rectangle())
                    .onHover { inside in
                        hovering = inside
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { drag in
                            let start = startWidth ?? width
                            if startWidth == nil { startWidth = start }
                            resize(side.clamp((start + drag.translation.width * side.direction).rounded(), upTo: available))
                        }
                        .onEnded { drag in
                            if let startWidth {
                                resize(side.clamp((startWidth + drag.translation.width * side.direction).rounded(), upTo: available))
                            }
                            startWidth = nil
                            finish()
                        })
            }
            .zIndex(1)
            .help(T("Drag to resize"))
    }
}
