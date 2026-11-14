import AppKit
import SwiftUI

enum ViewMode: String, CaseIterable {
    case largeIcons, mediumIcons, tiles, details

    var title: String {
        switch self {
        case .largeIcons: return "Iconos grandes"
        case .mediumIcons: return "Iconos medianos"
        case .tiles: return "Mosaicos"
        case .details: return "Detalles"
        }
    }

    var symbol: String {
        switch self {
        case .largeIcons: return "square.grid.2x2"
        case .mediumIcons: return "square.grid.3x3"
        case .tiles: return "rectangle.grid.2x2"
        case .details: return "list.bullet"
        }
    }
}

/// Una pestaña: carpeta actual, historial, contenido y selección.
final class ExplorerTab: ObservableObject, Identifiable {
    let id = UUID()

    @Published private(set) var url: URL
    @Published private(set) var items: [FileItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?
    @Published private(set) var backStack: [URL] = []
    @Published private(set) var forwardStack: [URL] = []
    @Published var selection = Set<URL>()
    @Published var searchText = ""
    @Published var viewMode: ViewMode
    @Published var sortOrder: [KeyPathComparator<FileItem>] = [
        KeyPathComparator(\FileItem.name, comparator: .localizedStandard),
    ]

    private var watcher: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?
    private var loadToken = 0

    init(url: URL) {
        self.url = url
        let saved = UserDefaults.standard.string(forKey: "viewMode").flatMap(ViewMode.init(rawValue:))
        viewMode = saved ?? .details
        reload()
    }

    deinit { watcher?.cancel() }

    var isThisPC: Bool { Locations.isThisPC(url) }

    var title: String {
        if isThisPC { return "Este equipo" }
        if url.path == "/" { return Volume.mounted().first(where: \.isRoot)?.name ?? "Disco local" }
        if let known = KnownFolder.matching(url) { return known.title }
        if let cloud = Preferences.shared.cloudDrives.first(where: { $0.url == url.standardizedFileURL }) { return cloud.name }
        return FileManager.default.displayName(atPath: url.path)
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { !isThisPC }

    /// Elementos a mostrar: filtrados y ordenados, carpetas primero (como en Windows).
    func visibleItems(showHidden: Bool) -> [FileItem] {
        var list = items
        if !showHidden { list = list.filter { !$0.isHidden } }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(query) } }
        let folders = list.filter(\.isDirectory).sorted(using: sortOrder)
        let files = list.filter { !$0.isDirectory }.sorted(using: sortOrder)
        return folders + files
    }

    // MARK: Navegación

    func navigate(to newURL: URL) {
        let target = Locations.isThisPC(newURL) ? newURL : newURL.standardizedFileURL
        debugLog("navegar a \(target.absoluteString)")
        guard target != url else { reload(); return }
        backStack.append(url)
        forwardStack.removeAll()
        show(target)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(url)
        show(previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(url)
        show(next)
    }

    /// Salta a una ubicación del historial (menú «Ubicaciones recientes»).
    func jump(toBackIndex index: Int) {
        guard backStack.indices.contains(index) else { return }
        let target = backStack[index]
        let skipped = backStack[(index + 1)...]
        forwardStack.append(url)
        forwardStack.append(contentsOf: skipped.reversed())
        backStack.removeSubrange(index...)
        show(target)
    }

    /// Sube a la carpeta que contiene a la actual. Desde la raíz de un disco va a «Este equipo».
    func goUp() {
        guard canGoUp else { return }
        let child = url
        let isVolumeRoot = (try? url.resourceValues(forKeys: [.isVolumeKey]).isVolume) ?? false
        let isCloudRoot = Preferences.shared.cloudDrives.contains { $0.url == url.standardizedFileURL }
        if url.path == "/" || isVolumeRoot || isCloudRoot {
            navigate(to: Locations.thisPC)
        } else {
            navigate(to: url.deletingLastPathComponent())
        }
        selection = [child]
    }

    private func show(_ target: URL) {
        url = target
        selection = []
        searchText = ""
        items = []
        reload()
    }

    // MARK: Carga del contenido

    func reload() {
        loadToken += 1
        if isThisPC {
            watcher?.cancel()
            watcher = nil
            items = []
            loadError = nil
            isLoading = false
            Preferences.shared.refreshVolumes()
            return
        }
        let token = loadToken
        let target = url
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try FileManager.default
                    .contentsOfDirectory(at: target, includingPropertiesForKeys: FileItem.resourceKeys, options: [])
                    .compactMap(FileItem.init(url:))
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadToken == token else { return }
                self.isLoading = false
                switch result {
                case .success(let list):
                    self.items = list
                    self.loadError = nil
                    let present = Set(list.map(\.url))
                    self.selection = self.selection.filter { present.contains($0) }
                case .failure(let error):
                    self.items = []
                    self.loadError = Self.describe(error)
                }
                self.watch()
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoPermissionError {
            return "No tienes permiso para abrir esta carpeta. Si es Escritorio, Documentos o Descargas, permite el acceso en Configuración del Sistema > Privacidad y seguridad > Archivos y carpetas."
        }
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError {
            return "Esta carpeta ya no existe o la unidad se desconectó."
        }
        return error.localizedDescription
    }

    /// Vuelve a cargar solo cuando algo cambia en la carpeta (también desde Finder).
    private func watch() {
        watcher?.cancel()
        watcher = nil
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .attrib], queue: .main)
        source.setEventHandler { [weak self] in self?.scheduleReload() }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    private func scheduleReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}

/// Estado de una ventana: pestañas, portapapeles y diálogos.
final class AppState: ObservableObject {
    /// La ventana que está al frente (recibe los atajos de teclado).
    static weak var active: AppState?

    let prefs = Preferences.shared

    @Published var tabs: [ExplorerTab] = []
    @Published var selectedTabID: UUID?

    // Diálogos
    @Published var alertMessage: String?
    @Published var renameTarget: URL?
    @Published var renameText = ""
    @Published var showConnectSheet = false
    @Published var connectAddress = ""
    @Published var connectSave = true
    @Published var isConnecting = false
    @Published var confirmPermanentDelete: [URL]?
    @Published var propertiesTarget: [URL]?

    // Pedidos de foco desde el teclado
    @Published var editAddressRequest = 0
    @Published var focusSearchRequest = 0

    weak var window: NSWindow?
    var openWindowAction: ((URL) -> Void)?

    init(initialURL: URL? = nil) {
        let first = ExplorerTab(url: initialURL ?? FileManager.default.homeDirectoryForCurrentUser)
        tabs = [first]
        selectedTabID = first.id
    }

    var currentTab: ExplorerTab {
        tabs.first { $0.id == selectedTabID } ?? tabs[0]
    }

    // MARK: Pestañas y ventanas

    func newTab(at url: URL? = nil) {
        let tab = ExplorerTab(url: url ?? FileManager.default.homeDirectoryForCurrentUser)
        tab.viewMode = currentTab.viewMode
        if let index = tabs.firstIndex(where: { $0.id == selectedTabID }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        selectedTabID = tab.id
    }

    func newWindow(at url: URL? = nil) {
        openWindowAction?(url ?? currentTab.url)
    }

    func closeTab(_ id: UUID? = nil) {
        let target = id ?? selectedTabID
        guard let index = tabs.firstIndex(where: { $0.id == target }) else { return }
        if tabs.count == 1 {
            window?.performClose(nil)
            return
        }
        tabs.remove(at: index)
        if selectedTabID == target {
            selectedTabID = tabs[min(index, tabs.count - 1)].id
        }
    }

    func selectTab(offset: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        selectedTabID = tabs[(index + offset + tabs.count) % tabs.count].id
    }

    func selectTab(number: Int) {
        guard !tabs.isEmpty else { return }
        let index = number == 9 ? tabs.count - 1 : number - 1
        if tabs.indices.contains(index) { selectedTabID = tabs[index].id }
    }

    func setViewMode(_ mode: ViewMode) {
        currentTab.viewMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "viewMode")
    }

    // MARK: Abrir

    static func isFolder(_ url: URL) -> Bool {
        guard let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else { return false }
        return (v.isDirectory ?? false) && !(v.isPackage ?? false)
    }

    func open(_ urls: [URL], inNewTab: Bool = false) {
        for url in urls {
            if Self.isFolder(url) {
                if inNewTab || urls.count > 1 { newTab(at: url) } else { currentTab.navigate(to: url) }
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func open(_ urls: [URL], with app: URL) {
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func chooseAppAndOpen(_ urls: [URL]) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Abrir"
        panel.message = "Elige la aplicación con la que quieres abrir el archivo."
        if panel.runModal() == .OK, let app = panel.url { open(urls, with: app) }
    }

    func showPackageContents(_ url: URL) {
        currentTab.navigate(to: url)
    }

    /// Lo que se escribe en la barra de direcciones.
    func go(to text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        if t.caseInsensitiveCompare("Este equipo") == .orderedSame {
            currentTab.navigate(to: Locations.thisPC)
            return
        }
        if NetworkShares.isNetworkAddress(t) {
            connect(to: t, save: false)
            return
        }
        let path = (t as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
            let url = URL(fileURLWithPath: path)
            if isDir.boolValue { currentTab.navigate(to: url) } else { NSWorkspace.shared.open(url) }
        } else {
            alertMessage = "No se encuentra «\(t)». Revisa la ortografía e inténtalo de nuevo."
        }
    }

    // MARK: Red y discos

    func connect(to address: String, save: Bool) {
        isConnecting = true
        NetworkShares.connect(address) { [weak self] result in
            guard let self else { return }
            self.isConnecting = false
            switch result {
            case .success(let folder):
                self.showConnectSheet = false
                if save { self.prefs.remember(address) }
                self.prefs.refreshVolumes()
                self.currentTab.navigate(to: folder)
            case .failure(NetworkShares.ConnectError.cancelled):
                break
            case .failure(let error):
                self.alertMessage = error.localizedDescription
            }
        }
    }

    func showConnectDialog() {
        connectAddress = ""
        showConnectSheet = true
    }

    func eject(_ volume: Volume) {
        let url = volume.url
        if currentTab.url.path.hasPrefix(url.path) { currentTab.navigate(to: Locations.thisPC) }
        DispatchQueue.global().async {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            } catch {
                DispatchQueue.main.async {
                    self.alertMessage = "No se pudo expulsar «\(volume.name)». Cierra los archivos que estén abiertos en esa unidad e inténtalo de nuevo."
                }
            }
        }
    }

    // MARK: Operaciones con archivos

    private func run(_ work: @escaping () throws -> [URL]?, then: (([URL]) -> Void)? = nil) {
        let tab = currentTab
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try work()
                DispatchQueue.main.async {
                    tab.reload()
                    if let result { then?(result) }
                }
            } catch {
                DispatchQueue.main.async {
                    tab.reload()
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }

    var selectedURLs: [URL] {
        let tab = currentTab
        return tab.visibleItems(showHidden: prefs.showHidden).map(\.url).filter { tab.selection.contains($0) }
    }

    /// Para los menús de clic derecho: lo seleccionado o el elemento clicado.
    func targets(_ urls: Set<URL>) -> [URL] {
        let list = currentTab.visibleItems(showHidden: prefs.showHidden).map(\.url).filter { urls.contains($0) }
        return list.isEmpty ? Array(urls) : list
    }

    var canWriteHere: Bool { !currentTab.isThisPC }

    func copy(_ urls: [URL]) {
        if !urls.isEmpty { FileClipboard.shared.set(urls, cut: false) }
    }

    func cut(_ urls: [URL]) {
        if !urls.isEmpty { FileClipboard.shared.set(urls, cut: true) }
    }

    func paste() {
        guard canWriteHere else { return }
        let (urls, cut) = FileClipboard.shared.current()
        guard !urls.isEmpty else { return }
        let folder = currentTab.url
        run({
            cut ? try FileOperations.move(urls, to: folder) : try FileOperations.copy(urls, to: folder)
        }, then: { [weak self] created in
            if cut { FileClipboard.shared.clearAfterCut() }
            self?.currentTab.selection = Set(created)
        })
    }

    /// «Pegar acceso directo»: crea alias de lo copiado en la carpeta actual.
    func pasteShortcut() {
        guard canWriteHere else { return }
        let urls = FileClipboard.shared.current().urls
        guard !urls.isEmpty else { return }
        let folder = currentTab.url
        run({ try FileOperations.makeShortcuts(urls, in: folder) }, then: { [weak self] created in
            self?.currentTab.selection = Set(created)
        })
    }

    func createShortcut(_ urls: [URL]) {
        guard let folder = urls.first?.deletingLastPathComponent() else { return }
        run({ try FileOperations.makeShortcuts(urls, in: folder) }, then: { [weak self] created in
            self?.currentTab.selection = Set(created)
        })
    }

    func sendToDesktop(_ urls: [URL]) {
        let desktop = KnownFolder.desktop.url
        run({ try FileOperations.makeShortcuts(urls, in: desktop) })
    }

    func copyPath(_ urls: [URL]) {
        let list = urls.isEmpty ? [currentTab.url] : urls
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(list.map { "\"\($0.path)\"" }.joined(separator: "\n"), forType: .string)
    }

    func trash(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        run({ try FileOperations.trash(urls); return nil })
    }

    func askDeletePermanently(_ urls: [URL]) {
        if !urls.isEmpty { confirmPermanentDelete = urls }
    }

    func deletePermanently(_ urls: [URL]) {
        run({ try FileOperations.deletePermanently(urls); return nil })
    }

    func duplicate(_ urls: [URL]) {
        guard let folder = urls.first?.deletingLastPathComponent() else { return }
        run({ try FileOperations.copy(urls, to: folder) }, then: { [weak self] created in
            self?.currentTab.selection = Set(created)
        })
    }

    func copy(_ urls: [URL], to folder: URL) {
        run({ try FileOperations.copy(urls, to: folder) })
    }

    func move(_ urls: [URL], to folder: URL) {
        run({ try FileOperations.move(urls, to: folder) })
    }

    func chooseFolder(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        panel.directoryURL = currentTab.isThisPC ? nil : currentTab.url
        return panel.runModal() == .OK ? panel.url : nil
    }

    func newFolder() {
        guard canWriteHere else { return }
        let folder = currentTab.url
        run({ [try FileOperations.newFolder(in: folder)] }, then: { [weak self] created in
            self?.currentTab.selection = Set(created)
            if let url = created.first { self?.beginRename(url) }
        })
    }

    func newFolder(with urls: [URL]) {
        guard canWriteHere, !urls.isEmpty else { return }
        let folder = currentTab.url
        run({ [try FileOperations.newFolder(with: urls, in: folder)] }, then: { [weak self] created in
            self?.currentTab.selection = Set(created)
            if let url = created.first { self?.beginRename(url) }
        })
    }

    func newTextDocument(rich: Bool = false) {
        guard canWriteHere else { return }
        let folder = currentTab.url
        run({ [rich ? try FileOperations.newRichTextDocument(in: folder) : try FileOperations.newTextDocument(in: folder)] },
            then: { [weak self] created in
                self?.currentTab.selection = Set(created)
                if let url = created.first { self?.beginRename(url) }
            })
    }

    func compress(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        run({ [try FileOperations.compress(urls)] }, then: { [weak self] created in
            self?.currentTab.selection = Set(created)
        })
    }

    func extract(_ zip: URL) {
        run({ [try FileOperations.extract(zip)] }, then: { [weak self] created in
            self?.currentTab.selection = Set(created)
        })
    }

    func beginRename(_ url: URL? = nil) {
        guard let target = url ?? selectedURLs.first else { return }
        renameText = target.lastPathComponent
        renameTarget = target
    }

    func commitRename() {
        guard let target = renameTarget else { return }
        let newName = renameText
        renameTarget = nil
        run({ [try FileOperations.rename(target, to: newName)] }, then: { [weak self] renamed in
            self?.currentTab.selection = Set(renamed)
        })
    }

    func setHidden(_ hidden: Bool, _ urls: [URL]) {
        run({ try FileOperations.setHidden(hidden, for: urls); return nil })
    }

    func toggleTag(_ tag: String, on urls: [URL]) {
        run({
            let allHave = urls.allSatisfy { url in
                ((try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []).contains(tag)
            }
            for url in urls {
                var tags = (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
                if allHave { tags.removeAll { $0 == tag } } else if !tags.contains(tag) { tags.append(tag) }
                try FileOperations.setTags(tags, for: url)
            }
            return nil
        })
    }

    func clearTags(_ urls: [URL]) {
        run({ for url in urls { try FileOperations.setTags([], for: url) }; return nil })
    }

    func selectAll() {
        currentTab.selection = Set(currentTab.visibleItems(showHidden: prefs.showHidden).map(\.url))
    }

    func selectNone() {
        currentTab.selection = []
    }

    func invertSelection() {
        let all = Set(currentTab.visibleItems(showHidden: prefs.showHidden).map(\.url))
        currentTab.selection = all.subtracting(currentTab.selection)
    }

    func showInFinder(_ urls: [URL]) {
        if urls.isEmpty {
            if !currentTab.isThisPC { NSWorkspace.shared.activateFileViewerSelecting([currentTab.url]) }
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    func openInTerminal(_ folder: URL? = nil) {
        let target = folder ?? currentTab.url
        guard !Locations.isThisPC(target),
              let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([target], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    func showProperties(_ urls: [URL]) {
        let list = urls.isEmpty ? (currentTab.isThisPC ? [] : [currentTab.url]) : urls
        if !list.isEmpty { propertiesTarget = list }
    }

    // MARK: Compartir (Finder)

    func share(_ urls: [URL]) {
        guard !urls.isEmpty, let window, let view = window.contentView else { return }
        let picker = NSSharingServicePicker(items: urls)
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        picker.show(relativeTo: NSRect(origin: point, size: NSSize(width: 1, height: 1)), of: view, preferredEdge: .minY)
    }

    func email(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: urls) {
            service.perform(withItems: urls)
        } else {
            alertMessage = "No hay una app de correo configurada."
        }
    }

    func quickLook(_ urls: [URL]) {
        QuickLook.shared.toggle(urls.isEmpty ? selectedURLs : urls)
    }
}
