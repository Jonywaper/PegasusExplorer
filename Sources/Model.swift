import AppKit

/// Dirección especial para la página «Este equipo».
enum Locations {
    static let thisPC = URL(string: "pegasus://este-equipo")!
    static func isThisPC(_ url: URL) -> Bool { url.scheme == "pegasus" }
}

/// Un archivo o carpeta mostrado en la lista.
struct FileItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let isApplication: Bool
    let isHidden: Bool
    let size: Int64?
    let modified: Date?
    let kind: String
    let tags: [String]

    var id: URL { url }

    static let resourceKeys: [URLResourceKey] = [
        .nameKey, .isDirectoryKey, .isPackageKey, .isApplicationKey, .isHiddenKey,
        .fileSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey, .tagNamesKey,
    ]

    init?(url: URL) {
        guard let v = try? url.resourceValues(forKeys: Set(FileItem.resourceKeys)) else { return nil }
        self.url = url
        name = v.name ?? url.lastPathComponent
        // Las apps (.app) y otros paquetes se tratan como archivos, como en Finder.
        isPackage = v.isPackage ?? false
        isApplication = v.isApplication ?? false
        isDirectory = (v.isDirectory ?? false) && !isPackage
        isHidden = (v.isHidden ?? false) || name.hasPrefix(".")
        size = isDirectory ? nil : v.fileSize.map { Int64($0) }
        modified = v.contentModificationDate
        kind = isDirectory ? "Carpeta de archivos" : (v.localizedTypeDescription ?? "Archivo")
        tags = v.tagNames ?? []
    }

    /// Nombre a mostrar, con o sin extensión (opción «Extensiones de nombre de archivo»).
    func displayName(showExtensions: Bool) -> String {
        if showExtensions || isDirectory || name.hasPrefix(".") { return name }
        let ext = (name as NSString).pathExtension
        if ext.isEmpty { return name }
        return (name as NSString).deletingPathExtension
    }

    var isZip: Bool { url.pathExtension.lowercased() == "zip" }

    // Valores usados para ordenar las columnas.
    var sortDate: Date { modified ?? .distantPast }
    var sortSize: Int64 { size ?? -1 }
}

enum Format {
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private static let longDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .medium
        return f
    }()

    static func date(_ date: Date?) -> String {
        guard let date else { return "" }
        return dateFormatter.string(from: date)
    }

    static func longDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        return longDateFormatter.string(from: date)
    }

    /// Tamaño en KB, como lo muestra el Explorador de Windows en la vista Detalles.
    static func size(_ bytes: Int64?) -> String {
        guard let bytes else { return "" }
        let kb = (bytes + 1023) / 1024
        return "\(number(kb)) KB"
    }

    /// «20 s», «3 min», «1 h 5 min».
    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        return "\(s / 3600) h \(s % 3600 / 60) min"
    }

    static func bytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// En unidades de 1024, como muestra Google su almacenamiento («15 GB»).
    static func bytesBinary(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }

    /// «1,25 MB (1.310.720 bytes)», como en Propiedades de Windows.
    static func bytesLong(_ value: Int64) -> String {
        "\(bytes(value)) (\(number(value)) bytes)"
    }

    static func number(_ value: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

/// Íconos del sistema, guardados en memoria para no pedirlos cada vez.
final class IconCache {
    static let shared = IconCache()
    private let cache = NSCache<NSString, NSImage>()

    func icon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(image, forKey: key)
        return image
    }
}

/// Carpetas conocidas, con los nombres que usa Windows.
enum KnownFolder: CaseIterable {
    case desktop, documents, downloads, pictures, music, videos

    var title: String {
        switch self {
        case .desktop: return "Escritorio"
        case .downloads: return "Descargas"
        case .documents: return "Documentos"
        case .pictures: return "Imágenes"
        case .music: return "Música"
        case .videos: return "Videos"
        }
    }

    var symbol: String {
        switch self {
        case .desktop: return "menubar.dock.rectangle"
        case .downloads: return "arrow.down.circle.fill"
        case .documents: return "doc.text.fill"
        case .pictures: return "photo.fill"
        case .music: return "music.note"
        case .videos: return "film.fill"
        }
    }

    /// Las rutas se calculan una sola vez (se consultan muchas veces al dibujar).
    private static let urls: [KnownFolder: URL] = Dictionary(
        uniqueKeysWithValues: allCases.map { ($0, $0.resolveURL().standardizedFileURL) })

    var url: URL { KnownFolder.urls[self] ?? FileManager.default.homeDirectoryForCurrentUser }

    private func resolveURL() -> URL {
        let fm = FileManager.default
        let dir: FileManager.SearchPathDirectory
        switch self {
        case .desktop: dir = .desktopDirectory
        case .downloads: dir = .downloadsDirectory
        case .documents: dir = .documentDirectory
        case .pictures: dir = .picturesDirectory
        case .music: dir = .musicDirectory
        case .videos: dir = .moviesDirectory
        }
        return fm.urls(for: dir, in: .userDomainMask).first ?? fm.homeDirectoryForCurrentUser
    }

    static func matching(_ url: URL) -> KnownFolder? {
        let target = url.standardizedFileURL
        return allCases.first { $0.url == target }
    }
}

/// Un disco o unidad montada (local, externa o de red).
struct Volume: Identifiable, Hashable {
    let url: URL
    let name: String
    let isRoot: Bool
    let isNetwork: Bool
    let isEjectable: Bool
    let totalBytes: Int64?
    let freeBytes: Int64?
    let format: String?

    var id: URL { url }

    var usedFraction: Double {
        guard let total = totalBytes, let free = freeBytes, total > 0 else { return 0 }
        return Double(total - free) / Double(total)
    }

    static func mounted() -> [Volume] {
        let keys: [URLResourceKey] = [
            .volumeLocalizedNameKey, .volumeIsLocalKey, .volumeIsEjectableKey,
            .volumeIsRemovableKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey, .volumeLocalizedFormatDescriptionKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let isRoot = url.path == "/"
            let baseName = v.volumeLocalizedName ?? url.lastPathComponent
            let isNetwork = !(v.volumeIsLocal ?? true)
            // «Important usage» solo vale para discos locales: en unidades de red macOS devuelve 0.
            let important = isNetwork ? nil : v.volumeAvailableCapacityForImportantUsage.flatMap { $0 > 0 ? $0 : nil }
            let free = important ?? v.volumeAvailableCapacity.map { Int64($0) }
            return Volume(
                url: url,
                name: isRoot ? "Disco local (\(baseName))" : baseName,
                isRoot: isRoot,
                isNetwork: isNetwork,
                isEjectable: !isRoot && ((v.volumeIsEjectable ?? false) || (v.volumeIsRemovable ?? false) || isNetwork),
                totalBytes: v.volumeTotalCapacity.map { Int64($0) },
                freeBytes: free,
                format: v.volumeLocalizedFormatDescription)
        }
        .sorted { a, b in
            if a.isRoot != b.isRoot { return a.isRoot }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// El volumen que contiene una ruta.
    static func containing(_ url: URL, in volumes: [Volume]) -> Volume? {
        let path = url.standardizedFileURL.path
        return volumes
            .filter { v in v.isRoot || path == v.url.path || path.hasPrefix(v.url.path.hasSuffix("/") ? v.url.path : v.url.path + "/") }
            .max { $0.url.path.count < $1.url.path.count }
    }
}

/// Etiquetas de color de Finder (con los nombres y colores que tenga configurados el usuario).
enum FinderTags {
    struct Tag: Hashable {
        let name: String
        let color: NSColor
    }

    static var all: [Tag] {
        let names = NSWorkspace.shared.fileLabels
        let colors = NSWorkspace.shared.fileLabelColors
        // El índice 0 es «Ninguno».
        return zip(names, colors).dropFirst().map { Tag(name: $0.0, color: $0.1) }
    }

    static func color(for name: String) -> NSColor? {
        all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.color
    }
}

/// Unidades en la nube (Google Drive, OneDrive, Dropbox, Box, iCloud Drive).
/// En Mac, cada cuenta aparece como una carpeta en ~/Library/CloudStorage.
struct CloudDrive: Identifiable, Hashable {
    let url: URL
    let name: String
    let provider: String
    var quota: CloudQuota?

    var id: URL { url }

    /// `withQuota: false` evita abrir la base de datos de Google Drive (para no esperar en pantalla).
    static func detect(withQuota: Bool = true) -> [CloudDrive] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let storage = home.appendingPathComponent("Library/CloudStorage")
        var drives: [CloudDrive] = []

        let entries = (try? fm.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil,
                                                   options: [.skipsHiddenFiles])) ?? []
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let folder = url.lastPathComponent
            let (provider, account) = split(folder)
            let name: String
            switch provider {
            case "GoogleDrive": name = account.isEmpty ? "Google Drive" : "Google Drive (\(account))"
            case "OneDrive": name = account.isEmpty ? "OneDrive" : "OneDrive - \(account)"
            case "Dropbox": name = account.isEmpty ? "Dropbox" : "Dropbox (\(account))"
            case "Box": name = account.isEmpty ? "Box" : "Box (\(account))"
            default: name = folder.replacingOccurrences(of: "-", with: " - ")
            }
            let quota = withQuota && provider == "GoogleDrive" ? GoogleDriveQuota.quota(forEmail: account) : nil
            drives.append(CloudDrive(url: url.standardizedFileURL, name: name, provider: provider, quota: quota))
        }

        let icloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if fm.fileExists(atPath: icloud.path) {
            drives.append(CloudDrive(url: icloud.standardizedFileURL, name: "iCloud Drive", provider: "iCloud"))
        }
        return drives
    }

    /// «GoogleDrive-correo@gmail.com» → ("GoogleDrive", "correo@gmail.com").
    private static func split(_ folder: String) -> (String, String) {
        guard let dash = folder.firstIndex(of: "-") else { return (folder, "") }
        return (String(folder[..<dash]), String(folder[folder.index(after: dash)...]))
    }

    var symbol: String { provider == "iCloud" ? "icloud.fill" : "cloud.fill" }

    /// La unidad en la nube que contiene una ruta.
    static func containing(_ url: URL, in drives: [CloudDrive]) -> CloudDrive? {
        let path = url.standardizedFileURL.path
        return drives.first { path == $0.url.path || path.hasPrefix($0.url.path + "/") }
    }
}
