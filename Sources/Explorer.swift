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

/// «Agrupar por» del Explorador de Windows.
enum GroupBy: String, CaseIterable {
    case none, name, kind, date, size

    var title: String {
        switch self {
        case .none: return "(Ninguno)"
        case .name: return "Nombre"
        case .kind: return "Tipo"
        case .date: return "Fecha de modificación"
        case .size: return "Tamaño"
        }
    }

    /// Grupo de un elemento: orden del grupo y su título.
    func group(of item: FileItem) -> (rank: Int, title: String) {
        switch self {
        case .none:
            return (0, "")
        case .name:
            let first = item.name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).first
            guard let first else { return (1000, "Otros") }
            if first.isNumber { return (0, "0–9") }
            if let scalar = first.uppercased().unicodeScalars.first, ("A"..."Z").contains(Character(scalar)) {
                return (Int(scalar.value), String(scalar))
            }
            return (1000, "Otros")
        case .kind:
            return item.isDirectory ? (0, "Carpeta de archivos") : (1, item.kind)
        case .date:
            guard let date = item.modified else { return (8, "Sin fecha") }
            let calendar = Calendar.current
            let now = Date()
            if calendar.isDateInToday(date) { return (0, "Hoy") }
            if calendar.isDateInYesterday(date) { return (1, "Ayer") }
            if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return (2, "Esta semana") }
            if let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: now),
               calendar.isDate(date, equalTo: lastWeek, toGranularity: .weekOfYear) { return (3, "La semana pasada") }
            if calendar.isDate(date, equalTo: now, toGranularity: .month) { return (4, "Este mes") }
            if let lastMonth = calendar.date(byAdding: .month, value: -1, to: now),
               calendar.isDate(date, equalTo: lastMonth, toGranularity: .month) { return (5, "El mes pasado") }
            if calendar.isDate(date, equalTo: now, toGranularity: .year) { return (6, "Este año") }
            return (7, "Hace mucho tiempo")
        case .size:
            guard let size = item.size else { return (0, "Carpetas") }
            switch size {
            case 0: return (1, "Vacío (0 KB)")
            case ..<16_384: return (2, "Diminuto (0 - 16 KB)")
            case ..<1_048_576: return (3, "Pequeño (16 KB - 1 MB)")
            case ..<134_217_728: return (4, "Mediano (1 - 128 MB)")
            case ..<1_073_741_824: return (5, "Grande (128 MB - 1 GB)")
            case ..<4_294_967_296: return (6, "Enorme (1 - 4 GB)")
            default: return (7, "Gigantesco (> 4 GB)")
            }
        }
    }
}

/// Un grupo de elementos (con «Agrupar por»).
struct ItemGroup: Identifiable {
    let title: String
    let items: [FileItem]
    var id: String { title }
}

/// Una pestaña: carpeta actual, historial, contenido y selección.
final class ExplorerTab: ObservableObject, Identifiable {
    let id = UUID()

    @Published private(set) var url: URL
    @Published private(set) var items: [FileItem] = [] { didSet { visibleCache = nil } }
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?
    @Published private(set) var backStack: [URL] = []
    @Published private(set) var forwardStack: [URL] = []
    @Published var selection = Set<URL>()
    @Published var searchText = "" {
        didSet {
            visibleCache = nil
            if searchText != oldValue { scheduleSearch() }
        }
    }
    /// Resultados de buscar en esta carpeta y todas sus subcarpetas (nil = no se está buscando).
    @Published private(set) var searchResults: [FileItem]? { didSet { visibleCache = nil } }
    @Published private(set) var isSearching = false
    /// true si se llegó al límite de resultados.
    @Published private(set) var searchTruncated = false
    private var searchToken = 0
    static let searchLimit = 5000
    /// Último elemento clicado (para Mayús+clic y Mayús+flechas).
    var anchor: URL?
    /// Elementos por fila en la vista actual (lo calcula la vista; lo usan las flechas).
    var columnsHint = 1
    /// Pide a la lista que se desplace hasta este elemento.
    @Published var scrollTarget: URL?
    @Published var viewMode: ViewMode
    @Published var groupBy: GroupBy = GroupBy(rawValue: UserDefaults.standard.string(forKey: "groupBy") ?? "") ?? .none {
        didSet {
            visibleCache = nil
            UserDefaults.standard.set(groupBy.rawValue, forKey: "groupBy")
        }
    }
    @Published var sortOrder: [KeyPathComparator<FileItem>] = [
        KeyPathComparator(\FileItem.name, comparator: .localizedStandard),
    ] { didSet { visibleCache = nil } }
    /// Lista ya filtrada y ordenada: se calcula una vez y se reutiliza hasta que algo cambie.
    private var visibleCache: (showHidden: Bool, list: [FileItem])?

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
        if url.path == "/" { return Preferences.shared.volumes.first(where: \.isRoot)?.name ?? "Disco local" }
        if let known = KnownFolder.matching(url) { return known.title }
        if let cloud = Preferences.shared.cloudDrives.first(where: { $0.url == url.standardizedFileURL }) { return cloud.name }
        return FileManager.default.displayName(atPath: url.path)
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { !isThisPC }

    /// Elementos a mostrar: filtrados y ordenados, carpetas primero (como en Windows).
    func visibleItems(showHidden: Bool) -> [FileItem] {
        if let cache = visibleCache, cache.showHidden == showHidden { return cache.list }
        let list = computeVisibleItems(showHidden: showHidden)
        visibleCache = (showHidden, list)
        return list
    }

    private func computeVisibleItems(showHidden: Bool) -> [FileItem] {
        var list = searchResults ?? items
        if !showHidden { list = list.filter { !$0.isHidden } }
        let folders = list.filter(\.isDirectory).sorted(using: sortOrder)
        let files = list.filter { !$0.isDirectory }.sorted(using: sortOrder)
        let ordered = folders + files
        guard groupBy != .none else { return ordered }
        // Por grupo, conservando el orden elegido dentro de cada uno.
        let grouping = groupBy
        return ordered.enumerated()
            .map { (index: $0.offset, item: $0.element, group: grouping.group(of: $0.element)) }
            .sorted { a, b in
                if a.group.rank != b.group.rank { return a.group.rank < b.group.rank }
                if a.group.title != b.group.title {
                    return a.group.title.localizedStandardCompare(b.group.title) == .orderedAscending
                }
                return a.index < b.index
            }
            .map(\.item)
    }

    /// Los elementos visibles partidos en grupos consecutivos.
    func groups(_ list: [FileItem]) -> [ItemGroup] {
        var result: [ItemGroup] = []
        var title: String?
        var current: [FileItem] = []
        for item in list {
            let next = groupBy.group(of: item).title
            if next != title, let title {
                result.append(ItemGroup(title: title, items: current))
                current = []
            }
            title = next
            current.append(item)
        }
        if let title { result.append(ItemGroup(title: title, items: current)) }
        return result
    }

    // MARK: Búsqueda en subcarpetas

    /// Busca por nombre en esta carpeta y en todas sus subcarpetas, como el buscador del Explorador.
    /// Empieza un instante después de dejar de escribir; los resultados aparecen por tandas.
    private func scheduleSearch() {
        searchToken += 1
        let token = searchToken
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !isThisPC else {
            searchResults = nil
            isSearching = false
            searchTruncated = false
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.searchToken == token else { return }
            self.startSearch(query, token: token)
        }
    }

    private func startSearch(_ query: String, token: Int) {
        let root = url
        let includeHidden = Preferences.shared.showHidden
        let matches: (String) -> Bool = { name in
            name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        // Lo de la carpeta actual aparece al instante; lo de las subcarpetas, al ir encontrándolo.
        searchResults = items.filter { matches($0.name) }
        isSearching = true
        searchTruncated = false
        debugLog("buscar «\(query)» en \(root.path)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
            if !includeHidden { options.insert(.skipsHiddenFiles) }
            let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: FileItem.resourceKeys,
                                                        options: options) { _, _ in true }
            var found: [FileItem] = []
            var pending: [FileItem] = []
            var lastPublish = Date()
            var scanned = 0
            var truncated = false
            let alive: () -> Bool = { [weak self] in
                var current = false
                DispatchQueue.main.sync { current = self?.searchToken == token }
                return current
            }
            while let next = walker?.nextObject() as? URL {
                scanned += 1
                if scanned % 2000 == 0, !alive() { return }
                // Lo de la carpeta actual ya está; solo se agregan subcarpetas.
                guard next.deletingLastPathComponent().standardizedFileURL != root.standardizedFileURL,
                      matches(next.lastPathComponent), let item = FileItem(url: next) else { continue }
                found.append(item)
                pending.append(item)
                if found.count >= Self.searchLimit { truncated = true; break }
                if Date().timeIntervalSince(lastPublish) > 0.3 {
                    let batch = pending
                    pending = []
                    lastPublish = Date()
                    DispatchQueue.main.async {
                        guard let self, self.searchToken == token else { return }
                        self.searchResults = (self.searchResults ?? []) + batch
                    }
                }
            }
            let batch = pending
            DispatchQueue.main.async {
                guard let self, self.searchToken == token else { return }
                self.searchResults = (self.searchResults ?? []) + batch
                self.isSearching = false
                self.searchTruncated = truncated
                debugLog("búsqueda terminada: \(self.searchResults?.count ?? 0) resultados, \(scanned) revisados")
            }
        }
    }

    /// Carpeta donde está un resultado, relativa a la carpeta donde se busca («Proyectos/2024»).
    func searchLocation(of item: FileItem) -> String? {
        guard searchResults != nil else { return nil }
        let parent = item.url.deletingLastPathComponent().standardizedFileURL.path
        let root = url.standardizedFileURL.path
        if parent == root { return nil }
        return parent.hasPrefix(root + "/") ? String(parent.dropFirst(root.count + 1)) : parent
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
    /// Todas las ventanas abiertas.
    private static let all = NSHashTable<AppState>.weakObjects()

    let prefs = Preferences.shared

    @Published var tabs: [ExplorerTab] = []
    @Published var selectedTabID: UUID?

    // Diálogos
    @Published var alertMessage: String?
    /// Cambio de nombre en la misma lista (F2), como en Windows.
    let rename = RenameController()
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
        AppState.all.add(self)
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
        debugLog("vista: \(mode.rawValue)")
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
        // Saca de la unidad a todas las pestañas de todas las ventanas: si alguna la tiene abierta,
        // macOS se niega a expulsarla.
        let prefix = url.path.hasSuffix("/") ? url.path : url.path + "/"
        for state in AppState.all.allObjects {
            for tab in state.tabs where tab.url.isFileURL && (tab.url.path == url.path || tab.url.path.hasPrefix(prefix)) {
                tab.navigate(to: Locations.thisPC)
            }
        }
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

    private func run(_ work: @escaping () throws -> [URL]?, undo: (([URL]) -> UndoRecord?)? = nil,
                     then: (([URL]) -> Void)? = nil) {
        let tab = currentTab
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try work()
                DispatchQueue.main.async {
                    tab.reload()
                    if let result, !result.isEmpty, let record = undo?(result) { UndoHistory.shared.record(record) }
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
        if tab.selection.isEmpty { return [] }
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
        transfer(cut ? .move : .copy, urls, to: currentTab.url) {
            if cut { FileClipboard.shared.clearAfterCut() }
        }
    }

    /// Copia o mueve con ventana de progreso; queda registrado para deshacer.
    func transfer(_ kind: TransferJob.Kind, _ urls: [URL], to folder: URL, then: (() -> Void)? = nil) {
        guard !urls.isEmpty, folder.isFileURL else { return }
        let tab = currentTab
        TransferCenter.shared.start(kind, urls, to: folder) { [weak self] pairs, error in
            tab.reload()
            if !pairs.isEmpty {
                UndoHistory.shared.record(kind == .copy ? .copied(pairs) : .moved(pairs))
                if tab.url.standardizedFileURL == folder.standardizedFileURL {
                    tab.selection = Set(pairs.map { $0.to.standardizedFileURL })
                }
            }
            if let error { self?.alertMessage = error.localizedDescription }
            then?()
        }
    }

    /// Archivos soltados en una carpeta: dentro del mismo disco se mueven y entre discos se copian,
    /// como en Windows. Con Opción (⌥) presionada siempre se copian.
    func drop(_ urls: [URL], into folder: URL, forceCopy: Bool) {
        let target = folder.standardizedFileURL
        let list = urls.map(\.standardizedFileURL).filter { url in
            url != target && url.deletingLastPathComponent() != target && !TransferEngine.isInside(target, url)
        }
        guard !list.isEmpty, AppState.isFolder(target) else { return }
        let sameVolume = list.allSatisfy { TransferEngine.volumeID($0) == TransferEngine.volumeID(target) }
        transfer(forceCopy || !sameVolume ? .copy : .move, list, to: target)
    }

    /// «Pegar acceso directo»: crea alias de lo copiado en la carpeta actual.
    func pasteShortcut() {
        guard canWriteHere else { return }
        let urls = FileClipboard.shared.current().urls
        guard !urls.isEmpty else { return }
        let folder = currentTab.url
        run({ try FileOperations.makeShortcuts(urls, in: folder) }, undo: { .created($0) }, then: { [weak self] created in
            self?.currentTab.selection = Set(created)
        })
    }

    func createShortcut(_ urls: [URL]) {
        guard let folder = urls.first?.deletingLastPathComponent() else { return }
        run({ try FileOperations.makeShortcuts(urls, in: folder) }, undo: { .created($0) }, then: { [weak self] created in
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
        var pairs: [(original: URL, inTrash: URL)] = []
        run({
            for url in urls {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                if let inTrash = resulting as URL? { pairs.append((url, inTrash)) }
            }
            return pairs.map(\.original)
        }, undo: { _ in .trashed(pairs) })
    }

    func askDeletePermanently(_ urls: [URL]) {
        if !urls.isEmpty { confirmPermanentDelete = urls }
    }

    func deletePermanently(_ urls: [URL]) {
        run({ try FileOperations.deletePermanently(urls); return nil })
    }

    func duplicate(_ urls: [URL]) {
        guard let folder = urls.first?.deletingLastPathComponent() else { return }
        transfer(.copy, urls, to: folder)
    }

    func copy(_ urls: [URL], to folder: URL) {
        transfer(.copy, urls, to: folder)
    }

    func move(_ urls: [URL], to folder: URL) {
        transfer(.move, urls, to: folder)
    }

    // MARK: Deshacer

    func undo() {
        guard UndoHistory.shared.canUndo else { NSSound.beep(); return }
        UndoHistory.shared.undo { [weak self] urls, error in self?.afterUndo(urls, error) }
    }

    func redo() {
        guard UndoHistory.shared.canRedo else { NSSound.beep(); return }
        UndoHistory.shared.redo { [weak self] urls, error in self?.afterUndo(urls, error) }
    }

    private func afterUndo(_ urls: [URL], _ error: Error?) {
        let tab = currentTab
        tab.reload()
        let here = Set(urls.map(\.standardizedFileURL)).filter { $0.deletingLastPathComponent() == tab.url.standardizedFileURL }
        if !here.isEmpty { tab.selection = here }
        if let error { alertMessage = error.localizedDescription }
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
        run({ [try FileOperations.newFolder(in: folder)] }, undo: { .created($0) }, then: { [weak self] created in
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
            undo: { .created($0) }, then: { [weak self] created in
                self?.currentTab.selection = Set(created)
                if let url = created.first { self?.beginRename(url) }
            })
    }

    func compress(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        run({ [try FileOperations.compress(urls)] }, undo: { .created($0) }, then: { [weak self] created in
            self?.currentTab.selection = Set(created)
        })
    }

    func extract(_ zip: URL) {
        run({ [try FileOperations.extract(zip)] }, undo: { .created($0) }, then: { [weak self] created in
            self?.currentTab.selection = Set(created)
        })
    }

    func beginRename(_ url: URL? = nil) {
        guard let target = url ?? selectedURLs.first, !currentTab.isThisPC else { return }
        rename.text = target.lastPathComponent
        rename.target = target.standardizedFileURL
        currentTab.scrollTarget = target.standardizedFileURL
    }

    func cancelRename() {
        rename.target = nil
        focusFileList(in: window)
    }

    func commitRename() {
        guard let target = rename.target else { return }
        let newName = rename.text
        rename.target = nil
        focusFileList(in: window)
        guard newName != target.lastPathComponent else { return }
        run({ [try FileOperations.rename(target, to: newName)] },
            undo: { renamed in renamed.first.flatMap { $0 == target ? nil : .renamed(from: target, to: $0) } }, then: { [weak self] renamed in
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

    /// Flechas del teclado: mueve la selección (Mayús la extiende desde el ancla).
    func moveSelection(dx: Int, dy: Int, extend: Bool) {
        let tab = currentTab
        let items = tab.visibleItems(showHidden: prefs.showHidden)
        guard !items.isEmpty else { return }
        let step = dx + dy * max(1, tab.columnsHint)
        let currentIndex = items.lastIndex { tab.selection.contains($0.url) }
        let target: Int
        if let currentIndex {
            target = min(items.count - 1, max(0, currentIndex + step))
        } else {
            target = step >= 0 ? 0 : items.count - 1
        }
        let url = items[target].url
        if extend, let anchor = tab.anchor, let a = items.firstIndex(where: { $0.url == anchor }) {
            tab.selection = Set(items[min(a, target)...max(a, target)].map(\.url))
        } else {
            tab.selection = [url]
            tab.anchor = url
        }
        tab.scrollTarget = url
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
