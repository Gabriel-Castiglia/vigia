// Vigia: where the Files and Contents panes go, as on Windows (MainWindow.Layout.cs).
// Copyright (C) 2026 Gabriel Castiglia. Licensed under the GNU GPL, version 2 only.
// Date: November 21, 2026
// SPDX-License-Identifier: GPL-2.0-only
//
// Each pane goes to the left or to the right of the text (Prefs.filesSide / outlineSide); when both share a side
// they sit one above the other or side by side (leftArrange / rightArrange), Files first unless outlineFirst. Each
// arrangement keeps its own sidebar width (Prefs.layoutWidths). It is chosen three ways, as on Windows: the layout
// button at the right end of the toolbar (a drawing of every layout), View → Layout, or dragging a pane by its title
// to an edge of the window, where the place it would take is shown before it is let go.

import AppKit
import SwiftUI

enum Pane: String, CaseIterable { case files, outline }

struct LayoutPreset { let key, files, outline, arrange: String }

/// A layout as the drawings and the window see it: the side of each pane, which goes first, how each side sits and
/// which panes are shown.
struct LayoutShape: Equatable {
    var filesSide = "left", outlineSide = "left", leftArrange = "rows", rightArrange = "rows"
    var outlineFirst = false, filesOn = true, outlineOn = true

    func side(_ p: Pane) -> String { p == .files ? filesSide : outlineSide }
    func on(_ p: Pane) -> Bool { p == .files ? filesOn : outlineOn }
    func arrange(_ side: String) -> String { side == "right" ? rightArrange : leftArrange }
    /// The panes shown on one side, in their order.
    func panes(_ side: String) -> [Pane] {
        (outlineFirst ? [Pane.outline, .files] : [.files, .outline]).filter { on($0) && self.side($0) == side }
    }
    func cols(_ side: String) -> Bool { panes(side).count > 1 && arrange(side) == "cols" }
}

/// A place a dragged pane can go: a side, how the panes there will sit, and first or last among them. `zone` is
/// the part of the window's body that lights up, in the body's coordinates (top left = 0, 0).
struct DockTarget: Equatable {
    let side: String
    let arrange: String?
    let first: Bool
    let zone: CGRect
    let label: String
}

enum Layouts {
    static let presets = [
        LayoutPreset(key: "LayoutLeftRows", files: "left", outline: "left", arrange: "rows"),
        LayoutPreset(key: "LayoutLeftCols", files: "left", outline: "left", arrange: "cols"),
        LayoutPreset(key: "LayoutSplitFiles", files: "left", outline: "right", arrange: "rows"),
        LayoutPreset(key: "LayoutSplitOutline", files: "right", outline: "left", arrange: "rows"),
        LayoutPreset(key: "LayoutRightRows", files: "right", outline: "right", arrange: "rows"),
        LayoutPreset(key: "LayoutRightCols", files: "right", outline: "right", arrange: "cols"),
    ]

    static func shape(_ p: Prefs) -> LayoutShape {
        LayoutShape(filesSide: p.filesSide, outlineSide: p.outlineSide, leftArrange: p.leftArrange, rightArrange: p.rightArrange,
                    outlineFirst: p.outlineFirst, filesOn: p.sidebar && p.filesPanel, outlineOn: p.sidebar && p.outlinePanel)
    }

    /// The current layout with a preset applied and both panes shown, for the picker's drawings.
    static func shape(of preset: LayoutPreset, _ p: Prefs) -> LayoutShape {
        var s = shape(p)
        s.filesSide = preset.files; s.outlineSide = preset.outline
        s.filesOn = true; s.outlineOn = true
        if preset.files == preset.outline {
            if preset.files == "left" { s.leftArrange = preset.arrange } else { s.rightArrange = preset.arrange }
        }
        return s
    }

    static func isPreset(_ preset: LayoutPreset, _ p: Prefs) -> Bool {
        p.filesSide == preset.files && p.outlineSide == preset.outline
            && (preset.files != preset.outline || shape(p).arrange(preset.files) == preset.arrange)
    }

    private static func setArrange(_ side: String, _ arrange: String, _ p: Prefs) {
        if side == "right" { p.rightArrange = arrange } else { p.leftArrange = arrange }
    }

    /// A layout shows both panes.
    static func apply(_ preset: LayoutPreset, _ p: Prefs) {
        p.filesSide = preset.files; p.outlineSide = preset.outline
        if preset.files == preset.outline { setArrange(preset.files, preset.arrange, p) }
        p.sidebar = true; p.filesPanel = true; p.outlinePanel = true
    }

    /// Files and Contents trade places: their order on one side, or the sides themselves.
    static func swap(_ p: Prefs) {
        if p.filesSide == p.outlineSide { p.outlineFirst.toggle() } else { (p.filesSide, p.outlineSide) = (p.outlineSide, p.filesSide) }
    }

    // MARK: widths

    /// What a sidebar holds, as the key of its saved width: side, panes in order, and how they sit.
    static func widthKey(_ side: String, _ s: LayoutShape) -> String {
        let panes = s.panes(side)
        return side + ":" + panes.map(\.rawValue).joined(separator: "+") + (panes.count > 1 ? ":" + s.arrange(side) : "")
    }

    static func range(cols: Bool) -> ClosedRange<Double> { cols ? Prefs.columnsRange : Prefs.sidebarRange }
    static func defaultWidth(cols: Bool) -> Double { cols ? Prefs.defaultColumns : Prefs.defaultSidebar }

    static func width(_ side: String, _ p: Prefs) -> Double {
        let s = shape(p), r = range(cols: s.cols(side))
        let w = p.layoutWidths[widthKey(side, s)] ?? defaultWidth(cols: s.cols(side))
        return min(max(w, r.lowerBound), r.upperBound)
    }

    /// Saves the width of one side as it is now laid out; nil goes back to the usual width.
    static func setWidth(_ side: String, _ w: Double?, _ p: Prefs) {
        let s = shape(p)
        guard !s.panes(side).isEmpty else { return }
        p.layoutWidths[widthKey(side, s)] = w.map { $0.rounded() }
    }

    // MARK: dragging a pane

    /// The strip along each edge where a pane can be dropped.
    static func edge(_ width: CGFloat) -> CGFloat { min(max(width * 0.22, 140), 320) }

    static func name(_ pane: Pane) -> String { L(pane == .files ? "FilesShort" : "OutlineShort") }

    /// The place under the pointer (body coordinates): the strip along each edge; where the other pane already is,
    /// the upper third puts the dragged one above it, the lower third below, the middle beside it.
    static func target(_ pane: Pane, at pt: CGPoint, in size: CGSize, _ p: Prefs) -> DockTarget? {
        let W = size.width, H = size.height
        guard W > 0, H > 0, pt.y >= 0, pt.y <= H else { return nil }
        let e = edge(W)
        let side: String
        if pt.x < e { side = "left" } else if pt.x > W - e { side = "right" } else { return nil }
        let others = shape(p).panes(side).filter { $0 != pane }
        let x0 = side == "left" ? 0 : W - e
        let n = name(pane)
        guard let other = others.first else {
            return DockTarget(side: side, arrange: nil, first: true, zone: CGRect(x: x0, y: 0, width: e, height: H),
                              label: L(side == "left" ? "DockLeft" : "DockRight", n))
        }
        let of = L(other == .files ? "OfFiles" : "OfOutline")
        let fy = pt.y / H
        if fy < 1 / 3 {
            return DockTarget(side: side, arrange: "rows", first: true, zone: CGRect(x: x0, y: 0, width: e, height: H / 2), label: L("DockAbove", n, of))
        }
        if fy > 2 / 3 {
            return DockTarget(side: side, arrange: "rows", first: false, zone: CGRect(x: x0, y: H / 2, width: e, height: H / 2), label: L("DockBelow", n, of))
        }
        let firstHalf = pt.x - x0 < e / 2
        return DockTarget(side: side, arrange: "cols", first: firstHalf, zone: CGRect(x: firstHalf ? x0 : x0 + e / 2, y: 0, width: e / 2, height: H),
                          label: L(firstHalf ? "DockBesideLeft" : "DockBesideRight", n, of))
    }

    /// The dragged pane goes to the target: its side, how the panes there sit, and first or last among them.
    static func dock(_ pane: Pane, _ t: DockTarget, _ p: Prefs) {
        let others = shape(p).panes(t.side).filter { $0 != pane }
        if pane == .files { p.filesSide = t.side } else { p.outlineSide = t.side }
        if let a = t.arrange { setArrange(t.side, a, p) }
        if !others.isEmpty { p.outlineFirst = (pane == .outline) == t.first }
    }
}

// MARK: the drag

/// A pane dragged by its title. While it moves, a see-through window over the window's body shows both edges and,
/// under the pointer, the place the pane would take; letting go there moves it, anywhere else (or Esc) leaves
/// everything as it was. A window of its own, as on Windows, because the text is a web view that SwiftUI drawing
/// would not cover.
final class DockState: ObservableObject {
    var body: CGRect = .zero          // the window's body below the toolbar, in the window's SwiftUI coordinates
    weak var window: NSWindow?
    private(set) var pane: Pane?
    private(set) var target: DockTarget?
    private var overlay: NSWindow?
    private var host: NSHostingView<DockOverlay>?
    private var monitor: Any?
    private var cancelled = false

    var dragging: Bool { pane != nil }

    func move(_ p: Pane, to pt: CGPoint) {
        guard !cancelled else { return }
        if pane == nil { begin(p) }
        target = Layouts.target(p, at: CGPoint(x: pt.x - body.minX, y: pt.y - body.minY), in: body.size, Prefs.shared)
        host?.rootView = DockOverlay(size: body.size, target: target)
    }

    /// The mouse was let go: the pane moves if it is over a place, and the next drag starts afresh.
    func ended() {
        if !cancelled, let pane, let target { Layouts.dock(pane, target, Prefs.shared) }
        close()
        cancelled = false
    }

    private func begin(_ p: Pane) {
        pane = p
        NSCursor.closedHand.push()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.keyCode == 53 else { return e }      // Esc
            self.close(); self.cancelled = true
            return nil
        }
        guard let parent = window, body.width > 0 else { return }
        let f = parent.frame            // body is measured from the top left of the frame (GripView.point)
        let rect = NSRect(x: f.minX + body.minX, y: f.maxY - body.maxY, width: body.width, height: body.height)
        let w = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false; w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        let h = NSHostingView(rootView: DockOverlay(size: body.size, target: nil))
        w.contentView = h
        parent.addChildWindow(w, ordered: .above)
        overlay = w; host = h
    }

    private func close() {
        guard pane != nil else { return }
        pane = nil; target = nil
        NSCursor.pop()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let overlay { overlay.parent?.removeChildWindow(overlay); overlay.orderOut(nil) }
        overlay = nil; host = nil
    }
}

/// The guide drawn over the body while a pane is dragged: both edges dashed, the place under the pointer filled
/// and named.
struct DockOverlay: View {
    let size: CGSize
    let target: DockTarget?
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        let e = Layouts.edge(size.width), c = prefs.highlight
        ZStack(alignment: .topLeading) {
            box(CGRect(x: 0, y: 0, width: e, height: size.height), c, 0.06, 0.45, dashed: true)
            box(CGRect(x: size.width - e, y: 0, width: e, height: size.height), c, 0.06, 0.45, dashed: true)
            if let t = target {
                box(t.zone, c, 0.28, 0.95, dashed: false)
                Text(t.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8).fill(c))
                    .frame(maxWidth: max(120, t.zone.width - 16))
                    .fixedSize(horizontal: false, vertical: true)
                    .position(x: t.zone.midX, y: t.zone.midY)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func box(_ r: CGRect, _ c: Color, _ fill: Double, _ stroke: Double, dashed: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10).fill(c.opacity(fill))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(c.opacity(stroke), style: StrokeStyle(lineWidth: 2, dash: dashed ? [4, 3] : [])))
            .frame(width: max(0, r.width - 8), height: max(0, r.height - 8))
            .offset(x: r.minX + 4, y: r.minY + 4)
    }
}

/// The title of a pane, made a handle: the open hand under the pointer, and a drag that takes the pane elsewhere.
/// A see-through AppKit view laid over the title takes the mouse itself, as the dividers' strips do in AppKit apps:
/// a SwiftUI gesture on a line of text did not start for every press.
struct PaneGrip: ViewModifier {
    let pane: Pane
    let dock: DockState

    func body(content: Content) -> some View {
        content
            .overlay(GripArea(pane: pane, dock: dock))
            .accessibilityIdentifier(pane == .files ? "filesGrip" : "outlineGrip")
    }
}

struct GripArea: NSViewRepresentable {
    let pane: Pane
    let dock: DockState

    func makeNSView(context: Context) -> GripView {
        let v = GripView()
        v.pane = pane; v.dock = dock
        v.toolTip = L("PaneDragTip")
        return v
    }

    func updateNSView(_ v: GripView, context: Context) { v.pane = pane; v.dock = dock; v.toolTip = L("PaneDragTip") }
}

final class GripView: NSView {
    var pane: Pane = .files
    weak var dock: DockState?
    private var start: NSPoint?
    private var moving = false

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The pointer in SwiftUI's global coordinates, the ones DockState.body is in: from the top left of the window's
    /// frame, title bar included (measured: the body starts at 69 = 32 of title bar + 37 of toolbar).
    private func point(_ e: NSEvent) -> CGPoint {
        CGPoint(x: e.locationInWindow.x, y: (window?.frame.height ?? 0) - e.locationInWindow.y)
    }

    override func mouseDown(with e: NSEvent) { start = e.locationInWindow; moving = false }

    override func mouseDragged(with e: NSEvent) {
        guard let start, let dock else { return }
        if !moving, hypot(e.locationInWindow.x - start.x, e.locationInWindow.y - start.y) < 6 { return }
        moving = true
        dock.move(pane, to: point(e))
    }

    override func mouseUp(with e: NSEvent) {
        if moving { dock?.ended() }
        start = nil; moving = false
    }
}

// MARK: drawings and the picker

/// A small drawing of a layout: the text with a few lines, Files in the theme colour and Contents in a lighter
/// shade, as on Windows. The toolbar button shows the current one (small).
struct LayoutThumb: View {
    let shape: LayoutShape
    var width: CGFloat = 124
    var selected = false
    @ObservedObject private var prefs = Prefs.shared

    private var mini: Bool { width < 40 }
    private var gap: CGFloat { mini ? 1 : 3 }

    var body: some View {
        let h = (width * 0.63).rounded()
        HStack(spacing: gap) {
            side("left")
            text
            side("right")
        }
        .padding(gap)
        .frame(width: width, height: h)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: mini ? 3 : 6))
        .overlay(RoundedRectangle(cornerRadius: mini ? 3 : 6)
            .strokeBorder(selected ? prefs.highlight : Color.secondary.opacity(0.6), lineWidth: selected ? 2 : 1))
    }

    private func fill(_ p: Pane) -> Color { prefs.highlight.opacity(p == .files ? 0.9 : 0.42) }

    @ViewBuilder private func side(_ s: String) -> some View {
        let panes = shape.panes(s)
        if !panes.isEmpty {
            let cols = shape.cols(s)
            let share = cols ? min(0.5, 0.21 * Double(panes.count)) : 0.26
            Group {
                if cols {
                    HStack(spacing: gap) { ForEach(panes, id: \.self) { p in RoundedRectangle(cornerRadius: mini ? 1 : 3).fill(fill(p)) } }
                } else {
                    VStack(spacing: gap) { ForEach(panes, id: \.self) { p in RoundedRectangle(cornerRadius: mini ? 1 : 3).fill(fill(p)) } }
                }
            }
            .frame(width: (width - 2 * gap) * share)
        }
    }

    private var text: some View {
        GeometryReader { g in
            VStack(alignment: .leading, spacing: mini ? 2 : 5) {
                ForEach(0 ..< (mini ? 3 : 5), id: \.self) { i in
                    Capsule().fill(Color.secondary.opacity(0.45))
                        .frame(width: g.size.width * (i % 2 == 1 ? 0.6 : 0.85), height: mini ? 1.5 : 2.5)
                }
            }
            .padding(.top, mini ? 2 : 6).padding(.leading, mini ? 2 : 6)
        }
        .background(RoundedRectangle(cornerRadius: mini ? 1 : 3).fill(Color(nsColor: .textBackgroundColor)))
    }
}

/// What a popover is showing. A class and not @State (see DragState).
final class Shown: ObservableObject { @Published var on = false }

/// The toolbar button with the drawing of the layout in use; a click shows every layout drawn (a click applies it
/// and the panel stays open), the panes on or off, the swap, and how to drag a pane.
struct LayoutPicker: View {
    @ObservedObject var prefs: Prefs
    @StateObject private var pop = Shown()

    var body: some View {
        Button { pop.on.toggle() } label: { LayoutThumb(shape: Layouts.shape(prefs), width: 26).padding(.vertical, 1) }
            .buttonStyle(.borderless).help(L("LayoutPickerTip")).accessibilityLabel(L("LayoutPickerTip"))
            .accessibilityIdentifier("layoutPicker")
            .popover(isPresented: $pop.on, arrowEdge: .bottom) { LayoutPanel(prefs: prefs) }
    }
}

struct LayoutPanel: View {
    @ObservedObject var prefs: Prefs

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("LayoutPickerTitle")).font(.system(size: 12, weight: .semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(140), spacing: 6), count: 3), spacing: 6) {
                ForEach(Layouts.presets, id: \.key) { p in
                    let on = Layouts.isPreset(p, prefs)
                    Button { Layouts.apply(p, prefs) } label: {
                        VStack(spacing: 6) {
                            LayoutThumb(shape: Layouts.shape(of: p, prefs), width: 124, selected: on)
                            Text(L(p.key)).font(.system(size: 11, weight: on ? .semibold : .regular))
                                .foregroundStyle(on ? .primary : .secondary)
                                .multilineTextAlignment(.center).frame(width: 128).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(5)
                        .background(RoundedRectangle(cornerRadius: 9).fill(on ? prefs.highlight.opacity(0.14) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("layout-" + p.key)
                }
            }
            HStack(spacing: 8) {
                chip(L("FilesShort"), on: prefs.filesPanel && prefs.sidebar) { prefs.togglePane(.files) }
                chip(L("OutlineShort"), on: prefs.outlinePanel && prefs.sidebar) { prefs.togglePane(.outline) }
                Button { Layouts.swap(prefs) } label: { Label(L("LayoutSwapShort"), systemImage: "arrow.left.arrow.right") }
                    .controlSize(.small)
            }
            Text(L("LayoutDragHint")).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 464)
    }

    private func chip(_ title: String, on: Bool, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label { Text(title) } icon: {
                Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? prefs.highlight : .secondary)
            }
        }
        .controlSize(.small)
    }
}
