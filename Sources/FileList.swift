import SwiftUI

/// Contenido de la carpeta en la vista elegida (Detalles, iconos o mosaicos).
struct FileListView: View {
    @ObservedObject var state: AppState
    @ObservedObject var tab: ExplorerTab
    @ObservedObject var prefs = Preferences.shared

    var body: some View {
        let items = tab.visibleItems(showHidden: prefs.showHidden)
        ZStack {
            ItemsView(state: state, tab: tab, items: items, showExtensions: prefs.showExtensions)

            if let error = tab.loadError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundColor(.orange)
                    Text(error).multilineTextAlignment(.center).frame(maxWidth: 420)
                }
                .padding()
            } else if items.isEmpty && !tab.isLoading {
                Text(tab.searchText.isEmpty ? "Esta carpeta está vacía."
                     : (tab.isSearching ? "Buscando…" : "Ningún elemento coincide con la búsqueda."))
                    .foregroundColor(.secondary)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: tab.selection) { _ in QuickLook.shared.update(state.selectedURLs) }
    }
}

// MARK: - Detalles, iconos y mosaicos

/// Lista de archivos propia (sin la tabla de SwiftUI, que en macOS 13 daba problemas).
/// Detalles es una lista con columnas; las demás vistas son una cuadrícula.
struct ItemsView: View {
    let state: AppState
    @ObservedObject var tab: ExplorerTab
    let items: [FileItem]
    let showExtensions: Bool
    /// Rectángulo de selección mientras se arrastra (en coordenadas de la cuadrícula).
    @State private var marquee: CGRect?
    @State private var selectionBeforeDrag = Set<URL>()
    /// Posición de cada elemento; se guarda aparte para no redibujar en cada cambio.
    @State private var frames = FrameStore()

    final class FrameStore {
        var frames: [URL: CGRect] = [:]
    }

    /// Hueco reservado para la barra de desplazamiento vertical.
    static let scrollerGutter: CGFloat = 16

    private var iconSize: CGFloat {
        switch tab.viewMode {
        case .largeIcons: return 96
        case .mediumIcons: return 48
        default: return 48
        }
    }

    private var columns: [GridItem] {
        switch tab.viewMode {
        case .largeIcons: return [GridItem(.adaptive(minimum: 120), spacing: 4)]
        case .tiles: return [GridItem(.adaptive(minimum: 250), spacing: 4, alignment: .leading)]
        default: return [GridItem(.adaptive(minimum: 88), spacing: 4)]
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if tab.viewMode == .details { DetailsHeader(tab: tab) }
            GeometryReader { viewport in
                ScrollViewReader { proxy in
                    ScrollView {
                        Group {
                            if tab.viewMode == .details {
                                LazyVStack(spacing: 0) {
                                    if tab.groupBy == .none {
                                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                            detailsRow(item, index)
                                        }
                                    } else {
                                        ForEach(tab.groups(items)) { group in
                                            GroupHeader(title: group.title, count: group.items.count)
                                            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                                                detailsRow(item, index)
                                            }
                                        }
                                    }
                                }
                                .padding(.vertical, 2)
                            } else {
                                LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                                    if tab.groupBy == .none {
                                        ForEach(items) { item in decorated(cell(item), item) }
                                    } else {
                                        ForEach(tab.groups(items)) { group in
                                            Section(header: GroupHeader(title: group.title, count: group.items.count)) {
                                                ForEach(group.items) { item in decorated(cell(item), item) }
                                            }
                                        }
                                    }
                                }
                                .padding(8)
                            }
                        }
                        // Ancho fijo que siempre reserva el hueco de la barra de desplazamiento: así el diseño
                        // no depende de si la barra está visible. (Si dependiera, con la barra siempre visible de
                        // macOS podía oscilar sin fin: aparece la barra, cambian las columnas, cambia el alto,
                        // desaparece la barra… hasta colgar o cerrar la app.)
                        .frame(width: max(0, viewport.size.width - ItemsView.scrollerGutter), alignment: .topLeading)
                        .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .topLeading)
                        .contentShape(Rectangle())
                        .onTapGesture { tab.selection = [] }
                        .background(MarqueeTracker(onChange: updateMarquee, onRightClick: showMenu, dragURLs: dragURLs))
                        // Soltar en un espacio vacío: a la carpeta actual.
                        .dropTarget(tab.isThisPC ? nil : tab.url, state: state, cornerRadius: 0)
                        .overlay(alignment: .topLeading) {
                            if let marquee {
                                Rectangle()
                                    .fill(Color.accentColor.opacity(0.15))
                                    .overlay(Rectangle().stroke(Color.accentColor.opacity(0.8), lineWidth: 1))
                                    .frame(width: marquee.width, height: marquee.height)
                                    .offset(x: marquee.minX, y: marquee.minY)
                                    .allowsHitTesting(false)
                            }
                        }
                        .coordinateSpace(name: "cuadricula")
                        .onPreferenceChange(CellFramesKey.self) { value in
                            frames.frames = value
                            // Elementos por fila (para las flechas arriba y abajo): los que comparten la primera fila visible.
                            if tab.viewMode == .details {
                                tab.columnsHint = 1
                            } else if let top = value.values.map(\.midY).min() {
                                // Las celdas de una fila están centradas entre sí: comparten el centro, no el borde.
                                tab.columnsHint = max(1, value.values.filter { abs($0.midY - top) < 2 }.count)
                            }
                        }
                    }
                    .onChange(of: tab.scrollTarget) { target in
                        if let target { proxy.scrollTo(target) }
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// Clic derecho: el menú se construye solo en ese momento (antes se preparaba uno por cada fila
    /// en cada redibujado, con sus listas de apps y de servicios para compartir).
    private func detailsRow(_ item: FileItem, _ index: Int) -> some View {
        decorated(DetailsRow(state: state, item: item, index: index, isSelected: tab.selection.contains(item.url),
                             location: tab.searchLocation(of: item), showExtensions: showExtensions), item)
    }

    /// Arrastrar archivos a otras apps: si se empieza sobre un elemento, se arrastra la selección
    /// (o solo ese elemento, si no estaba seleccionado). Sobre un espacio vacío devuelve nil
    /// y se dibuja el rectángulo de selección.
    private func dragURLs(at point: CGPoint) -> [URL]? {
        guard let hit = frames.frames.first(where: { $0.value.contains(point) })?.key else { return nil }
        if !tab.selection.contains(hit) {
            tab.selection = [hit]
            tab.anchor = hit
        }
        return state.targets(tab.selection)
    }

    private func showMenu(at point: CGPoint) {
        if let hit = frames.frames.first(where: { $0.value.contains(point) })?.key {
            if !tab.selection.contains(hit) {
                tab.selection = [hit]
                tab.anchor = hit
            }
            PopupMenu.show(state.itemMenuEntries(state.targets(tab.selection)))
        } else {
            PopupMenu.show(state.backgroundMenuEntries())
        }
    }

    /// Clic y posición (para la selección por área y el clic derecho) de cada elemento.
    private func decorated<Content: View>(_ content: Content, _ item: FileItem) -> some View {
        content
            .help(tab.searchLocation(of: item).map { "\(item.name) — en \($0)" } ?? "")
            .contentShape(Rectangle())
            .onTapGesture { click(item) }
            .dropTarget(item.isDirectory ? item.url : nil, state: state)
            .background(GeometryReader { geo in
                Color.clear.preference(key: CellFramesKey.self,
                                       value: [item.url: geo.frame(in: .named("cuadricula"))])
            })
            .id(item.url)
    }

    /// Selección por área: arrastrar con el botón presionado dibuja un rectángulo y selecciona lo que toca.
    /// Con ⌘, Ctrl o Mayús se agrega a la selección que ya había.
    private func updateMarquee(_ rect: CGRect?, _ flags: NSEvent.ModifierFlags) {
        guard let rect else {
            marquee = nil
            return
        }
        if marquee == nil {
            let additive = flags.contains(.command) || flags.contains(.shift) || flags.contains(.control)
            selectionBeforeDrag = additive ? tab.selection : []
        }
        marquee = rect
        let touched = frames.frames.filter { $0.value.intersects(rect) }.map(\.key)
        tab.selection = selectionBeforeDrag.union(touched)
    }

    @ViewBuilder
    private func cell(_ item: FileItem) -> some View {
        let isSelected = tab.selection.contains(item.url)
        let name = item.displayName(showExtensions: showExtensions)
        Group {
            if tab.viewMode == .tiles {
                HStack(spacing: 8) {
                    ItemIcon(item: item, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            ItemNameLabel(item: item, text: name, state: state, rename: state.rename,
                                          size: 12, centered: false, lineLimit: 1)
                            if !item.tags.isEmpty { TagDots(tags: item.tags) }
                        }
                        Text(item.kind).font(.caption).foregroundColor(.secondary).lineLimit(1)
                        if let size = item.size {
                            Text(Format.bytes(size)).font(.caption).foregroundColor(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(6)
            } else {
                VStack(spacing: 4) {
                    ItemIcon(item: item, size: iconSize)
                    HStack(spacing: 3) {
                        if !item.tags.isEmpty { TagDots(tags: item.tags) }
                        ItemNameLabel(item: item, text: name, state: state, rename: state.rename,
                                      size: 11, centered: true, lineLimit: isSelected ? 4 : 2)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity)
            }
        }
        .opacity(item.isHidden ? 0.55 : 1)
        .modifier(ItemHighlight(isSelected: isSelected, cornerRadius: 3, border: true, idle: .clear))
    }

    /// Clic, Ctrl/Cmd+clic (agregar o quitar), Mayús+clic (rango) y doble clic (abrir).
    private func click(_ item: FileItem) {
        let event = NSApp.currentEvent
        if (event?.clickCount ?? 1) >= 2 {
            state.open([item.url])
            return
        }
        let flags = event?.modifierFlags ?? []
        if flags.contains(.shift), let anchor = tab.anchor,
           let a = items.firstIndex(where: { $0.url == anchor }),
           let b = items.firstIndex(where: { $0.url == item.url }) {
            tab.selection = Set(items[min(a, b)...max(a, b)].map(\.url))
        } else if flags.contains(.command) || flags.contains(.control) {
            if tab.selection.contains(item.url) { tab.selection.remove(item.url) } else { tab.selection.insert(item.url) }
            tab.anchor = item.url
        } else {
            tab.selection = [item.url]
            tab.anchor = item.url
        }
    }
}

// MARK: - Columnas de Detalles

/// Anchos de las columnas de Detalles; se ajustan arrastrando el borde del encabezado y se recuerdan.
final class DetailsColumns: ObservableObject {
    static let shared = DetailsColumns()
    @Published var date: CGFloat { didSet { save(date, "columnDate") } }
    @Published var kind: CGFloat { didSet { save(kind, "columnKind") } }
    @Published var size: CGFloat { didSet { save(size, "columnSize") } }

    private init() {
        let d = UserDefaults.standard
        date = d.object(forKey: "columnDate") as? CGFloat ?? 150
        kind = d.object(forKey: "columnKind") as? CGFloat ?? 150
        size = d.object(forKey: "columnSize") as? CGFloat ?? 90
    }

    private func save(_ value: CGFloat, _ key: String) { UserDefaults.standard.set(Double(value), forKey: key) }
}

/// Título de un grupo («Hoy (3)», «Documento PDF (12)»…), como en Windows.
struct GroupHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 13)).foregroundColor(Color(red: 0.12, green: 0.36, blue: 0.75))
            Text("(\(count))").font(.system(size: 12)).foregroundColor(.secondary)
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Borde arrastrable entre columnas del encabezado.
private struct ColumnResizer: View {
    @Binding var width: CGFloat
    @State private var start: CGFloat?
    @State private var pushed = false

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.15))
            .frame(width: 1, height: 14)
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside && !pushed { NSCursor.resizeLeftRight.push(); pushed = true }
                if !inside && pushed { NSCursor.pop(); pushed = false }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let base = start ?? width
                    start = base
                    // La columna está a la derecha del borde: arrastrar a la izquierda la ensancha.
                    width = min(420, max(60, base - value.translation.width))
                }
                .onEnded { _ in start = nil })
    }
}

/// Encabezado con los nombres de columna; clic para ordenar (otra vez para invertir).
struct DetailsHeader: View {
    @ObservedObject var tab: ExplorerTab
    @ObservedObject private var columns = DetailsColumns.shared

    var body: some View {
        HStack(spacing: 0) {
            header("Nombre", .name).frame(maxWidth: .infinity, alignment: .leading)
            ColumnResizer(width: $columns.date)
            header("Fecha de modificación", .date).frame(width: columns.date - 7, alignment: .leading)
            ColumnResizer(width: $columns.kind)
            header("Tipo", .kind).frame(width: columns.kind - 7, alignment: .leading)
            ColumnResizer(width: $columns.size)
            header("Tamaño", .size).frame(width: columns.size - 7, alignment: .trailing)
        }
        .padding(.leading, 10)
        // Mismo margen derecho que la lista (que reserva el hueco de la barra de desplazamiento).
        .padding(.trailing, 10 + ItemsView.scrollerGutter)
        .frame(height: 26)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1) }
    }

    private func header(_ title: String, _ field: SortField) -> some View {
        let current = tab.currentSort
        return Button {
            let ascending = current.field == field ? !current.ascending : field.defaultAscending
            field.apply(to: tab, ascending: ascending)
        } label: {
            HStack(spacing: 4) {
                Text(title).lineLimit(1)
                if current.field == field {
                    Image(systemName: current.ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Una fila de la vista Detalles.
struct DetailsRow: View {
    let state: AppState
    let item: FileItem
    let index: Int
    let isSelected: Bool
    /// Subcarpeta donde está (solo en los resultados de búsqueda).
    let location: String?
    @ObservedObject private var columns = DetailsColumns.shared
    let showExtensions: Bool

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                ItemIcon(item: item, size: 16)
                ItemNameLabel(item: item, text: item.displayName(showExtensions: showExtensions), state: state,
                              rename: state.rename, size: 12, centered: false, lineLimit: 1)
                if let location {
                    Text("en \(location)").font(.system(size: 11)).foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.head)
                }
                if !item.tags.isEmpty { TagDots(tags: item.tags) }
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(Format.date(item.modified)).lineLimit(1)
                .padding(.horizontal, 4)
                .frame(width: columns.date, alignment: .leading)
            Text(item.kind).lineLimit(1)
                .padding(.horizontal, 4)
                .frame(width: columns.kind, alignment: .leading)
            Text(Format.size(item.size)).lineLimit(1)
                .padding(.horizontal, 4)
                .frame(width: columns.size, alignment: .trailing)
        }
        .font(.system(size: 12))
        .foregroundColor(.primary)
        .opacity(item.isHidden ? 0.55 : 1)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .modifier(ItemHighlight(isSelected: isSelected, cornerRadius: 0, border: false,
                                idle: index % 2 == 1 ? Color.primary.opacity(0.035) : .clear))
    }
}

/// Fondo de un elemento: seleccionado, o resaltado más tenue al pasar el ratón (como en Windows).
struct ItemHighlight: ViewModifier {
    let isSelected: Bool
    let cornerRadius: CGFloat
    let border: Bool
    let idle: Color
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: cornerRadius)
                .fill(isSelected ? Color.accentColor.opacity(hovering ? 0.30 : 0.22)
                                 : (hovering ? Color.accentColor.opacity(0.10) : idle)))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(border && isSelected ? Color.accentColor.opacity(0.55)
                                             : (border && hovering ? Color.accentColor.opacity(0.25) : .clear)))
            .onHover { hovering = $0 }
    }
}

/// Posiciones de los elementos de la cuadrícula (para la selección por área).
struct CellFramesKey: PreferenceKey {
    static var defaultValue: [URL: CGRect] = [:]
    static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Sigue el ratón con eventos de AppKit: selección por área, clic derecho y foco del teclado.
/// No intercepta los clics normales: solo observa, así el clic y el doble clic siguen funcionando.
struct MarqueeTracker: NSViewRepresentable {
    let onChange: (CGRect?, NSEvent.ModifierFlags) -> Void
    let onRightClick: (CGPoint) -> Void
    let dragURLs: (CGPoint) -> [URL]?

    func makeNSView(context: Context) -> TrackerView {
        let view = TrackerView()
        update(view)
        return view
    }

    func updateNSView(_ view: TrackerView, context: Context) {
        update(view)
    }

    private func update(_ view: TrackerView) {
        view.onChange = onChange
        view.onRightClick = onRightClick
        view.dragURLs = dragURLs
    }

    final class TrackerView: NSView, NSDraggingSource {
        var onChange: ((CGRect?, NSEvent.ModifierFlags) -> Void)?
        var onRightClick: ((CGPoint) -> Void)?
        var dragURLs: ((CGPoint) -> [URL]?)?
        private var monitor: Any?
        private var start: NSPoint?
        private var startFlags: NSEvent.ModifierFlags = []

        /// Qué está haciendo el botón presionado: nada aún, rectángulo de selección o arrastre de archivos.
        private enum Mode { case pending, marquee, dragging }
        private var mode = Mode.pending

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        /// Recibe el foco del teclado para que las flechas y los atajos lleguen a la lista
        /// (y no al campo de búsqueda).
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {}

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown]) { [weak self] event in
                guard let self else { return event }
                return self.handle(event) ? nil : event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        /// Devuelve true si el evento se consumió.
        private func handle(_ event: NSEvent) -> Bool {
            guard let window, event.window === window, window.attachedSheet == nil else { return false }
            let point = convert(event.locationInWindow, from: nil)
            let inside = visibleRect.contains(point)
            switch event.type {
            case .rightMouseDown:
                guard inside else { return false }
                window.makeFirstResponder(self)
                DispatchQueue.main.async { self.onRightClick?(point) }
                return true
            case .leftMouseDown:
                // Solo si el clic cae en la parte visible de la lista (no en el panel lateral ni la cinta).
                // Un clic dentro del campo de cambiar nombre es para ese campo.
                if let editor = window.firstResponder as? NSTextView, let field = editor.delegate as? NSView,
                   field.convert(field.bounds, to: nil).contains(event.locationInWindow) {
                    start = nil
                    return false
                }
                start = inside && event.clickCount == 1 ? point : nil
                startFlags = event.modifierFlags
                mode = .pending
                if inside, window.firstResponder !== self { window.makeFirstResponder(self) }
            case .leftMouseDragged:
                guard let start else { return false }
                switch mode {
                case .dragging:
                    return true
                case .pending:
                    if hypot(point.x - start.x, point.y - start.y) < 5 { return false }
                    // Al empezar a mover: sobre un elemento se arrastran archivos; en un espacio vacío, rectángulo.
                    if let urls = dragURLs?(start), !urls.isEmpty {
                        mode = .dragging
                        beginFileDrag(urls, from: start, event: event)
                        return true
                    }
                    mode = .marquee
                    fallthrough
                case .marquee:
                    let rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                                      width: abs(point.x - start.x), height: abs(point.y - start.y))
                    onChange?(rect, startFlags)
                }
            case .leftMouseUp:
                if mode == .marquee { onChange?(nil, startFlags) }
                start = nil
                mode = .pending
            default:
                break
            }
            return false
        }

        // MARK: Arrastrar archivos

        private func beginFileDrag(_ urls: [URL], from point: NSPoint, event: NSEvent) {
            let size: CGFloat = 48
            let items = urls.prefix(200).enumerated().map { index, url -> NSDraggingItem in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                // Íconos apilados, como en Finder; solo los primeros se ven desplazados.
                let offset = CGFloat(min(index, 4)) * 6
                let frame = NSRect(x: point.x - size / 2 + offset, y: point.y - size / 2 + offset, width: size, height: size)
                let icon = (IconCache.shared.icon(for: url).copy() as? NSImage) ?? NSImage()
                icon.size = NSSize(width: size, height: size)
                item.setDraggingFrame(frame, contents: icon)
                return item
            }
            debugLog("arrastrar archivos: \(urls.count)")
            let session = beginDraggingSession(with: items, event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
            session.draggingFormation = .pile
        }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            // Hacia otras apps: copiar (WhatsApp, Gmail…); el Finder decide mover o copiar según la unidad,
            // igual que hace con sus propios archivos.
            context == .outsideApplication ? [.copy, .move, .link, .generic] : [.copy, .move, .generic]
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            mode = .pending
            start = nil
            debugLog("arrastre terminado: operación \(operation.rawValue)")
        }
    }
}

// MARK: - Cambiar nombre en la misma lista

/// Elemento que se está renombrando y el texto escrito.
final class RenameController: ObservableObject {
    @Published var target: URL?
    @Published var text = ""
}

/// Nombre de un elemento; con F2 se convierte en un campo para escribir el nombre nuevo.
struct ItemNameLabel: View {
    let item: FileItem
    let text: String
    let state: AppState
    @ObservedObject var rename: RenameController
    let size: CGFloat
    let centered: Bool
    let lineLimit: Int

    var body: some View {
        if rename.target == item.url.standardizedFileURL {
            InlineRenameField(state: state, rename: rename, size: size, centered: centered,
                              isFolder: item.isDirectory)
        } else {
            Text(text)
                .font(.system(size: size))
                .multilineTextAlignment(centered ? .center : .leading)
                .lineLimit(lineLimit)
                .truncationMode(centered ? .tail : .middle)
        }
    }
}

private struct InlineRenameField: View {
    let state: AppState
    @ObservedObject var rename: RenameController
    let size: CGFloat
    let centered: Bool
    let isFolder: Bool
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $rename.text)
            .textFieldStyle(.plain)
            .font(.system(size: size))
            .multilineTextAlignment(centered ? .center : .leading)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1))
            .frame(minWidth: 60)
            .focused($focused)
            .onSubmit { state.commitRename() }
            .onExitCommand { state.cancelRename() }
            // Al hacer clic en otro lado se guarda el nombre, como en Windows.
            .onChange(of: focused) { isFocused in
                if !isFocused, rename.target != nil { state.commitRename() }
            }
            .onAppear {
                DispatchQueue.main.async {
                    focused = true
                    // Selecciona el nombre sin la extensión.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
                        let name = rename.text as NSString
                        let ext = name.pathExtension
                        let length = ext.isEmpty || isFolder || rename.text.hasPrefix(".")
                            ? name.length : name.length - ext.count - 1
                        editor.setSelectedRange(NSRange(location: 0, length: max(0, length)))
                    }
                }
            }
    }
}
