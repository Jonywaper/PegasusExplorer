import AppKit
import SwiftUI

/// Crea y guarda las ventanas del explorador.
///
/// Las ventanas se crean a mano (no con WindowGroup de SwiftUI) para poder poner
/// `sizingOptions = []` en la vista que aloja el contenido. Con las opciones por defecto,
/// SwiftUI ajusta las restricciones de tamaño de la ventana cada vez que cambia el contenido;
/// en macOS 13 eso podía entrar en un bucle («more Update Constraints in Window passes than
/// there are views») y cerrar la app. Sin esas opciones, el contenido nunca toca la ventana.
enum WindowManager {
    private static var windows: [NSWindow] = []
    private static var observers: [ObjectIdentifier: NSObjectProtocol] = [:]

    @discardableResult
    static func open(_ url: URL? = nil) -> NSWindow {
        let hosting = NSHostingView(rootView: ContentView(initialURL: url))
        hosting.sizingOptions = []

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = appName
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        // El contenido va dentro de una vista contenedora normal, no como vista principal de la
        // ventana: así SwiftUI tampoco puede cambiar el tamaño mínimo o máximo de la ventana.
        let container = HostContainer(frame: NSRect(x: 0, y: 0, width: 1180, height: 720))
        hosting.frame = container.bounds
        container.addSubview(hosting)
        window.contentView = container

        // La primera ventana recuerda su tamaño y posición; las demás se abren en cascada.
        if let front = windows.last {
            window.setFrame(front.frame, display: false)
            let origin = window.cascadeTopLeft(from: NSPoint(x: front.frame.minX, y: front.frame.maxY))
            window.setFrameTopLeftPoint(origin)
        } else if !window.setFrameUsingName("PegasusVentana") {
            window.center()
        }
        if windows.isEmpty { window.setFrameAutosaveName("PegasusVentana") }

        windows.append(window)
        observers[ObjectIdentifier(window)] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            if let observer = observers.removeValue(forKey: ObjectIdentifier(window)) {
                NotificationCenter.default.removeObserver(observer)
            }
            // Se suelta en la siguiente vuelta, cuando la ventana ya terminó de cerrarse.
            DispatchQueue.main.async {
                window.contentView = nil
                windows.removeAll { $0 === window }
            }
        }
        window.minSize = NSSize(width: 820, height: 528)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    static var hasWindows: Bool { !windows.isEmpty }
}

/// Vista contenedora: mantiene el contenido exactamente del tamaño de la ventana.
final class HostContainer: NSView {
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        for view in subviews where view.frame != bounds { view.frame = bounds }
    }

    override func layout() {
        super.layout()
        for view in subviews where view.frame != bounds { view.frame = bounds }
    }
}
