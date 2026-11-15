import AppKit

/// Operaciones con archivos: copiar, mover, papelera, renombrar y nueva carpeta.
/// Todas se ejecutan fuera del hilo principal para no congelar la ventana.
enum FileOperations {
    enum OperationError: LocalizedError {
        case invalidName
        case alreadyExists(String)
        case intoItself(String)

        var errorDescription: String? {
            switch self {
            case .invalidName:
                return "El nombre no es válido. No puede estar vacío ni contener «/» o «:»."
            case .alreadyExists(let name):
                return "Ya existe un elemento llamado «\(name)» en esta carpeta."
            case .intoItself(let name):
                return "No se puede copiar ni mover «\(name)» dentro de sí misma."
            }
        }
    }

    /// Nombre libre en la carpeta de destino, como en Windows:
    /// «Informe - copia.pdf», «Informe - copia (2).pdf»...
    static func uniqueURL(for name: String, in folder: URL, copySuffix: Bool) -> URL {
        let fm = FileManager.default
        let candidate = folder.appendingPathComponent(name)
        if !fm.fileExists(atPath: candidate.path) { return candidate }

        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        let dotExt = ext.isEmpty ? "" : ".\(ext)"
        var index = 1
        while true {
            let label: String
            if copySuffix {
                label = index == 1 ? "\(base) - copia" : "\(base) - copia (\(index))"
            } else {
                label = "\(base) (\(index + 1))"
            }
            let url = folder.appendingPathComponent(label + dotExt)
            if !fm.fileExists(atPath: url.path) { return url }
            index += 1
        }
    }

    static func validate(name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..",
              !trimmed.contains("/"), !trimmed.contains(":") else {
            throw OperationError.invalidName
        }
        return trimmed
    }

    private static func isInside(_ child: URL, _ parent: URL) -> Bool {
        let c = child.standardizedFileURL.path
        let p = parent.standardizedFileURL.path
        return c == p || c.hasPrefix(p.hasSuffix("/") ? p : p + "/")
    }

    /// Copia los elementos en la carpeta. Si el destino es la misma carpeta, crea «- copia».
    static func copy(_ urls: [URL], to folder: URL) throws -> [URL] {
        let fm = FileManager.default
        var created: [URL] = []
        for url in urls {
            if isInside(folder, url) { throw OperationError.intoItself(url.lastPathComponent) }
            let target = uniqueURL(for: url.lastPathComponent, in: folder, copySuffix: true)
            try fm.copyItem(at: url, to: target)
            created.append(target)
        }
        return created
    }

    /// Mueve los elementos a la carpeta. Si ya están ahí, no hace nada.
    static func move(_ urls: [URL], to folder: URL) throws -> [URL] {
        let fm = FileManager.default
        var moved: [URL] = []
        for url in urls {
            if url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL {
                moved.append(url)
                continue
            }
            if isInside(folder, url) { throw OperationError.intoItself(url.lastPathComponent) }
            let target = uniqueURL(for: url.lastPathComponent, in: folder, copySuffix: false)
            try fm.moveItem(at: url, to: target)
            moved.append(target)
        }
        return moved
    }

    /// Envía los elementos a la Papelera (la Papelera de reciclaje de Windows).
    static func trash(_ urls: [URL]) throws {
        for url in urls {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    static func rename(_ url: URL, to newName: String) throws -> URL {
        let name = try validate(name: newName)
        if name == url.lastPathComponent { return url }
        let target = url.deletingLastPathComponent().appendingPathComponent(name)
        // Permite cambiar solo mayúsculas/minúsculas en discos que no las distinguen.
        let sameIgnoringCase = name.lowercased() == url.lastPathComponent.lowercased()
        if FileManager.default.fileExists(atPath: target.path) && !sameIgnoringCase {
            throw OperationError.alreadyExists(name)
        }
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    static func newFolder(in folder: URL) throws -> URL {
        let target = uniqueURL(for: "Nueva carpeta", in: folder, copySuffix: false)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        return target
    }

    static func newTextDocument(in folder: URL) throws -> URL {
        let target = uniqueURL(for: "Nuevo documento de texto.txt", in: folder, copySuffix: false)
        guard FileManager.default.createFile(atPath: target.path, contents: Data()) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return target
    }

    static func newRichTextDocument(in folder: URL) throws -> URL {
        let target = uniqueURL(for: "Nuevo documento de texto enriquecido.rtf", in: folder, copySuffix: false)
        let rtf = "{\\rtf1\\ansi\\deff0 {\\fonttbl {\\f0 Helvetica;}}\\f0\\fs24 }"
        guard FileManager.default.createFile(atPath: target.path, contents: Data(rtf.utf8)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return target
    }

    /// Elimina sin pasar por la Papelera (Mayús+Supr en Windows).
    static func deletePermanently(_ urls: [URL]) throws {
        for url in urls {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Crea un acceso directo (alias de Finder) de cada elemento en la carpeta.
    static func makeShortcuts(_ urls: [URL], in folder: URL) throws -> [URL] {
        var created: [URL] = []
        for url in urls {
            let data = try url.bookmarkData(options: .suitableForBookmarkFile,
                                            includingResourceValuesForKeys: nil, relativeTo: nil)
            let target = uniqueURL(for: "\(url.lastPathComponent) - acceso directo", in: folder, copySuffix: false)
            try URL.writeBookmarkData(data, to: target)
            created.append(target)
        }
        return created
    }

    /// Comprime en ZIP. Con un elemento, el ZIP se llama como él; con varios, como el primero.
    static func compress(_ urls: [URL]) throws -> URL {
        guard let first = urls.first else { throw CocoaError(.fileNoSuchFile) }
        let folder = first.deletingLastPathComponent()
        let firstIsFolder = (try? first.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let base = urls.count == 1 && !firstIsFolder
            ? (first.lastPathComponent as NSString).deletingPathExtension
            : first.lastPathComponent
        let target = uniqueURL(for: "\(base).zip", in: folder, copySuffix: false)
        try run("/usr/bin/zip", ["-r", "-y", "-q", "./" + target.lastPathComponent] + urls.map { "./" + $0.lastPathComponent },
                in: folder)
        return target
    }

    /// «Extraer todo»: descomprime el ZIP en una carpeta con su nombre.
    static func extract(_ zip: URL) throws -> URL {
        let folder = zip.deletingLastPathComponent()
        let name = (zip.lastPathComponent as NSString).deletingPathExtension
        let target = uniqueURL(for: name, in: folder, copySuffix: false)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, target.path], in: folder)
        return target
    }

    /// «Nueva carpeta con la selección» de Finder.
    static func newFolder(with urls: [URL], in folder: URL) throws -> URL {
        let target = uniqueURL(for: "Nueva carpeta con elementos", in: folder, copySuffix: false)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        _ = try move(urls, to: target)
        return target
    }

    static func setHidden(_ hidden: Bool, for urls: [URL]) throws {
        for url in urls {
            try (url as NSURL).setResourceValue(hidden, forKey: .isHiddenKey)
        }
    }

    static func setLocked(_ locked: Bool, for urls: [URL]) throws {
        for url in urls {
            try (url as NSURL).setResourceValue(locked, forKey: .isUserImmutableKey)
        }
    }

    static func setTags(_ tags: [String], for url: URL) throws {
        try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
    }

    /// Tamaño total, tamaño en disco, archivos y carpetas (para Propiedades).
    struct SizeInfo {
        var bytes: Int64 = 0
        var onDisk: Int64 = 0
        var files = 0
        var folders = 0
    }

    static func measure(_ urls: [URL], isCancelled: () -> Bool = { false }) -> SizeInfo {
        var info = SizeInfo()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .totalFileAllocatedSizeKey]
        func add(_ url: URL) {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return }
            info.bytes += Int64(v.fileSize ?? 0)
            info.onDisk += Int64(v.totalFileAllocatedSize ?? 0)
        }
        for url in urls {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isDir {
                info.files += 1
                add(url)
                continue
            }
            guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { continue }
            for case let child as URL in walker {
                if isCancelled() { return info }
                let childIsDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if childIsDir { info.folders += 1 } else { info.files += 1; add(child) }
            }
        }
        return info
    }

    private static func run(_ tool: String, _ arguments: [String], in folder: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = folder
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "PegasusExplorer", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "No se pudo completar la operación. \(message)"])
        }
    }
}

/// Portapapeles de archivos. Comparte el portapapeles del sistema para que
/// copiar en Finder y pegar aquí (o al revés) también funcione.
final class FileClipboard {
    static let shared = FileClipboard()

    private(set) var urls: [URL] = []
    private(set) var isCut = false
    private var changeCount = -1
    private var external: [URL] = []
    private var externalCount = -1

    func set(_ urls: [URL], cut: Bool) {
        self.urls = urls
        isCut = cut
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        changeCount = pb.changeCount
    }

    /// Lo que se pegaría ahora: lo nuestro, o archivos copiados en otra app.
    func current() -> (urls: [URL], cut: Bool) {
        let pb = NSPasteboard.general
        if pb.changeCount == changeCount { return (urls, isCut) }
        // Solo se vuelve a leer el portapapeles cuando cambió (se consulta en cada redibujado).
        if pb.changeCount != externalCount {
            external = pb.readObjects(forClasses: [NSURL.self],
                                      options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            externalCount = pb.changeCount
        }
        return (external, false)
    }

    var hasContent: Bool { !current().urls.isEmpty }

    func clearAfterCut() {
        if isCut {
            urls = []
            isCut = false
        }
    }
}
