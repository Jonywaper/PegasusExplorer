import AppKit
import SwiftUI

// Los menús de clic derecho se construyen como NSMenu en el momento de usarlos.

extension AppState {
    private func appName(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func pinTitle(_ url: URL) -> String {
        prefs.isPinned(url) ? "Desanclar del Acceso rápido" : "Anclar al Acceso rápido"
    }

    /// Menú de clic derecho sobre archivos y carpetas.
    func itemMenuEntries(_ urls: [URL]) -> [MenuEntry] {
        let folders = urls.filter(AppState.isFolder)
        let files = urls.filter { !folders.contains($0) }
        let single = urls.count == 1 ? urls[0] : nil
        let singleIsFolder = single.map { folders.contains($0) } ?? false
        let isPackage = single.map { ((try? $0.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false) } ?? false

        var entries: [MenuEntry] = [MenuEntry(title: "Abrir") { [weak self] in self?.open(urls) }]
        if !folders.isEmpty {
            entries.append(MenuEntry(title: "Abrir en una pestaña nueva") { [weak self] in self?.open(folders, inNewTab: true) })
            entries.append(MenuEntry(title: "Abrir en ventana nueva") { [weak self] in folders.forEach { self?.newWindow(at: $0) } })
        }
        if !files.isEmpty {
            entries.append(MenuEntry(title: "Abrir con", children: openWithEntries(files)))
        }
        if singleIsFolder, let single {
            entries.append(MenuEntry(title: pinTitle(single)) { [weak self] in self?.prefs.togglePin(single) })
        }
        entries.append(MenuEntry(title: "Vista rápida") { [weak self] in self?.quickLook(urls) })
        if isPackage, let single {
            entries.append(MenuEntry(title: "Mostrar contenido del paquete") { [weak self] in self?.showPackageContents(single) })
        }
        if let single, single.pathExtension.lowercased() == "zip" {
            entries.append(MenuEntry(title: "Extraer todo") { [weak self] in self?.extract(single) })
        }
        entries.append(.separator)
        entries.append(MenuEntry(title: "Compartir", children: shareEntries(urls)))
        entries.append(MenuEntry(title: "Enviar a", children: sendToEntries(urls)))
        entries.append(.separator)
        entries.append(MenuEntry(title: "Cortar") { [weak self] in self?.cut(urls) })
        entries.append(MenuEntry(title: "Copiar") { [weak self] in self?.copy(urls) })
        entries.append(MenuEntry(title: "Duplicar") { [weak self] in self?.duplicate(urls) })
        entries.append(.separator)
        entries.append(MenuEntry(title: "Crear acceso directo") { [weak self] in self?.createShortcut(urls) })
        entries.append(MenuEntry(title: "Eliminar") { [weak self] in self?.trash(urls) })
        entries.append(MenuEntry(title: "Eliminar permanentemente…") { [weak self] in self?.askDeletePermanently(urls) })
        if let single {
            entries.append(MenuEntry(title: "Cambiar nombre") { [weak self] in self?.beginRename(single) })
        }
        entries.append(.separator)
        entries.append(MenuEntry(title: "Etiquetas", children: tagEntries(urls)))
        entries.append(MenuEntry(title: single.map { "Comprimir «\($0.lastPathComponent)»" } ?? "Comprimir \(urls.count) elementos") {
            [weak self] in self?.compress(urls)
        })
        if urls.count > 1 {
            entries.append(MenuEntry(title: "Nueva carpeta con la selección (\(urls.count) elementos)") { [weak self] in self?.newFolder(with: urls) })
        }
        entries.append(MenuEntry(title: "Copiar ruta de acceso") { [weak self] in self?.copyPath(urls) })
        entries.append(MenuEntry(title: "Mostrar en Finder") { [weak self] in self?.showInFinder(urls) })
        if singleIsFolder, let single {
            entries.append(MenuEntry(title: "Abrir en Terminal") { [weak self] in self?.openInTerminal(single) })
        }
        entries.append(.separator)
        entries.append(MenuEntry(title: "Propiedades") { [weak self] in self?.showProperties(urls) })
        return entries
    }

    /// Menú de clic derecho sobre el fondo de la carpeta.
    func backgroundMenuEntries() -> [MenuEntry] {
        let tab = currentTab
        let canPaste = canWriteHere && FileClipboard.shared.hasContent
        let sort = tab.currentSort
        var sortEntries = SortField.allCases.map { field in
            MenuEntry(title: field.title, checked: sort.field == field) {
                field.apply(to: tab, ascending: sort.field == field ? !sort.ascending : field.defaultAscending)
            }
        }
        sortEntries.append(.separator)
        sortEntries.append(MenuEntry(title: "Ascendente", checked: sort.ascending) { sort.field.apply(to: tab, ascending: true) })
        sortEntries.append(MenuEntry(title: "Descendente", checked: !sort.ascending) { sort.field.apply(to: tab, ascending: false) })

        return [
            MenuEntry(title: "Ver", children: ViewMode.allCases.map { mode in
                MenuEntry(title: mode.title, checked: tab.viewMode == mode) { [weak self] in self?.setViewMode(mode) }
            }),
            MenuEntry(title: "Ordenar por", children: sortEntries),
            MenuEntry(title: "Actualizar") { tab.reload() },
            .separator,
            MenuEntry(title: "Pegar", enabled: canPaste) { [weak self] in self?.paste() },
            MenuEntry(title: "Pegar acceso directo", enabled: canPaste) { [weak self] in self?.pasteShortcut() },
            .separator,
            MenuEntry(title: "Nuevo", children: [
                MenuEntry(title: "Carpeta") { [weak self] in self?.newFolder() },
                .separator,
                MenuEntry(title: "Documento de texto") { [weak self] in self?.newTextDocument() },
                MenuEntry(title: "Documento de texto enriquecido") { [weak self] in self?.newTextDocument(rich: true) },
            ]),
            .separator,
            MenuEntry(title: pinTitle(tab.url)) { [weak self] in self?.prefs.togglePin(tab.url) },
            MenuEntry(title: "Abrir en Terminal") { [weak self] in self?.openInTerminal() },
            MenuEntry(title: "Mostrar en Finder") { [weak self] in self?.showInFinder([]) },
            MenuEntry(title: "Copiar ruta de acceso") { [weak self] in self?.copyPath([]) },
            .separator,
            MenuEntry(title: "Propiedades") { [weak self] in self?.showProperties([]) },
        ]
    }

    func openWithEntries(_ files: [URL]) -> [MenuEntry] {
        var entries: [MenuEntry] = []
        if let first = files.first {
            let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: first)
            if let defaultApp {
                entries.append(MenuEntry(title: "\(appName(defaultApp)) (predeterminada)", image: smallIcon(defaultApp)) {
                    [weak self] in self?.open(files, with: defaultApp)
                })
                entries.append(.separator)
            }
            let others = NSWorkspace.shared.urlsForApplications(toOpen: first).filter { $0 != defaultApp }.prefix(15)
            for app in others {
                entries.append(MenuEntry(title: appName(app), image: smallIcon(app)) { [weak self] in self?.open(files, with: app) })
            }
            if !others.isEmpty { entries.append(.separator) }
        }
        entries.append(MenuEntry(title: "Elegir otra aplicación…") { [weak self] in self?.chooseAppAndOpen(files) })
        return entries
    }

    private func shareEntries(_ urls: [URL]) -> [MenuEntry] {
        var entries = NSSharingService.sharingServices(forItems: urls).map { service -> MenuEntry in
            let image = (service.image.copy() as? NSImage) ?? service.image
            image.size = NSSize(width: 16, height: 16)
            return MenuEntry(title: service.title, image: image) { service.perform(withItems: urls) }
        }
        if !entries.isEmpty { entries.append(.separator) }
        entries.append(MenuEntry(title: "Más…") { [weak self] in self?.share(urls) })
        return entries
    }

    private func sendToEntries(_ urls: [URL]) -> [MenuEntry] {
        var entries = [
            MenuEntry(title: "Carpeta comprimida (en zip)") { [weak self] in self?.compress(urls) },
            MenuEntry(title: "Destinatario de correo") { [weak self] in self?.email(urls) },
            MenuEntry(title: "Documentos") { [weak self] in self?.copy(urls, to: KnownFolder.documents.url) },
            MenuEntry(title: "Escritorio (crear acceso directo)") { [weak self] in self?.sendToDesktop(urls) },
        ]
        let drives = prefs.volumes.filter { !$0.isRoot }
        if !drives.isEmpty {
            entries.append(.separator)
            entries += drives.map { volume in
                MenuEntry(title: volume.name, image: smallIcon(volume.url)) { [weak self] in self?.copy(urls, to: volume.url) }
            }
        }
        return entries
    }

    private func tagEntries(_ urls: [URL]) -> [MenuEntry] {
        let current = Set(urls.flatMap { (try? $0.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? [] })
        var entries = FinderTags.all.map { tag in
            MenuEntry(title: tag.name, image: NSImage.dot(tag.color), checked: current.contains(tag.name)) {
                [weak self] in self?.toggleTag(tag.name, on: urls)
            }
        }
        entries.append(.separator)
        entries.append(MenuEntry(title: "Quitar etiquetas") { [weak self] in self?.clearTags(urls) })
        return entries
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
