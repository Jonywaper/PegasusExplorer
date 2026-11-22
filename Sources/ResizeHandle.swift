import AppKit
import SwiftUI

/// Borde que se arrastra para cambiar un ancho (panel izquierdo, vista previa, columnas de Detalles).
///
/// Está hecho con eventos de AppKit y no con un gesto de SwiftUI: en esta app los gestos de
/// arrastre de SwiftUI no siempre recibían el ratón, y el borde no se movía.
struct ResizeHandle: NSViewRepresentable {
    let width: Double
    let range: ClosedRange<Double>
    /// +1: el ancho crece al arrastrar a la derecha; -1: al arrastrar a la izquierda.
    let direction: Double
    let onChange: (Double) -> Void

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        update(view)
        return view
    }

    func updateNSView(_ view: HandleView, context: Context) {
        update(view)
    }

    private func update(_ view: HandleView) {
        view.width = width
        view.range = range
        view.direction = direction
        view.onChange = onChange
    }

    final class HandleView: NSView {
        var width: Double = 0
        var range: ClosedRange<Double> = 0...1
        var direction: Double = 1
        var onChange: ((Double) -> Void)?
        private var startX: CGFloat = 0
        private var startWidth: Double = 0

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func layout() {
            super.layout()
            window?.invalidateCursorRects(for: self)
        }

        override func mouseDown(with event: NSEvent) {
            startX = event.locationInWindow.x
            startWidth = width
        }

        override func mouseDragged(with event: NSEvent) {
            let delta = Double(event.locationInWindow.x - startX) * direction
            let next = min(range.upperBound, max(range.lowerBound, startWidth + delta))
            if next != width {
                width = next
                onChange?(next)
            }
        }

        override func mouseUp(with event: NSEvent) {
            debugLog("ancho ajustado: \(Int(width))")
        }
    }
}
