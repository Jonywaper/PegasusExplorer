import AppKit

/// Revisa en GitHub si hay una versión nueva de PegasusExplorer y avisa.
/// Solo consulta la lista pública de versiones del repositorio; no envía ningún dato tuyo.
enum UpdateChecker {
    static let repository = "Jonywaper/PegasusExplorer"
    private static let lastCheckKey = "lastUpdateCheck"
    private static let skippedKey = "skippedUpdateVersion"
    static let autoCheckKey = "checkUpdatesAtLaunch"

    struct Release {
        let version: String
        let title: String
        let page: URL
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var autoCheckEnabled: Bool {
        get { UserDefaults.standard.object(forKey: autoCheckKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoCheckKey) }
    }

    /// Al abrir la app: como mucho una vez al día y solo si está activado.
    static func checkAtLaunch() {
        guard autoCheckEnabled, ProcessInfo.processInfo.environment["SE_SNAPSHOT"] == nil else { return }
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 24 * 3600 else { return }
        check(manual: false)
    }

    /// Menú «Buscar actualizaciones…»: siempre consulta y siempre responde.
    static func check(manual: Bool) {
        fetchLatest { result in
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
            switch result {
            case .success(let release?) where isNewer(release.version, than: currentVersion):
                if !manual && UserDefaults.standard.string(forKey: skippedKey) == release.version { return }
                showUpdate(release)
            case .success:
                if manual { showMessage("Tienes la versión más reciente", "PegasusExplorer \(currentVersion) está al día.") }
            case .failure:
                if manual { showMessage("No se pudo buscar actualizaciones", "Revisa tu conexión a internet e inténtalo de nuevo.") }
            }
        }
    }

    // MARK: GitHub

    private static func fetchLatest(completion: @escaping (Result<Release?, Error>) -> Void) {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=10")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("PegasusExplorer/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { data, _, error in
            let result: Result<Release?, Error>
            if let error {
                result = .failure(error)
            } else if let data,
                      let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                let releases = list.compactMap { item -> Release? in
                    guard (item["draft"] as? Bool) != true,
                          let tag = item["tag_name"] as? String,
                          let page = (item["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
                    let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                    return Release(version: version, title: item["name"] as? String ?? tag, page: page)
                }
                // La más nueva por número de versión (incluye las beta).
                let newest = releases.max { isNewer($1.version, than: $0.version) }
                result = .success(newest)
            } else {
                result = .failure(URLError(.cannotParseResponse))
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    /// Compara «0.9.10» con «0.9.2» número por número.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Avisos

    private static func showUpdate(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = "Hay una versión nueva de PegasusExplorer"
        alert.informativeText = "Está disponible la versión \(release.version). Tú tienes la \(currentVersion).\n\nDescárgala desde GitHub, abre el DMG y arrastra PegasusExplorer a Aplicaciones para reemplazar la anterior."
        alert.addButton(withTitle: "Descargar")
        alert.addButton(withTitle: "Más tarde")
        alert.addButton(withTitle: "Omitir esta versión")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: NSWorkspace.shared.open(release.page)
        case .alertThirdButtonReturn: UserDefaults.standard.set(release.version, forKey: skippedKey)
        default: break
        }
    }

    private static func showMessage(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "Aceptar")
        alert.runModal()
    }
}
