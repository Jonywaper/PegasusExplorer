import AppKit
import SwiftUI

@main
struct PegasusExplorerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Las ventanas las crea WindowManager; esta escena solo existe para tener los menús.
        Settings { EmptyView() }
            .commands { ExplorerCommands() }
    }
}

struct ExplorerCommands: Commands {
    /// La ventana que está al frente.
    private var state: AppState? { AppState.active }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("Acerca de \(appName)") { AboutWindow.show() }
            Button("Buscar actualizaciones…") { UpdateChecker.check(manual: true) }
        }
        CommandGroup(replacing: .appSettings) {}
        CommandGroup(replacing: .newItem) {
            Button("Ventana nueva") { WindowManager.open(state?.currentTab.url) }
                .keyboardShortcut("n")
            Button("Pestaña nueva") { state?.newTab() }
                .keyboardShortcut("t")
            Button("Cerrar pestaña") { state?.closeTab() }
                .keyboardShortcut("w")
            Divider()
            Button("Nueva carpeta") { state?.newFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Conectar a unidad de red…") { state?.showConnectDialog() }
                .keyboardShortcut("k")
        }
        CommandMenu("Ir") {
            Button("Atrás") { state?.currentTab.goBack() }
            Button("Adelante") { state?.currentTab.goForward() }
            Button("Carpeta superior") { state?.currentTab.goUp() }
            Divider()
            Button("Este equipo") { state?.currentTab.navigate(to: Locations.thisPC) }
            Button("Inicio") { state?.currentTab.navigate(to: FileManager.default.homeDirectoryForCurrentUser) }
            ForEach(KnownFolder.allCases, id: \.self) { folder in
                Button(folder.title) { state?.currentTab.navigate(to: folder.url) }
            }
            Button("Aplicaciones") { state?.currentTab.navigate(to: URL(fileURLWithPath: "/Applications")) }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?
    private static var launchURLs: [URL] = []

    /// Carpeta que pidió abrir otra app antes de que existiera la ventana.
    static func takeLaunchURL() -> URL? {
        launchURLs.isEmpty ? nil : launchURLs.removeFirst()
    }

    private static var launched = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.launched = true
        // Primera ventana: la carpeta que pidió otra app, o la carpeta de inicio.
        let pending = AppDelegate.launchURLs
        AppDelegate.launchURLs = []
        if pending.isEmpty { WindowManager.open() } else { pending.forEach { WindowManager.open($0) } }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            KeyboardShortcuts.handle(event) ? nil : event
        }
        // Diagnóstico: PEGASUS_DEBUGLOG=/ruta/archivo.log anota cada clic.
        if ProcessInfo.processInfo.environment["PEGASUS_DEBUGLOG"] != nil {
            _ = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
                if let view = event.window?.contentView {
                    let p = view.convert(event.locationInWindow, from: nil)
                    debugLog("\(event.type == .leftMouseDown ? "down" : "up  ") x=\(Int(p.x)) y=\(Int(view.bounds.height - p.y)) clics=\(event.clickCount)")
                }
                return event
            }
        }
        // «Abrir en PegasusExplorer» en el clic derecho del Finder (Servicios / Acciones rápidas).
        NSApp.servicesProvider = FinderService.shared
        NSUpdateDynamicServices()
        debugLog("inicio: PegasusExplorer \(UpdateChecker.currentVersion), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        Watchdog.start()
        runSnapshotIfRequested()
        // Avisa si hay una versión nueva (como mucho una vez al día).
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { UpdateChecker.checkAtLaunch() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Clic en el ícono del Dock sin ventanas abiertas: abre una.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag && !WindowManager.hasWindows { WindowManager.open() }
        return true
    }

    /// Cuando esta app es el explorador predeterminado, otras apps le piden abrir carpetas.
    func application(_ application: NSApplication, open urls: [URL]) {
        AppDelegate.reveal(urls.filter { $0.isFileURL })
    }

    /// Abre cada carpeta en una pestaña nueva; para un archivo, abre su carpeta y lo selecciona.
    static func reveal(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard let state = AppState.active else {
            let folders = urls.map { AppState.isFolder($0) ? $0 : $0.deletingLastPathComponent() }
            if launched { folders.forEach { WindowManager.open($0) } } else { launchURLs.append(contentsOf: folders) }
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        for url in urls {
            if AppState.isFolder(url) {
                state.newTab(at: url)
            } else {
                state.newTab(at: url.deletingLastPathComponent())
                state.currentTab.selection = [url.standardizedFileURL]
            }
        }
        debugLog("abrir desde fuera: \(urls.map(\.path)) -> pestañas: \(state.tabs.map(\.url.path)), seleccionado: \(state.currentTab.selection.map(\.lastPathComponent))")
        state.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Para desarrollo: SE_SNAPSHOT=/ruta/captura.png guarda una imagen de la ventana y cierra la app.
    private func runSnapshotIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["SE_SNAPSHOT"] else {
            // SE_START sin captura: solo abre esa ubicación (para pruebas).
            if let start = env["SE_START"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    AppState.active?.currentTab.navigate(to: start == "thispc" ? Locations.thisPC : URL(fileURLWithPath: start))
                }
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard let state = AppState.active else { return }
            if let start = env["SE_START"] {
                state.currentTab.navigate(to: start == "thispc" ? Locations.thisPC : URL(fileURLWithPath: start))
            }
            if let mode = env["SE_VIEW"].flatMap(ViewMode.init(rawValue:)) { state.setViewMode(mode) }
            if let ribbon = env["SE_RIBBON"] { UserDefaults.standard.set(ribbon, forKey: "ribbonTab") }
            if env["SE_ABOUT"] != nil { AboutWindow.show() }
        }
        // SE_CLICK="x,y": doble clic en ese punto de la ventana (coordenadas de la captura).
        if let click = env["SE_CLICK"]?.split(separator: ",").compactMap({ Double($0) }), click.count == 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                guard let window = AppState.active?.window, let content = window.contentView else { return }
                let point = NSPoint(x: click[0], y: content.bounds.height - click[1])
                for count in 1...2 {
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                                          windowNumber: window.windowNumber, context: nil,
                                                          eventNumber: 0, clickCount: count, pressure: 1) {
                            NSApp.postEvent(event, atStart: false)
                        }
                    }
                }
            }
        }
        // SE_DRAG="x1,y1,x2,y2": arrastra con el botón presionado (para probar la selección por área).
        if let drag = env["SE_DRAG"]?.split(separator: ",").compactMap({ Double($0) }), drag.count == 4 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                guard let window = AppState.active?.window, let content = window.contentView else { return }
                let h = content.bounds.height
                var points = [NSPoint(x: drag[0], y: h - drag[1])]
                for step in 1...10 {
                    let t = Double(step) / 10
                    points.append(NSPoint(x: drag[0] + (drag[2] - drag[0]) * t, y: h - (drag[1] + (drag[3] - drag[1]) * t)))
                }
                for (index, point) in points.enumerated() {
                    let type: NSEvent.EventType = index == 0 ? .leftMouseDown : .leftMouseDragged
                    if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil,
                                                      eventNumber: 0, clickCount: 1, pressure: 1) {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
                // Captura con el botón aún presionado para ver el rectángulo; se suelta después.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if let event = NSEvent.mouseEvent(with: .leftMouseUp, location: points.last!, modifierFlags: [],
                                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil,
                                                      eventNumber: 0, clickCount: 1, pressure: 0) {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
            }
        }
        // SE_KEYS="125,125,124": pulsa esas teclas (códigos de tecla) para probar el teclado.
        if let keys = env["SE_KEYS"]?.split(separator: ",").compactMap({ UInt16($0) }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                guard let window = AppState.active?.window else { return }
                debugLog("prueba de teclas: \(keys)")
                for code in keys {
                    if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil,
                                                    characters: "", charactersIgnoringModifiers: "",
                                                    isARepeat: false, keyCode: code) {
                        // Directo al manejador: una app en segundo plano no recibe teclas por la cola.
                        debugLog("tecla \(code): manejada=\(KeyboardShortcuts.handle(event)) selección=\(AppState.active?.currentTab.selection.count ?? -1)")
                        if let w = AppState.active?.window {
                            debugLog("  ventana evento=\(event.window === w) hoja=\(w.sheetParent != nil) modal=\(NSApp.modalWindow != nil) foco=\(w.firstResponder.map { String(describing: type(of: $0)) } ?? "nil") activa=\(AppState.active != nil) misma=\(AppState.active?.window === event.window) flags=\(event.modifierFlags.rawValue)")
                        }
                    } else { debugLog("tecla \(code): no se pudo crear el evento") }
                }
            }
        }
        // SE_WINSIZE="ancho,alto": tamaño de la ventana para la prueba.
        if let size = env["SE_WINSIZE"]?.split(separator: ",").compactMap({ Double($0) }), size.count == 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if let window = AppState.active?.window {
                    window.setFrame(NSRect(x: 60, y: 60, width: size[0], height: size[1]), display: true)
                }
            }
        }
        // SE_ACTIVATE=1: trae la app al frente (el resaltado al pasar el ratón solo funciona así).
        if env["SE_ACTIVATE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                NSApp.activate(ignoringOtherApps: true)
                AppState.active?.window?.makeKeyAndOrderFront(nil)
            }
        }
        // SE_HOVER=1: mueve el ratón (virtualmente) por toda la ventana, para probar el redibujado.
        if env["SE_HOVER"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                guard let window = AppState.active?.window, let content = window.contentView else { return }
                var y: CGFloat = 10
                while y < content.bounds.height {
                    var x: CGFloat = 10
                    while x < content.bounds.width {
                        if let event = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: x, y: y), modifierFlags: [],
                                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                                          windowNumber: window.windowNumber, context: nil,
                                                          eventNumber: 0, clickCount: 0, pressure: 0) {
                            NSApp.postEvent(event, atStart: false)
                        }
                        x += 40
                    }
                    y += 30
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if env["SE_CLICK"] != nil { print("ubicación:", AppState.active?.currentTab.url.absoluteString ?? "-") }
            if env["SE_SIZES"] != nil, let window = AppState.active?.window, let view = window.contentView {
                print("ventana:", window.frame.size, "mínimo ventana:", window.minSize,
                      "restricciones:", view.constraints.count, "contenedor:", view.bounds,
                      "contenido:", view.subviews.first?.frame ?? .zero, "márgenes:", view.subviews.first?.safeAreaInsets ?? NSEdgeInsets())
            }
            let window = env["SE_ABOUT"] != nil
                ? NSApp.windows.first { $0.title.hasPrefix("Acerca de") }
                : AppState.active?.window
            if let view = window?.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }
}

/// Atajos del Explorador de Windows (y algunos de Finder).
/// Funcionan con Ctrl (como en Windows) y con Cmd (como en Mac).
enum KeyboardShortcuts {
    private enum Key {
        static let a: UInt16 = 0, c: UInt16 = 8, d: UInt16 = 2, e: UInt16 = 14, f: UInt16 = 3, h: UInt16 = 4
        static let i: UInt16 = 34, k: UInt16 = 40, l: UInt16 = 37, n: UInt16 = 45, p: UInt16 = 35, r: UInt16 = 15
        static let t: UInt16 = 17, v: UInt16 = 9, w: UInt16 = 13, x: UInt16 = 7, period: UInt16 = 47
        static let space: UInt16 = 49, tab: UInt16 = 48, returnKey: UInt16 = 36, enter: UInt16 = 76
        static let backspace: UInt16 = 51, forwardDelete: UInt16 = 117, escape: UInt16 = 53
        static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
        static let leftBracket: UInt16 = 33, rightBracket: UInt16 = 30
        static let f2: UInt16 = 120, f3: UInt16 = 99, f4: UInt16 = 118, f5: UInt16 = 96
        static let digits: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
    }

    static func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad, .capsLock])
        let code = event.keyCode

        // Con la Vista rápida abierta, la barra espaciadora o Esc la cierran.
        if QuickLook.shared.isVisible && flags.isEmpty && (code == Key.space || code == Key.escape) {
            QuickLook.shared.toggle([])
            return true
        }

        guard let window = event.window ?? NSApp.keyWindow ?? AppState.active?.window, window.sheetParent == nil, NSApp.modalWindow == nil,
              let state = AppState.active, state.window === window else { return false }
        // Mientras se escribe en la barra de direcciones o en la búsqueda, el teclado es del campo de texto.
        if window.firstResponder is NSText { return false }

        let tab = state.currentTab
        let selection = state.selectedURLs
        let ctrlOrCmd = flags == [.control] || flags == [.command]
        let ctrlOrCmdShift = flags == [.control, .shift] || flags == [.command, .shift]

        if ctrlOrCmd {
            switch code {
            case Key.c: state.copy(selection); return true
            case Key.x: state.cut(selection); return true
            case Key.v: state.paste(); return true
            case Key.a: state.selectAll(); return true
            case Key.d: state.duplicate(selection); return true
            case Key.i: state.showProperties(selection); return true
            case Key.t: state.newTab(); return true
            case Key.w: state.closeTab(); return true
            case Key.n: state.newWindow(); return true
            case Key.l: state.editAddressRequest += 1; return true
            case Key.e, Key.f: state.focusSearchRequest += 1; return true
            case Key.r: tab.reload(); return true
            // Solo Ctrl+H: Cmd+H es «Ocultar» en macOS y se respeta.
            case Key.h where flags == [.control]: state.prefs.showHidden.toggle(); return true
            case Key.k: state.showConnectDialog(); return true
            case Key.tab: state.selectTab(offset: 1); return true
            case Key.backspace: state.trash(selection); return true
            default: break
            }
            if let number = Key.digits[code] { state.selectTab(number: number); return true }
        }

        if ctrlOrCmdShift {
            switch code {
            case Key.n: state.newFolder(); return true
            case Key.c: state.copyPath(selection); return true
            case Key.tab: state.selectTab(offset: -1); return true
            case Key.period: state.prefs.showHidden.toggle(); return true
            default: break
            }
        }

        // Atajos de Finder para navegar: Cmd+[ / Cmd+] / Cmd+Arriba / Cmd+Abajo / Cmd+Opción+Delete.
        if flags == [.command] {
            switch code {
            case Key.leftBracket: tab.goBack(); return true
            case Key.rightBracket: tab.goForward(); return true
            case Key.up: tab.goUp(); return true
            case Key.down: state.open(selection); return true
            default: break
            }
        }
        if flags == [.command, .option] && code == Key.backspace {
            state.askDeletePermanently(selection)
            return true
        }

        if flags == [.option] {
            switch code {
            case Key.left: tab.goBack(); return true
            case Key.right: tab.goForward(); return true
            case Key.up: tab.goUp(); return true
            case Key.d: state.editAddressRequest += 1; return true
            case Key.p: state.prefs.showPreviewPane.toggle(); return true
            case Key.returnKey, Key.enter: state.showProperties(selection); return true
            default: break
            }
        }

        if flags == [.shift] && code == Key.forwardDelete {
            state.askDeletePermanently(selection)
            return true
        }

        // Flechas: moverse entre archivos (Mayús extiende la selección).
        if flags.isEmpty || flags == [.shift] {
            let extend = flags == [.shift]
            switch code {
            case Key.up: state.moveSelection(dx: 0, dy: -1, extend: extend); return true
            case Key.down: state.moveSelection(dx: 0, dy: 1, extend: extend); return true
            case Key.left where tab.viewMode != .details: state.moveSelection(dx: -1, dy: 0, extend: extend); return true
            case Key.right where tab.viewMode != .details: state.moveSelection(dx: 1, dy: 0, extend: extend); return true
            default: break
            }
        }

        if flags.isEmpty {
            switch code {
            case Key.f2: state.beginRename(); return true
            case Key.f3: state.focusSearchRequest += 1; return true
            case Key.f4: state.editAddressRequest += 1; return true
            case Key.f5: tab.reload(); return true
            case Key.backspace: tab.goBack(); return true
            case Key.forwardDelete: state.trash(selection); return true
            case Key.space:
                if selection.isEmpty { return false }
                state.quickLook(selection)
                return true
            case Key.returnKey, Key.enter:
                if selection.isEmpty { return false }
                state.open(selection)
                return true
            default: break
            }
        }
        return false
    }
}

/// Registro de acciones (carpetas abiertas, vista, versión) para entender un cierre inesperado.
/// Se guarda solo en esta Mac: ~/Library/Logs/PegasusExplorer.log (o en PEGASUS_DEBUGLOG).
func debugLog(_ message: String) {
    let path = ProcessInfo.processInfo.environment["PEGASUS_DEBUGLOG"]
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/PegasusExplorer.log").path
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    let line = "\(formatter.string(from: Date())) \(message)\n"
    // Si crece demasiado, empieza de nuevo (se queda con lo más reciente).
    if let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int), size > 512_000 {
        try? FileManager.default.removeItem(atPath: path)
    }
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        handle.closeFile()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// Servicio de macOS que aparece en el clic derecho del Finder.
final class FinderService: NSObject {
    static let shared = FinderService()

    @objc func openInPegasus(_ pasteboard: NSPasteboard, userData: String?,
                             error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else {
            error.pointee = "No se recibió ningún archivo ni carpeta." as NSString
            return
        }
        DispatchQueue.main.async { AppDelegate.reveal(urls) }
    }
}

/// Detector de bloqueos: si la ventana deja de responder más de 4 segundos, anota en el registro
/// qué carpeta, vista y tamaño de ventana había, para poder reproducir el problema.
enum Watchdog {
    private static var lastBeat = Date()
    private static var context = ""
    private static var reported = false
    private static let lock = NSLock()

    static func start() {
        // Latido desde el hilo principal, con el contexto actual.
        // En modos «common» para que también lata con un menú abierto o al redimensionar.
        let beat = Timer(timeInterval: 1, repeats: true) { _ in
            let state = AppState.active
            let tab = state?.currentTab
            let frame = state?.window?.frame ?? .zero
            let text = "carpeta=\(tab?.url.path ?? "-") vista=\(tab?.viewMode.rawValue ?? "-") elementos=\(tab?.items.count ?? 0) "
                + "ventana=\(Int(frame.width))x\(Int(frame.height)) barras=\(NSScroller.preferredScrollerStyle == .legacy ? "fijas" : "superpuestas") "
                + "panel=\(UserDefaults.standard.double(forKey: "sidebarWidth"))"
            lock.lock(); lastBeat = Date(); context = text; reported = false; lock.unlock()
        }
        RunLoop.main.add(beat, forMode: .common)
        let thread = Thread {
            while true {
                Thread.sleep(forTimeInterval: 2)
                lock.lock()
                let stalled = Date().timeIntervalSince(lastBeat) > 4 && !reported
                let text = context
                if stalled { reported = true }
                lock.unlock()
                if stalled { debugLog("BLOQUEO: la ventana no responde. \(text)") }
            }
        }
        thread.name = "PegasusWatchdog"
        thread.start()
    }
}
