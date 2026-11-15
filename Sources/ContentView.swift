import SwiftUI

let appName = "PegasusExplorer"

struct ContentView: View {
    @StateObject private var state: AppState
    @ObservedObject private var prefs = Preferences.shared
    @Environment(\.openWindow) private var openWindow
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 175
    @AppStorage("previewWidth") private var previewWidth: Double = 300

    init(initialURL: URL?) {
        _state = StateObject(wrappedValue: AppState(initialURL: initialURL))
    }

    var body: some View {
        let tab = state.currentTab
        VStack(spacing: 0) {
            TabStrip(state: state)
            Ribbon(state: state, tab: tab)
            Divider()
            NavigationBar(state: state, tab: tab)
            Divider()
            // Paneles con divisores propios: el ancho se guarda y no se reinicia al cambiar de carpeta.
            HStack(spacing: 0) {
                if prefs.showNavigationPane {
                    SidebarView(state: state, tab: tab)
                        .frame(width: sidebarWidth)
                    PaneDivider(width: $sidebarWidth, range: 140...420, growsToRight: true)
                }
                MainContent(state: state, tab: tab)
                    .frame(minWidth: 300, maxWidth: .infinity)
                if prefs.showPreviewPane {
                    PaneDivider(width: $previewWidth, range: 200...600, growsToRight: false)
                    PreviewArea(state: state, tab: tab)
                        .frame(width: previewWidth)
                }
            }
            Divider()
            StatusBar(state: state, tab: tab)
        }
        .frame(minWidth: 820, minHeight: 500)
        .navigationTitle(appName)
        .background(WindowAccessor { window in
            state.window = window
            AppState.active = state
        })
        .focusedSceneObject(state)
        .onAppear {
            state.openWindowAction = { url in openWindow(value: url) }
            focusFileList(in: state.window)
        }
        .onChange(of: state.selectedTabID) { _ in focusFileList(in: state.window) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if let window = note.object as? NSWindow, window == state.window { AppState.active = state }
        }
        .sheet(isPresented: Binding(get: { state.renameTarget != nil },
                                    set: { if !$0 { state.renameTarget = nil } })) {
            RenameSheet(state: state)
        }
        .sheet(isPresented: $state.showConnectSheet) {
            ConnectSheet(state: state)
        }
        .sheet(isPresented: Binding(get: { state.propertiesTarget != nil },
                                    set: { if !$0 { state.propertiesTarget = nil } })) {
            PropertiesSheet(state: state, urls: state.propertiesTarget ?? [])
        }
        .confirmationDialog(deleteTitle,
                            isPresented: Binding(get: { state.confirmPermanentDelete != nil },
                                                 set: { if !$0 { state.confirmPermanentDelete = nil } })) {
            Button("Eliminar permanentemente", role: .destructive) {
                if let urls = state.confirmPermanentDelete { state.deletePermanently(urls) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("No se enviará a la Papelera y no se podrá recuperar.")
        }
        .alert(appName,
               isPresented: Binding(get: { state.alertMessage != nil },
                                    set: { if !$0 { state.alertMessage = nil } })) {
            Button("Aceptar", role: .cancel) {}
        } message: {
            Text(state.alertMessage ?? "")
        }
    }

    private var deleteTitle: String {
        guard let urls = state.confirmPermanentDelete else { return "" }
        return urls.count == 1
            ? "¿Seguro que quieres eliminar permanentemente «\(urls[0].lastPathComponent)»?"
            : "¿Seguro que quieres eliminar permanentemente estos \(urls.count) elementos?"
    }

}

/// Contenido de la pestaña. Observa la pestaña para cambiar entre «Este equipo» y una carpeta
/// en cuanto se navega (si no, la ventana se quedaba mostrando la página anterior).
struct MainContent: View {
    let state: AppState
    @ObservedObject var tab: ExplorerTab

    var body: some View {
        if tab.isThisPC {
            ThisPCView(state: state)
        } else {
            FileListView(state: state, tab: tab)
        }
    }
}

/// Panel de vista previa del archivo seleccionado.
struct PreviewArea: View {
    let state: AppState
    @ObservedObject var tab: ExplorerTab

    var body: some View {
        let selected = state.selectedURLs
        PreviewPane(url: selected.count == 1 && !AppState.isFolder(selected[0]) ? selected[0] : nil)
    }
}

/// Da acceso a la NSWindow de la vista.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { onWindow(window) } }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { if let window = view.window { onWindow(window) } }
    }
}

/// Divisor arrastrable entre paneles (como el de Windows). Guarda el ancho del panel.
struct PaneDivider: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    /// true: el panel está a la izquierda del divisor (crece al arrastrar a la derecha).
    let growsToRight: Bool
    @State private var startWidth: Double?

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1)
            .overlay(
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let start = startWidth ?? width
                            startWidth = start
                            let delta = Double(value.translation.width) * (growsToRight ? 1 : -1)
                            width = min(range.upperBound, max(range.lowerBound, start + delta))
                        }
                        .onEnded { _ in startWidth = nil })
            )
            .zIndex(1)
    }
}

/// Pone el teclado en la lista de archivos (para usar flechas y atajos).
func focusFileList(in window: NSWindow?) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
        guard let window = window ?? NSApp.keyWindow, let root = window.contentView else { return }
        func findTable(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView, table.tableColumns.count > 1 { return table }
            for sub in view.subviews { if let found = findTable(sub) { return found } }
            return nil
        }
        if let table = findTable(root) {
            window.makeFirstResponder(table)
        } else {
            window.makeFirstResponder(nil)
        }
    }
}

// MARK: - Pestañas

struct TabStrip: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(state.tabs) { tab in
                        TabButton(tab: tab, isSelected: tab.id == state.selectedTabID,
                                  select: { state.selectedTabID = tab.id },
                                  close: { state.closeTab(tab.id) },
                                  newWindow: { state.newWindow(at: tab.url); state.closeTab(tab.id) })
                    }
                }
            }
            Button(action: { state.newTab() }) {
                Image(systemName: "plus").frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help("Nueva pestaña (Ctrl+T)")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct TabButton: View {
    @ObservedObject var tab: ExplorerTab
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    let newWindow: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if tab.isThisPC {
                Image(systemName: "desktopcomputer").foregroundColor(.blue)
            } else {
                WindowsFolderIcon(size: 16)
            }
            Text(tab.title).lineLimit(1).frame(maxWidth: 160, alignment: .leading)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.borderless)
            .opacity(isSelected || hovering ? 1 : 0)
            .help("Cerrar pestaña (Ctrl+W)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color(nsColor: .controlBackgroundColor)
                                 : (hovering ? Color.primary.opacity(0.06) : .clear)))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .onMiddleClick(perform: close)
        .contextMenu {
            Button("Cerrar pestaña", action: close)
            Button("Mover a una ventana nueva", action: newWindow)
        }
    }
}

// MARK: - Navegación y barra de direcciones

struct NavigationBar: View {
    @ObservedObject var state: AppState
    @ObservedObject var tab: ExplorerTab
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 2) {
            navButton("arrow.left", "Atrás: volver a la carpeta anterior (Alt+Izquierda)", enabled: tab.canGoBack) { tab.goBack() }
            navButton("arrow.right", "Adelante (Alt+Derecha)", enabled: tab.canGoForward) { tab.goForward() }
            Button { PopupMenu.show(recentEntries) } label: {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).frame(width: 14, height: 26)
            }
            .buttonStyle(.borderless)
            .disabled(!tab.canGoBack && !tab.canGoForward)
            .help("Ubicaciones recientes")
            navButton("arrow.up", "Subir: ir a la carpeta que contiene a esta (Alt+Arriba)", enabled: tab.canGoUp) { tab.goUp() }

            AddressBar(state: state, tab: tab)
                .padding(.leading, 4)
            navButton("arrow.clockwise", "Actualizar (F5)", enabled: true) { tab.reload() }

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Buscar en \(tab.title)", text: $tab.searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onExitCommand { tab.searchText = ""; searchFocused = false; focusFileList(in: state.window) }
                if !tab.searchText.isEmpty {
                    Button { tab.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 8)
            .frame(width: 220, height: 26)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.primary.opacity(0.15)))
            .disabled(tab.isThisPC)
            .onChange(of: state.focusSearchRequest) { _ in searchFocused = true }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var recentEntries: [MenuEntry] {
        var entries: [MenuEntry] = tab.forwardStack.reversed().map { url in
            MenuEntry(title: label(for: url)) { tab.goForward() }
        }
        // Los de «Adelante» solo se pueden alcanzar en orden; el primero es el inmediato.
        if !entries.isEmpty {
            entries = [MenuEntry(title: label(for: tab.forwardStack.last!)) { tab.goForward() }]
        }
        entries.append(MenuEntry(title: label(for: tab.url), checked: true) {})
        for (index, url) in tab.backStack.enumerated().reversed().prefix(12) {
            entries.append(MenuEntry(title: label(for: url)) { tab.jump(toBackIndex: index) })
        }
        return entries
    }

    private func label(for url: URL) -> String {
        if Locations.isThisPC(url) { return "Este equipo" }
        if url.path == "/" { return "Disco local" }
        return KnownFolder.matching(url)?.title ?? FileManager.default.displayName(atPath: url.path)
    }

    private func navButton(_ symbol: String, _ help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 26, height: 26)
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(help)
    }
}

struct AddressBar: View {
    @ObservedObject var state: AppState
    @ObservedObject var tab: ExplorerTab
    @ObservedObject var prefs = Preferences.shared
    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: .textBackgroundColor))
            RoundedRectangle(cornerRadius: 3).stroke(editing ? Color.accentColor : Color.primary.opacity(0.15))

            if editing {
                TextField("Escribe una ruta, \\\\servidor\\carpeta o smb://servidor/carpeta", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .padding(.horizontal, 8)
                    .onSubmit {
                        editing = false
                        state.go(to: text)
                        focusFileList(in: state.window)
                    }
                    .onExitCommand { editing = false; focusFileList(in: state.window) }
                    .onChange(of: focused) { isFocused in if !isFocused { editing = false } }
            } else {
                HStack(spacing: 0) {
                    Group {
                        if tab.isThisPC {
                            Image(systemName: "desktopcomputer").foregroundColor(.blue)
                        } else {
                            WindowsFolderIcon(size: 16)
                        }
                    }
                    .padding(.horizontal, 6)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8, weight: .semibold)).foregroundColor(.secondary)
                                    .padding(.horizontal, 3)
                                Button(segment.title) { tab.navigate(to: segment.url) }
                                    .buttonStyle(BreadcrumbStyle())
                            }
                        }
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 20)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: beginEditing)
                }
            }
        }
        .frame(height: 26)
        .onChange(of: state.editAddressRequest) { _ in beginEditing() }
    }

    private func beginEditing() {
        text = tab.isThisPC ? "Este equipo" : tab.url.path
        editing = true
        DispatchQueue.main.async { focused = true }
    }

    /// «Este equipo › Disco local (Macintosh HD) › Users › ...», como en Windows.
    private var segments: [(title: String, url: URL)] {
        var result: [(String, URL)] = []
        if !tab.isThisPC {
            var current = tab.url.standardizedFileURL
            let cloud = CloudDrive.containing(current, in: prefs.cloudDrives)
            let volume = Volume.containing(current, in: prefs.volumes)
            while true {
                let title: String
                if let cloud, current.path == cloud.url.path {
                    title = cloud.name
                } else if let volume, current.path == volume.url.path {
                    title = volume.name
                } else if let known = KnownFolder.matching(current) {
                    title = known.title
                } else {
                    title = FileManager.default.displayName(atPath: current.path)
                }
                result.insert((title, current), at: 0)
                if current.path == "/" || (volume != nil && current.path == volume!.url.path)
                    || (cloud != nil && current.path == cloud!.url.path) { break }
                current = current.deletingLastPathComponent()
            }
        }
        result.insert(("Este equipo", Locations.thisPC), at: 0)
        return result
    }
}

struct BreadcrumbStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BreadcrumbLabel(configuration: configuration)
    }

    private struct BreadcrumbLabel: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .lineLimit(1)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(configuration.isPressed ? 0.25 : (hovering ? 0.12 : 0))))
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Barra de estado

struct StatusBar: View {
    @ObservedObject var state: AppState
    @ObservedObject var tab: ExplorerTab
    @ObservedObject var prefs = Preferences.shared

    var body: some View {
        let items = tab.visibleItems(showHidden: prefs.showHidden)
        let selected = items.filter { tab.selection.contains($0.url) }
        let selectedBytes = selected.compactMap(\.size).reduce(0, +)
        HStack(spacing: 12) {
            if tab.isThisPC {
                Text("\(KnownFolder.allCases.count + 1 + prefs.volumes.count + prefs.cloudDrives.count) elementos")
            } else {
                Text(items.count == 1 ? "1 elemento" : "\(items.count) elementos")
            }
            if !selected.isEmpty {
                Divider().frame(height: 12)
                Text(selected.count == 1 ? "1 elemento seleccionado" : "\(selected.count) elementos seleccionados")
                if selectedBytes > 0 { Text(Format.bytes(selectedBytes)) }
            }
            if tab.isLoading || state.isConnecting {
                ProgressView().controlSize(.small)
                Text(state.isConnecting ? "Conectando…" : "Cargando…")
            }
            Spacer()
            if !tab.isThisPC {
                ForEach([ViewMode.details, .largeIcons], id: \.self) { mode in
                    Button { state.setViewMode(mode) } label: {
                        Image(systemName: mode.symbol)
                            .frame(width: 20, height: 18)
                            .background(tab.viewMode == mode ? Color.accentColor.opacity(0.22) : .clear)
                    }
                    .buttonStyle(.plain)
                    .help(mode.title)
                }
            }
        }
        .font(.system(size: 11))
        .foregroundColor(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Diálogos

struct RenameSheet: View {
    @ObservedObject var state: AppState
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cambiar nombre").font(.headline)
            TextField("Nombre", text: $state.renameText)
                .focused($focused)
                .frame(width: 360)
                .onSubmit { state.commitRename() }
            HStack {
                Spacer()
                Button("Cancelar") { state.renameTarget = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Cambiar nombre") { state.commitRename() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear {
            focused = true
            // Selecciona el nombre sin la extensión, como en Windows.
            DispatchQueue.main.async {
                guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
                let name = state.renameText as NSString
                let ext = name.pathExtension
                let isFolder = state.renameTarget.map(AppState.isFolder) ?? false
                let length = ext.isEmpty || isFolder || state.renameText.hasPrefix(".") ? name.length : name.length - ext.count - 1
                editor.setSelectedRange(NSRange(location: 0, length: max(0, length)))
            }
        }
    }
}

struct ConnectSheet: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Conectar a unidad de red").font(.headline)
            Text("Escribe la dirección de la carpeta compartida. macOS te pedirá usuario y contraseña si hace falta y puede guardarlos en tu llavero.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("\\\\servidor\\carpeta", text: $state.connectAddress)
                .frame(width: 420)
                .onSubmit(connect)
            Text("Ejemplos: \\\\192.168.1.10\\Compartida · smb://nas/Proyectos · afp://servidor/Datos · ftp://servidor · https://servidor/webdav")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Guardar en Red para volver a conectar", isOn: $state.connectSave)
            HStack {
                if state.isConnecting {
                    ProgressView().controlSize(.small)
                    Text("Conectando…").foregroundColor(.secondary)
                }
                Spacer()
                Button("Cancelar") { state.showConnectSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Conectar", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.connectAddress.trimmingCharacters(in: .whitespaces).isEmpty || state.isConnecting)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func connect() {
        let address = state.connectAddress.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else { return }
        state.connect(to: address, save: state.connectSave)
    }
}

// MARK: - Clic central (cerrar pestaña)

extension View {
    func onMiddleClick(perform action: @escaping () -> Void) -> some View {
        overlay(MiddleClickCatcher(action: action))
    }
}

private struct MiddleClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.action = action
    }

    final class CatcherView: NSView {
        var action: (() -> Void)?
        override func otherMouseUp(with event: NSEvent) {
            if event.buttonNumber == 2 { action?() } else { super.otherMouseUp(with: event) }
        }
        // Deja pasar los clics normales a la pestaña.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent,
                  event.type == .otherMouseDown || event.type == .otherMouseUp else { return nil }
            return super.hitTest(point)
        }
    }
}
