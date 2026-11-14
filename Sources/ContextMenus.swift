import AppKit
import SwiftUI

// MARK: - Menú de clic derecho sobre archivos y carpetas

struct ItemContextMenu: View {
    let state: AppState
    let urls: [URL]

    var body: some View {
        let folders = urls.filter(AppState.isFolder)
        let single = urls.count == 1 ? urls[0] : nil
        let singleIsFolder = single.map(AppState.isFolder) ?? false
        let isPackage = single.map { ((try? $0.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false) } ?? false

        Group {
            Button("Abrir") { state.open(urls) }
            if !folders.isEmpty {
                Button("Abrir en una pestaña nueva") { state.open(folders, inNewTab: true) }
                Button("Abrir en ventana nueva") { folders.forEach { state.newWindow(at: $0) } }
            }
            if !urls.isEmpty && folders.count < urls.count {
                OpenWithMenu(state: state, urls: urls.filter { !AppState.isFolder($0) })
            }
            if singleIsFolder, let single {
                Button(state.prefs.isPinned(single) ? "Desanclar del Acceso rápido" : "Anclar al Acceso rápido") {
                    state.prefs.togglePin(single)
                }
            }
            Button("Vista rápida") { state.quickLook(urls) }
            if isPackage, let single {
                Button("Mostrar contenido del paquete") { state.showPackageContents(single) }
            }
            if let single, single.pathExtension.lowercased() == "zip" {
                Button("Extraer todo") { state.extract(single) }
            }
        }
        Divider()
        Group {
            ShareMenu(state: state, urls: urls)
            SendToMenu(state: state, urls: urls)
        }
        Divider()
        Group {
            Button("Cortar") { state.cut(urls) }
            Button("Copiar") { state.copy(urls) }
            Button("Duplicar") { state.duplicate(urls) }
        }
        Divider()
        Group {
            Button("Crear acceso directo") { state.createShortcut(urls) }
            Button("Eliminar") { state.trash(urls) }
            Button("Eliminar permanentemente…") { state.askDeletePermanently(urls) }
            if urls.count == 1 {
                Button("Cambiar nombre") { state.beginRename(urls[0]) }
            }
        }
        Divider()
        Group {
            TagsMenu(state: state, urls: urls)
            Button(urls.count == 1 ? "Comprimir «\(urls[0].lastPathComponent)»" : "Comprimir \(urls.count) elementos") {
                state.compress(urls)
            }
            if urls.count > 1 {
                Button("Nueva carpeta con la selección (\(urls.count) elementos)") { state.newFolder(with: urls) }
            }
            Button("Copiar ruta de acceso") { state.copyPath(urls) }
            Button("Mostrar en Finder") { state.showInFinder(urls) }
            if singleIsFolder, let single {
                Button("Abrir en Terminal") { state.openInTerminal(single) }
            }
            Divider()
            Button("Propiedades") { state.showProperties(urls) }
        }
    }
}

// MARK: - Menú de clic derecho sobre el fondo de la carpeta

struct BackgroundContextMenu: View {
    let state: AppState
    @ObservedObject var tab: ExplorerTab

    var body: some View {
        Group {
            Menu("Ver") {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Button { state.setViewMode(mode) } label: {
                        if tab.viewMode == mode { Label(mode.title, systemImage: "checkmark") } else { Text(mode.title) }
                    }
                }
            }
            SortMenu(tab: tab)
            Button("Actualizar") { tab.reload() }
        }
        Divider()
        Group {
            Button("Pegar") { state.paste() }
                .disabled(!FileClipboard.shared.hasContent)
            Button("Pegar acceso directo") { state.pasteShortcut() }
                .disabled(!FileClipboard.shared.hasContent)
        }
        Divider()
        Menu("Nuevo") {
            Button("Carpeta") { state.newFolder() }
            Divider()
            Button("Documento de texto") { state.newTextDocument() }
            Button("Documento de texto enriquecido") { state.newTextDocument(rich: true) }
        }
        Divider()
        Group {
            Button(state.prefs.isPinned(tab.url) ? "Desanclar del Acceso rápido" : "Anclar al Acceso rápido") {
                state.prefs.togglePin(tab.url)
            }
            Button("Abrir en Terminal") { state.openInTerminal() }
            Button("Mostrar en Finder") { state.showInFinder([]) }
            Button("Copiar ruta de acceso") { state.copyPath([]) }
        }
        Divider()
        Button("Propiedades") { state.showProperties([]) }
    }
}

// MARK: - Submenús

struct SortMenu: View {
    @ObservedObject var tab: ExplorerTab

    var body: some View {
        Menu("Ordenar por") {
            ForEach(SortField.allCases, id: \.self) { field in
                Button { field.apply(to: tab, ascending: tab.currentSort.field == field ? !tab.currentSort.ascending : field.defaultAscending) } label: {
                    if tab.currentSort.field == field { Label(field.title, systemImage: "checkmark") } else { Text(field.title) }
                }
            }
            Divider()
            Button { tab.currentSort.field.apply(to: tab, ascending: true) } label: {
                if tab.currentSort.ascending { Label("Ascendente", systemImage: "checkmark") } else { Text("Ascendente") }
            }
            Button { tab.currentSort.field.apply(to: tab, ascending: false) } label: {
                if !tab.currentSort.ascending { Label("Descendente", systemImage: "checkmark") } else { Text("Descendente") }
            }
        }
    }
}

enum SortField: CaseIterable {
    case name, date, kind, size

    var title: String {
        switch self {
        case .name: return "Nombre"
        case .date: return "Fecha de modificación"
        case .kind: return "Tipo"
        case .size: return "Tamaño"
        }
    }

    var defaultAscending: Bool { self == .name || self == .kind }

    func apply(to tab: ExplorerTab, ascending: Bool) {
        let order: SortOrder = ascending ? .forward : .reverse
        switch self {
        case .name: tab.sortOrder = [KeyPathComparator(\FileItem.name, comparator: .localizedStandard, order: order)]
        case .date: tab.sortOrder = [KeyPathComparator(\FileItem.sortDate, order: order)]
        case .kind: tab.sortOrder = [KeyPathComparator(\FileItem.kind, comparator: .localizedStandard, order: order)]
        case .size: tab.sortOrder = [KeyPathComparator(\FileItem.sortSize, order: order)]
        }
    }
}

extension ExplorerTab {
    var currentSort: (field: SortField, ascending: Bool) {
        guard let first = sortOrder.first else { return (.name, true) }
        let field: SortField
        switch first.keyPath {
        case \FileItem.sortDate: field = .date
        case \FileItem.kind: field = .kind
        case \FileItem.sortSize: field = .size
        default: field = .name
        }
        return (field, first.order == .forward)
    }
}

struct OpenWithMenu: View {
    let state: AppState
    let urls: [URL]

    var body: some View {
        Menu("Abrir con") {
            if let first = urls.first {
                let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: first)
                let others = NSWorkspace.shared.urlsForApplications(toOpen: first)
                    .filter { $0 != defaultApp }
                    .prefix(15)
                if let defaultApp {
                    Button { state.open(urls, with: defaultApp) } label: {
                        Label { Text("\(appName(defaultApp)) (predeterminada)") } icon: { Image(nsImage: smallIcon(defaultApp)) }
                    }
                    Divider()
                }
                ForEach(Array(others), id: \.self) { app in
                    Button { state.open(urls, with: app) } label: {
                        Label { Text(appName(app)) } icon: { Image(nsImage: smallIcon(app)) }
                    }
                }
                Divider()
            }
            Button("Elegir otra aplicación…") { state.chooseAppAndOpen(urls) }
        }
    }

    private func appName(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

struct ShareMenu: View {
    let state: AppState
    let urls: [URL]

    var body: some View {
        Menu("Compartir") {
            let services = NSSharingService.sharingServices(forItems: urls)
            ForEach(Array(services.enumerated()), id: \.offset) { _, service in
                Button { service.perform(withItems: urls) } label: {
                    Label { Text(service.title) } icon: { Image(nsImage: service.image) }
                }
            }
            if !services.isEmpty { Divider() }
            Button("Más…") { state.share(urls) }
        }
    }
}

struct SendToMenu: View {
    let state: AppState
    let urls: [URL]

    var body: some View {
        Menu("Enviar a") {
            Button("Carpeta comprimida (en zip)") { state.compress(urls) }
            Button("Destinatario de correo") { state.email(urls) }
            Button("Documentos") { state.copy(urls, to: KnownFolder.documents.url) }
            Button("Escritorio (crear acceso directo)") { state.sendToDesktop(urls) }
            let drives = state.prefs.volumes.filter { !$0.isRoot }
            if !drives.isEmpty {
                Divider()
                ForEach(drives) { volume in
                    Button { state.copy(urls, to: volume.url) } label: {
                        Label { Text(volume.name) } icon: { Image(nsImage: smallIcon(volume.url)) }
                    }
                }
            }
        }
    }
}

struct TagsMenu: View {
    let state: AppState
    let urls: [URL]

    var body: some View {
        Menu("Etiquetas") {
            let current = Set(urls.flatMap { (try? $0.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? [] })
            ForEach(FinderTags.all, id: \.self) { tag in
                Button { state.toggleTag(tag.name, on: urls) } label: {
                    Label { Text(current.contains(tag.name) ? "✓ \(tag.name)" : tag.name) }
                        icon: { Image(nsImage: NSImage.dot(tag.color)) }
                }
            }
            Divider()
            Button("Quitar etiquetas") { state.clearTags(urls) }
        }
    }
}

func smallIcon(_ url: URL) -> NSImage {
    let image = (IconCache.shared.icon(for: url).copy() as? NSImage) ?? NSImage()
    image.size = NSSize(width: 16, height: 16)
    return image
}

extension NSImage {
    static func dot(_ color: NSColor, size: CGFloat = 12) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
}

// MARK: - Menús desplegables de la cinta (NSMenu)

struct MenuEntry {
    var title: String
    var image: NSImage?
    var checked = false
    var enabled = true
    var action: (() -> Void)?
    var children: [MenuEntry] = []
    var isSeparator = false

    static let separator = MenuEntry(title: "", isSeparator: true)
}

private final class MenuHandler: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func run() { handler() }
}

enum PopupMenu {
    static func build(_ entries: [MenuEntry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            if entry.isSeparator {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
            item.image = entry.image
            item.state = entry.checked ? .on : .off
            item.isEnabled = entry.enabled
            if !entry.children.isEmpty {
                item.submenu = build(entry.children)
            } else if let action = entry.action {
                let handler = MenuHandler(action)
                item.target = handler
                item.action = #selector(MenuHandler.run)
                item.representedObject = handler
            }
            menu.addItem(item)
        }
        return menu
    }

    static func show(_ entries: [MenuEntry]) {
        build(entries).popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

extension AppState {
    /// Destinos de «Mover a» y «Copiar a», como en Windows.
    func destinationEntries(copying: Bool) -> [MenuEntry] {
        let urls = selectedURLs
        let enabled = !urls.isEmpty
        var places: [URL] = []
        for url in prefs.pinned + KnownFolder.allCases.map(\.url) where !places.contains(url) {
            places.append(url)
        }
        var entries = places.map { place in
            MenuEntry(title: KnownFolder.matching(place)?.title ?? FileManager.default.displayName(atPath: place.path),
                      image: smallIcon(place), enabled: enabled) { [weak self] in
                copying ? self?.copy(urls, to: place) : self?.move(urls, to: place)
            }
        }
        let drives = prefs.volumes.filter { !$0.isRoot }
        if !drives.isEmpty {
            entries.append(.separator)
            entries += drives.map { volume in
                MenuEntry(title: volume.name, image: smallIcon(volume.url), enabled: enabled) { [weak self] in
                    copying ? self?.copy(urls, to: volume.url) : self?.move(urls, to: volume.url)
                }
            }
        }
        entries.append(.separator)
        entries.append(MenuEntry(title: "Elegir ubicación…", enabled: enabled) { [weak self] in
            guard let self, let folder = self.chooseFolder(prompt: copying ? "Copiar" : "Mover") else { return }
            copying ? self.copy(urls, to: folder) : self.move(urls, to: folder)
        })
        return entries
    }
}
