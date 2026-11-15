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
                Text(tab.searchText.isEmpty ? "Esta carpeta está vacía." : "Ningún elemento coincide con la búsqueda.")
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
                                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                        decorated(DetailsRow(item: item, index: index, isSelected: tab.selection.contains(item.url),
                                                             showExtensions: showExtensions), item)
                                    }
                                }
                                .padding(.vertical, 2)
                            } else {
                                LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                                    ForEach(items) { item in decorated(cell(item), item) }
                                }
                                .padding(8)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .topLeading)
                        .contentShape(Rectangle())
                        .onTapGesture { tab.selection = [] }
                        .background(MarqueeTracker(onChange: updateMarquee, onRightClick: showMenu))
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
            .contentShape(Rectangle())
            .onTapGesture { click(item) }
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
                            Text(name).lineLimit(1)
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
                        Text(name)
                            .font(.system(size: 11))
                            .multilineTextAlignment(.center)
                            .lineLimit(isSelected ? 4 : 2)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity)
            }
        }
        .opacity(item.isHidden ? 0.55 : 1)
        .background(RoundedRectangle(cornerRadius: 3).fill(isSelected ? Color.accentColor.opacity(0.22) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(isSelected ? Color.accentColor.opacity(0.55) : .clear))
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

enum DetailsColumns {
    static let date: CGFloat = 150
    static let kind: CGFloat = 150
    static let size: CGFloat = 90
}

/// Encabezado con los nombres de columna; clic para ordenar (otra vez para invertir).
struct DetailsHeader: View {
    @ObservedObject var tab: ExplorerTab

    var body: some View {
        HStack(spacing: 0) {
            header("Nombre", .name).frame(maxWidth: .infinity, alignment: .leading)
            header("Fecha de modificación", .date).frame(width: DetailsColumns.date, alignment: .leading)
            header("Tipo", .kind).frame(width: DetailsColumns.kind, alignment: .leading)
            header("Tamaño", .size).frame(width: DetailsColumns.size, alignment: .trailing)
        }
        .padding(.horizontal, 10)
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
    let item: FileItem
    let index: Int
    let isSelected: Bool
    let showExtensions: Bool

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                ItemIcon(item: item, size: 16)
                Text(item.displayName(showExtensions: showExtensions)).lineLimit(1).truncationMode(.middle)
                if !item.tags.isEmpty { TagDots(tags: item.tags) }
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(Format.date(item.modified)).lineLimit(1)
                .padding(.horizontal, 4)
                .frame(width: DetailsColumns.date, alignment: .leading)
            Text(item.kind).lineLimit(1)
                .padding(.horizontal, 4)
                .frame(width: DetailsColumns.kind, alignment: .leading)
            Text(Format.size(item.size)).lineLimit(1)
                .padding(.horizontal, 4)
                .frame(width: DetailsColumns.size, alignment: .trailing)
        }
        .font(.system(size: 12))
        .foregroundColor(.primary)
        .opacity(item.isHidden ? 0.55 : 1)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(
            isSelected ? Color.accentColor.opacity(0.22)
                : (index % 2 == 1 ? Color.primary.opacity(0.035) : Color.clear))
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

    func makeNSView(context: Context) -> TrackerView {
        let view = TrackerView()
        view.onChange = onChange
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ view: TrackerView, context: Context) {
        view.onChange = onChange
        view.onRightClick = onRightClick
    }

    final class TrackerView: NSView {
        var onChange: ((CGRect?, NSEvent.ModifierFlags) -> Void)?
        var onRightClick: ((CGPoint) -> Void)?
        private var monitor: Any?
        private var start: NSPoint?
        private var startFlags: NSEvent.ModifierFlags = []
        private var active = false

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

        /// Devuelve true si el evento se consumió (solo el clic derecho dentro de la lista).
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
                start = inside && event.clickCount == 1 ? point : nil
                startFlags = event.modifierFlags
                active = false
                if inside, window.firstResponder !== self { window.makeFirstResponder(self) }
            case .leftMouseDragged:
                guard let start else { return false }
                if !active && hypot(point.x - start.x, point.y - start.y) < 5 { return false }
                active = true
                let rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                                  width: abs(point.x - start.x), height: abs(point.y - start.y))
                onChange?(rect, startFlags)
            case .leftMouseUp:
                if active { onChange?(nil, startFlags) }
                start = nil
                active = false
            default:
                break
            }
            return false
        }
    }
}
