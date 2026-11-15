import Foundation
import SQLite3

/// Espacio de una cuenta en la nube.
struct CloudQuota: Hashable {
    let total: Int64
    let used: Int64
    let remaining: Int64

    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

/// Lee la cuota de Google Drive que la app «Google Drive para escritorio» guarda en la Mac
/// (~/Library/Application Support/Google/DriveFS/<cuenta>/metadata_sqlite_db).
/// Es la misma cifra que muestra esa app; se actualiza cuando Google Drive se sincroniza.
enum GoogleDriveQuota {
    static func quota(forEmail email: String) -> CloudQuota? {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/DriveFS")
        let accounts = ((try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.isEmpty && $0.lastPathComponent.allSatisfy(\.isNumber) }

        for account in accounts {
            let db = account.appendingPathComponent("metadata_sqlite_db").path
            let blobs = readProperties(db, keys: ["driveway_account", "account"])
            // Con varias cuentas, usa la carpeta cuyo registro contiene ese correo.
            if accounts.count > 1, !email.isEmpty {
                let needle = Data(email.lowercased().utf8)
                let matches = blobs.values.contains { $0.range(of: needle) != nil }
                if !matches { continue }
            }
            for key in ["driveway_account", "account"] {
                if let blob = blobs[key], let quota = findQuota(in: blob) { return quota }
            }
        }
        return nil
    }

    // MARK: SQLite

    private static func readProperties(_ path: String, keys: [String]) -> [String: Data] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return [:]
        }
        defer { sqlite3_close(db) }
        var result: [String: Data] = [:]
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for key in keys {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT value FROM properties WHERE property = ?", -1, &statement, nil) == SQLITE_OK else { continue }
            sqlite3_bind_text(statement, 1, key, -1, transient)
            if sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) {
                result[key] = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            }
            sqlite3_finalize(statement)
        }
        return result
    }

    // MARK: Protobuf

    /// Busca el bloque de cuota dentro del registro (formato protobuf sin esquema):
    /// campo 1 = total, 3 = usado, 7 = límite (igual al total), 8 = restante.
    static func findQuota(in data: Data) -> CloudQuota? {
        let bytes = [UInt8](data)
        return search(bytes[...], depth: 0)
    }

    private static func search(_ bytes: ArraySlice<UInt8>, depth: Int) -> CloudQuota? {
        guard depth < 8, let fields = parse(bytes) else { return nil }
        var numbers: [Int: UInt64] = [:]
        for field in fields {
            if case .number(let value) = field.value, numbers[field.number] == nil {
                numbers[field.number] = value
            }
        }
        if let total = numbers[1], let used = numbers[3], let remaining = numbers[8],
           total > 0, numbers[7] == total, used <= total {
            let gap = Int64(total) - Int64(used) - Int64(remaining)
            if abs(gap) <= Int64(total / 100) {
                return CloudQuota(total: Int64(total), used: Int64(used), remaining: Int64(remaining))
            }
        }
        for field in fields {
            if case .bytes(let sub) = field.value, !sub.isEmpty, let found = search(sub, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    private enum Value {
        case number(UInt64)
        case bytes(ArraySlice<UInt8>)
    }

    private static func parse(_ bytes: ArraySlice<UInt8>) -> [(number: Int, value: Value)]? {
        var fields: [(Int, Value)] = []
        var i = bytes.startIndex
        func varint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while i < bytes.endIndex, shift < 64 {
                let byte = bytes[i]
                i += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte < 0x80 { return result }
                shift += 7
            }
            return nil
        }
        while i < bytes.endIndex {
            guard let key = varint() else { return nil }
            let number = Int(key >> 3)
            guard number > 0 else { return nil }
            switch key & 7 {
            case 0:
                guard let value = varint() else { return nil }
                fields.append((number, .number(value)))
            case 1:
                guard i + 8 <= bytes.endIndex else { return nil }
                i += 8
            case 2:
                guard let length = varint(), length <= UInt64(bytes.endIndex - i) else { return nil }
                let end = i + Int(length)
                fields.append((number, .bytes(bytes[i..<end])))
                i = end
            case 5:
                guard i + 4 <= bytes.endIndex else { return nil }
                i += 4
            default:
                return nil
            }
        }
        return fields
    }
}
