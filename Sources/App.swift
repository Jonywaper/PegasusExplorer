import AppKit
import SwiftUI

@main
struct PegasusExplorerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup(for: URL.self) { $url in
            ContentView(initialURL: url ?? AppDelegate.takeLaunchURL())
        }
        .defaultSize(width: 1180, height: 720)
        .commands { ExplorerCommands() }
    }
}

struct ExplorerCommands: Commands {
    @FocusedObject var state: AppState?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("Acerca de \(appName)") { AboutWindow.show() }
        }
        CommandGroup(replacing: .newItem) {
            Button("Ventana nueva") { openWindow(value: state?.currentTab.url ?? FileManager.default.homeDirectoryForCurrentUser) }
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            KeyboardShortcuts.handle(event) ? nil : event
        }
        runSnapshotIfRequested()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Cuando esta app es el explorador predeterminado, otras apps le piden abrir carpetas.
    func application(_ application: NSApplication, open urls: [URL]) {
        let folders = urls.filter { $0.isFileURL }
        guard !folders.isEmpty else { return }
        if let state = AppState.active {
            for url in folders {
                if AppState.isFolder(url) { state.newTab(at: url) } else { state.newTab(at: url.deletingLastPathComponent()) }
            }
            state.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            AppDelegate.launchURLs.append(contentsOf: folders)
        }
    }

    /// Para desarrollo: SE_SNAPSHOT=/ruta/captura.png guarda una imagen de la ventana y cierra la app.
    private func runSnapshotIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["SE_SNAPSHOT"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard let state = AppState.active else { return }
            if let start = env["SE_START"] {
                state.currentTab.navigate(to: start == "thispc" ? Locations.thisPC : URL(fileURLWithPath: start))
            }
            if let mode = env["SE_VIEW"].flatMap(ViewMode.init(rawValue:)) { state.setViewMode(mode) }
            if let ribbon = env["SE_RIBBON"] { UserDefaults.standard.set(ribbon, forKey: "ribbonTab") }
            if env["SE_ABOUT"] != nil { AboutWindow.show() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
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

        guard let window = NSApp.keyWindow, window.sheetParent == nil, NSApp.modalWindow == nil,
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
            case Key.h: state.prefs.showHidden.toggle(); return true
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
