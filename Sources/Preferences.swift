import AppKit
import UniformTypeIdentifiers

/// Ajustes compartidos por todas las ventanas (se guardan entre sesiones).
final class Preferences: ObservableObject {
    static let shared = Preferences()

    @Published var showHidden: Bool { didSet { save(showHidden, "showHidden") } }
    @Published var showExtensions: Bool { didSet { save(showExtensions, "showExtensions") } }
    @Published var showNavigationPane: Bool { didSet { save(showNavigationPane, "showNavigationPane") } }
    @Published var showPreviewPane: Bool { didSet { save(showPreviewPane, "showPreviewPane") } }
    @Published var showRibbon: Bool { didSet { save(showRibbon, "showRibbon") } }
    @Published var pinned: [URL] {
        didSet { UserDefaults.standard.set(pinned.map(\.path), forKey: "pinnedFolders") }
    }
    @Published var savedShares: [NetworkShares.Saved] {
        didSet {
            if let data = try? JSONEncoder().encode(savedShares) {
                UserDefaults.standard.set(data, forKey: "savedShares")
            }
        }
    }
    @Published private(set) var volumes: [Volume] = []

    private var observers: [NSObjectProtocol] = []

    private init() {
        let d = UserDefaults.standard
        showHidden = d.bool(forKey: "showHidden")
        showExtensions = d.object(forKey: "showExtensions") as? Bool ?? true
        showNavigationPane = d.object(forKey: "showNavigationPane") as? Bool ?? true
        showPreviewPane = d.bool(forKey: "showPreviewPane")
        showRibbon = d.object(forKey: "showRibbon") as? Bool ?? true
        if let paths = d.stringArray(forKey: "pinnedFolders") {
            pinned = paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        } else {
            pinned = [KnownFolder.desktop, .downloads, .documents, .pictures].map(\.url)
        }
        if let data = d.data(forKey: "savedShares"),
           let list = try? JSONDecoder().decode([NetworkShares.Saved].self, from: data) {
            savedShares = list
        } else {
            savedShares = []
        }
        refreshVolumes()

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshVolumes()
            })
        }
    }

    private func save(_ value: Bool, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    func refreshVolumes() {
        volumes = Volume.mounted()
    }

    var localVolumes: [Volume] { volumes.filter { !$0.isNetwork } }
    var networkVolumes: [Volume] { volumes.filter(\.isNetwork) }

    /// Recursos de red guardados que ahora no están montados.
    var disconnectedShares: [NetworkShares.Saved] {
        savedShares.filter { share in
            guard let parsed = NetworkShares.parse(share.address) else { return true }
            return NetworkShares.mountedPath(for: parsed.share) == nil
        }
    }

    // MARK: Acceso rápido

    func isPinned(_ url: URL) -> Bool {
        pinned.contains { $0.standardizedFileURL == url.standardizedFileURL }
    }

    func togglePin(_ url: URL) {
        if isPinned(url) {
            pinned.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        } else {
            pinned.append(url)
        }
    }

    func forget(_ share: NetworkShares.Saved) {
        savedShares.removeAll { $0.address == share.address }
    }

    func remember(_ address: String) {
        guard !savedShares.contains(where: { $0.address == address }) else { return }
        savedShares.append(.init(name: NetworkShares.displayName(for: address), address: address))
    }

    // MARK: Explorador predeterminado

    /// ¿Esta app es la que abre las carpetas en el sistema?
    var isDefaultFolderHandler: Bool {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: .folder) else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    func setAsDefaultFolderHandler(_ enable: Bool, completion: @escaping (Error?) -> Void) {
        let app = enable
            ? Bundle.main.bundleURL
            : URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        NSWorkspace.shared.setDefaultApplication(at: app, toOpen: .folder) { error in
            DispatchQueue.main.async {
                self.objectWillChange.send()
                completion(error)
            }
        }
    }
}
