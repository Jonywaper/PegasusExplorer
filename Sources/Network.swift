import Foundation
import NetFS

/// Conexión a carpetas compartidas de red (SMB, AFP, NFS, FTP, WebDAV).
/// macOS se encarga de pedir usuario y contraseña y de guardarlos en el llavero,
/// así que la app nunca ve tu contraseña.
enum NetworkShares {
    struct Saved: Codable, Hashable, Identifiable {
        var name: String
        var address: String
        var id: String { address }
    }

    enum ConnectError: LocalizedError {
        case invalidAddress(String)
        case failed(Int32)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .invalidAddress(let text):
                return "«\(text)» no es una dirección de red válida. Usa, por ejemplo, \\\\servidor\\carpeta o smb://servidor/carpeta."
            case .cancelled:
                return "Se canceló la conexión."
            case .failed(let code):
                let detail = String(cString: strerror(code))
                return "No se pudo conectar al servidor (\(code): \(detail)). Revisa la dirección, la red y tus credenciales."
            }
        }
    }

    static let supportedSchemes: Set<String> = ["smb", "cifs", "afp", "nfs", "ftp", "http", "https", "webdav", "davs"]

    /// ¿El texto escrito en la barra de direcciones es una ruta de red?
    static func isNetworkAddress(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("\\\\") || t.hasPrefix("//") { return true }
        if let scheme = URL(string: t)?.scheme?.lowercased() { return supportedSchemes.contains(scheme) }
        return false
    }

    /// Convierte «\\servidor\carpeta\sub» o «smb://servidor/carpeta/sub» en
    /// (dirección del recurso compartido, subcarpeta dentro de él).
    static func parse(_ text: String) -> (share: URL, subpath: [String])? {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("\\\\") || t.hasPrefix("//") {
            t = "smb://" + t.dropFirst(2).replacingOccurrences(of: "\\", with: "/")
        }
        guard let url = URL(string: t.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? t)
                ?? URL(string: t),
              var scheme = url.scheme?.lowercased(), supportedSchemes.contains(scheme),
              let host = url.host, !host.isEmpty else { return nil }
        if scheme == "cifs" { scheme = "smb" }
        if scheme == "webdav" { scheme = "http" }
        if scheme == "davs" { scheme = "https" }

        let parts = url.path.split(separator: "/").map(String.init)
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        components.user = url.user
        // SMB y AFP montan un recurso compartido (la primera carpeta); lo demás va dentro.
        let mountsWholePath = !(scheme == "smb" || scheme == "afp")
        if let first = parts.first, !mountsWholePath {
            components.path = "/" + first
            guard let share = components.url else { return nil }
            return (share, Array(parts.dropFirst()))
        }
        components.path = parts.isEmpty ? "" : "/" + parts.joined(separator: "/")
        guard let share = components.url else { return nil }
        return (share, [])
    }

    /// Busca si ese recurso compartido ya está montado.
    static func mountedPath(for share: URL) -> URL? {
        let keys: [URLResourceKey] = [.volumeURLForRemountingKey]
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: []) ?? []
        let wantHost = share.host?.lowercased()
        let wantPath = share.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        for volume in volumes {
            guard let remote = try? volume.resourceValues(forKeys: Set(keys)).volumeURLForRemounting,
                  remote.host?.lowercased() == wantHost else { continue }
            let path = (remote.path.removingPercentEncoding ?? remote.path)
                .lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let want = wantPath.removingPercentEncoding ?? wantPath
            if path == want || want.isEmpty { return volume }
        }
        return nil
    }

    /// Monta el recurso (o reutiliza el ya montado) y devuelve la carpeta local donde quedó.
    static func connect(_ text: String, completion: @escaping (Result<URL, Error>) -> Void) {
        guard let parsed = parse(text) else {
            completion(.failure(ConnectError.invalidAddress(text)))
            return
        }
        let finish: (URL) -> Void = { mountPoint in
            let target = parsed.subpath.reduce(mountPoint) { $0.appendingPathComponent($1) }
            completion(.success(target))
        }
        if let existing = mountedPath(for: parsed.share) {
            finish(existing)
            return
        }

        // Permite que macOS muestre su ventana de usuario y contraseña.
        let openOptions = NSMutableDictionary()
        openOptions["UIOption"] = "AllowUI"
        let mountOptions = NSMutableDictionary()
        var requestID: AsyncRequestID?

        let status = NetFSMountURLAsync(
            parsed.share as CFURL, nil, nil, nil,
            openOptions as CFMutableDictionary, mountOptions as CFMutableDictionary,
            &requestID, DispatchQueue.main
        ) { status, _, mountPoints in
            if status == 0, let points = mountPoints as? [String], let first = points.first {
                finish(URL(fileURLWithPath: first, isDirectory: true))
            } else if status == 17, let existing = mountedPath(for: parsed.share) {
                finish(existing) // EEXIST: ya estaba montado
            } else if status == -128 || status == Int32(ECANCELED) {
                completion(.failure(ConnectError.cancelled))
            } else {
                completion(.failure(ConnectError.failed(status)))
            }
        }
        if status != 0 {
            completion(.failure(ConnectError.failed(status)))
        }
    }

    /// Nombre corto para mostrar: «Proyectos (nas)».
    static func displayName(for text: String) -> String {
        guard let parsed = parse(text) else { return text }
        let share = parsed.share.lastPathComponent
        let host = parsed.share.host ?? ""
        return share.isEmpty || share == "/" ? host : "\(share) (\(host))"
    }
}
