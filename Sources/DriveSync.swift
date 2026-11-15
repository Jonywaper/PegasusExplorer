import AppKit
import SQLite3
import SwiftUI

/// Estado de sincronización de las carpetas de la Mac que Google Drive respalda
/// («Mi computadora» en Google Drive para escritorio), como los íconos de OneDrive en Windows.
///
/// Lee, sin modificar nada, las bases de datos de Google Drive para escritorio:
/// - root_preference_sqlite.db → qué carpetas de la Mac se sincronizan.
/// - <cuenta>/mirror_sqlite.db → qué archivos ya están en la nube y cuáles faltan por subir.
final class DriveSync: ObservableObject {
    static let shared = DriveSync()

    enum Status {
        case synced, syncing, paused

        var symbol: String {
            switch self {
            case .synced: return "checkmark"
            case .syncing: return "arrow.triangle.2.circlepath"
            case .paused: return "pause.fill"
            }
        }

        var color: Color {
            switch self {
            case .synced: return Color(red: 0.13, green: 0.62, blue: 0.29)
            case .syncing: return Color(red: 0.15, green: 0.47, blue: 0.95)
            case .paused: return Color.gray
            }
        }

        var help: String {
            switch self {
            case .synced: return "Sincronizado con Google Drive"
            case .syncing: return "Sincronizando con Google Drive…"
            case .paused: return "Google Drive está cerrado: la sincronización está en pausa"
            }
        }
    }

    private struct Item {
        let parent: Int64
        let isFolder: Bool
        let inCloud: Bool
    }

    private struct Root {
        let path: String
        let localID: Int64
    }

    private struct Snapshot {
        var roots: [Root] = []
        var items: [Int64: Item] = [:]
        var children: [Int64: [String: Int64]] = [:]
        var busy: Set<Int64> = []
    }

    /// Cambia cada vez que hay datos nuevos (para que las vistas se redibujen).
    @Published private(set) var revision = 0
    private var snapshot = Snapshot()
    private var driveRunning = false
    private var lastChange: Date?
    private var loaded = false
    private var timer: Timer?
    private let queue = DispatchQueue(label: "DriveSync", qos: .utility)

    private init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    // MARK: Consulta

    /// ¿Es una de las carpetas que Google Drive sincroniza?
    func isSyncRoot(_ url: URL) -> Bool {
        let path = Self.normalize(url.standardizedFileURL.path)
        return snapshot.roots.contains { $0.path == path }
    }

    /// Estado de un archivo o carpeta, o nil si no está dentro de una carpeta sincronizada.
    func status(for url: URL) -> Status? {
        let path = Self.normalize(url.standardizedFileURL.path)
        guard let root = snapshot.roots.first(where: { path == $0.path || path.hasPrefix($0.path + "/") }) else {
            return nil
        }
        if !driveRunning { return .paused }

        // Baja desde la carpeta raíz siguiendo cada parte de la ruta.
        var current = root.localID
        let rest = path.dropFirst(root.path.count).split(separator: "/").map(String.init)
        for part in rest {
            guard let next = snapshot.children[current]?[Self.normalize(part)] else {
                // Todavía no está registrado: es nuevo y está por subirse.
                return part.hasPrefix(".") ? nil : .syncing
            }
            current = next
        }
        // «Sincronizando» solo si Google Drive lo tiene en su cola de subida.
        // (Los documentos de Google como .gdoc o .gsheet no tienen huella local y aun así están al día.)
        return snapshot.busy.contains(current) ? .syncing : .synced
    }

    // MARK: Lectura de Google Drive

    private func refresh() {
        let running = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.google.drivefs" }
        let previous = lastChange
        let wasLoaded = loaded
        queue.async { [weak self] in
            guard let self else { return }
            let base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Google/DriveFS")
            // Solo vuelve a leer si Google Drive cambió algo desde la última vez.
            let names = Self.accountFolders(in: base).map { $0.appendingPathComponent("mirror_sqlite.db") }
                + [base.appendingPathComponent("root_preference_sqlite.db")]
            let watched = names + names.map { URL(fileURLWithPath: $0.path + "-wal") }
            let newest = watched.compactMap {
                (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            }.max()
            let changed = !wasLoaded || newest != previous
            let snapshot = changed ? Self.load(base: base) : nil
            DispatchQueue.main.async {
                if let snapshot {
                    self.snapshot = snapshot
                    self.lastChange = newest
                    self.loaded = true
                }
                if changed || running != self.driveRunning {
                    self.driveRunning = running
                    self.revision += 1
                }
            }
        }
    }

    private static func accountFolders(in base: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.isEmpty && $0.lastPathComponent.allSatisfy(\.isNumber) }
    }

    private static func load(base: URL) -> Snapshot {
        var snapshot = Snapshot()
        // Carpetas sincronizadas: root_id, ruta y cuenta.
        var rootsByAccount: [String: [(rootID: Int64, path: String)]] = [:]
        query(base.appendingPathComponent("root_preference_sqlite.db").path,
              "SELECT root_id, last_seen_absolute_path, account_token FROM roots WHERE state = 2") { row in
            let account = text(row, 2)
            rootsByAccount[account, default: []].append((sqlite3_column_int64(row, 0), normalize(text(row, 1))))
        }

        for (account, roots) in rootsByAccount {
            let mirror = base.appendingPathComponent(account).appendingPathComponent("mirror_sqlite.db").path
            var localIDs: [Int64: Int64] = [:]
            query(mirror, "SELECT root_id, local_stable_id FROM root_config") { row in
                localIDs[sqlite3_column_int64(row, 0)] = sqlite3_column_int64(row, 1)
            }
            for root in roots {
                if let id = localIDs[root.rootID] { snapshot.roots.append(Root(path: root.path, localID: id)) }
            }
            query(mirror, """
                SELECT local_stable_id, parent_local_stable_id, local_filename, local_type,
                       local_md5_checksum IS NOT NULL AND local_md5_checksum = cloud_md5_checksum
                FROM mirror_item
                """) { row in
                let id = sqlite3_column_int64(row, 0)
                let parent = sqlite3_column_int64(row, 1)
                let isFolder = sqlite3_column_int(row, 3) == 0
                snapshot.items[id] = Item(parent: parent, isFolder: isFolder, inCloud: sqlite3_column_int(row, 4) == 1)
                snapshot.children[parent, default: [:]][normalize(text(row, 2))] = id
            }
            // Pendientes de subir: se marcan ellos y todas sus carpetas contenedoras.
            var pending: [Int64] = []
            query(mirror, "SELECT local_stable_id FROM pending_uploads UNION SELECT local_stable_id FROM queued_uploads") { row in
                pending.append(sqlite3_column_int64(row, 0))
            }
            for id in pending {
                var current: Int64? = id
                var steps = 0
                while let node = current, steps < 200, !snapshot.busy.contains(node) {
                    snapshot.busy.insert(node)
                    current = snapshot.items[node]?.parent
                    steps += 1
                }
            }
        }
        return snapshot
    }

    private static func query(_ path: String, _ sql: String, row: (OpaquePointer) -> Void) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW { row(statement) }
    }

    private static func text(_ row: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(row, column).map { String(cString: $0) } ?? ""
    }

    /// Las rutas con acentos pueden venir en dos formas Unicode; se comparan en la misma.
    private static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
    }
}

/// Indicadores sobre el ícono: logo de Google Drive (en las carpetas sincronizadas) y estado.
struct DriveSyncBadge: View {
    let url: URL
    let size: CGFloat
    @ObservedObject private var sync = DriveSync.shared

    var body: some View {
        let _ = sync.revision
        if let status = sync.status(for: url) {
            let badge = max(9, size * 0.3)
            ZStack(alignment: .bottomLeading) {
                Color.clear
                if sync.isSyncRoot(url) && size >= 32 {
                    GoogleDriveIcon(size: badge * 0.8)
                        .padding(badge * 0.12)
                        .background(Circle().fill(Color.white).shadow(color: .black.opacity(0.2), radius: 1))
                }
                Image(systemName: status.symbol)
                    .font(.system(size: badge * 0.55, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: badge, height: badge)
                    .background(Circle().fill(status.color))
                    .overlay(Circle().stroke(Color.white, lineWidth: max(1, badge * 0.1)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            .frame(width: size, height: size)
            .help(status.help)
            .allowsHitTesting(false)
        }
    }
}
