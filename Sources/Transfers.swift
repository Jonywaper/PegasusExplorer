import AppKit
import Darwin
import SwiftUI

// MARK: - Copias y movimientos con progreso

/// Origen y resultado de un elemento copiado o movido.
typealias TransferPair = (from: URL, to: URL)

/// Una copia o un movimiento en curso, con su avance y la opción de cancelar.
final class TransferJob: ObservableObject, Identifiable {
    enum Kind { case copy, move }

    let id = UUID()
    let kind: Kind
    let destination: URL
    let itemCount: Int
    @Published fileprivate(set) var totalBytes: Int64 = 0
    @Published fileprivate(set) var doneBytes: Int64 = 0
    @Published fileprivate(set) var currentName = ""
    @Published fileprivate(set) var preparing = true
    let started = Date()

    private let lock = NSLock()
    private var _cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }

    init(kind: Kind, itemCount: Int, destination: URL) {
        self.kind = kind
        self.itemCount = itemCount
        self.destination = destination
    }

    var title: String {
        let verb = kind == .copy ? "Copiando" : "Moviendo"
        let what = itemCount == 1 ? "1 elemento" : "\(itemCount) elementos"
        return "\(verb) \(what) a «\(FileManager.default.displayName(atPath: destination.path))»"
    }

    var fraction: Double { totalBytes > 0 ? min(1, Double(doneBytes) / Double(totalBytes)) : 0 }

    /// «12,3 MB de 300 MB · quedan unos 20 s».
    var detail: String {
        if preparing { return "Calculando…" }
        var text = "\(Format.bytes(doneBytes)) de \(Format.bytes(totalBytes))"
        let elapsed = Date().timeIntervalSince(started)
        if doneBytes > 0, elapsed > 1 {
            let speed = Double(doneBytes) / elapsed
            let remaining = Double(totalBytes - doneBytes) / max(speed, 1)
            text += " · \(Format.bytes(Int64(speed)))/s"
            if remaining >= 1 { text += " · quedan unos \(Format.duration(remaining))" }
        }
        return text
    }
}

/// Lleva las copias en curso y muestra la ventana de progreso (como la de Windows).
final class TransferCenter: ObservableObject {
    static let shared = TransferCenter()
    @Published private(set) var jobs: [TransferJob] = []
    private var panel: NSPanel?

    /// Copia o mueve `urls` a `folder` en segundo plano.
    /// `completion` recibe los pares (origen, resultado) que sí se completaron y el error, si hubo.
    func start(_ kind: TransferJob.Kind, _ urls: [URL], to folder: URL,
               completion: @escaping ([(from: URL, to: URL)], Error?) -> Void) {
        let job = TransferJob(kind: kind, itemCount: urls.count, destination: folder)
        jobs.append(job)
        // La ventana solo aparece si tarda: las copias rápidas no la muestran.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self, weak job] in
            guard let self, let job, self.jobs.contains(where: { $0 === job }) else { return }
            self.showPanel()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var done: [(from: URL, to: URL)] = []
            var failure: Error?
            do {
                try TransferEngine.run(job, urls, to: folder) { pair in done.append(pair) }
            } catch {
                failure = error
            }
            DispatchQueue.main.async {
                self.jobs.removeAll { $0 === job }
                if self.jobs.isEmpty { self.panel?.orderOut(nil) }
                completion(done, job.isCancelled ? nil : failure)
            }
        }
    }

    private func showPanel() {
        if panel == nil {
            let hosting = NSHostingView(rootView: TransferPanelView(center: self))
            hosting.sizingOptions = []
            let created = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 150),
                                  styleMask: [.titled, .closable, .utilityWindow],
                                  backing: .buffered, defer: false)
            created.title = "Progreso"
            created.isReleasedWhenClosed = false
            created.hidesOnDeactivate = false
            created.contentView = hosting
            created.center()
            panel = created
        }
        let height = CGFloat(40 + jobs.count * 96)
        if let panel {
            var frame = panel.frame
            let delta = height - panel.contentLayoutRect.height
            frame.size.height += delta
            frame.origin.y -= delta
            panel.setFrame(frame, display: true)
            panel.orderFront(nil)
        }
    }
}

struct TransferPanelView: View {
    @ObservedObject var center: TransferCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(center.jobs) { job in TransferRow(job: job) }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct TransferRow: View {
    @ObservedObject var job: TransferJob

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(job.title).font(.headline).lineLimit(1)
            HStack(spacing: 8) {
                ProgressView(value: job.preparing ? nil : job.fraction)
                    .progressViewStyle(.linear)
                Text(job.preparing ? "" : "\(Int(job.fraction * 100)) %")
                    .font(.system(size: 11).monospacedDigit())
                    .frame(width: 40, alignment: .trailing)
                Button("Cancelar") { job.cancel() }
                    .controlSize(.small)
            }
            Text(job.currentName.isEmpty ? job.detail : "\(job.currentName) · \(job.detail)")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// Hace el trabajo de copiar o mover, informando el avance byte a byte.
enum TransferEngine {
    enum TransferError: LocalizedError {
        case intoItself(String)
        var errorDescription: String? {
            switch self {
            case .intoItself(let name): return "No se puede copiar ni mover «\(name)» dentro de sí misma."
            }
        }
    }

    /// Avance compartido con la función de copia de macOS.
    private final class ProgressBox {
        let job: TransferJob
        var completed: Int64 = 0
        var currentFile: Int64 = 0
        var lastPublish = Date.distantPast

        init(job: TransferJob) { self.job = job }

        func publish(force: Bool = false) {
            let now = Date()
            // Como mucho diez actualizaciones por segundo, para no saturar la ventana.
            guard force || now.timeIntervalSince(lastPublish) > 0.1 else { return }
            lastPublish = now
            let value = completed + currentFile
            DispatchQueue.main.async { self.job.doneBytes = value }
        }
    }

    static func run(_ job: TransferJob, _ urls: [URL], to folder: URL,
                    onItem: (TransferPair) -> Void) throws {
        let fm = FileManager.default
        let target = folder.standardizedFileURL
        let targetVolume = volumeID(target)

        // Mover dentro del mismo disco es instantáneo (solo cambia de lugar).
        var toCopy: [URL] = []
        for url in urls {
            if isInside(target, url) { throw TransferError.intoItself(url.lastPathComponent) }
            if job.kind == .move {
                if url.deletingLastPathComponent().standardizedFileURL == target { continue }
                if volumeID(url) == targetVolume {
                    let destination = FileOperations.uniqueURL(for: url.lastPathComponent, in: target, copySuffix: false)
                    try fm.moveItem(at: url, to: destination)
                    onItem(TransferPair(from: url, to: destination))
                    continue
                }
            }
            toCopy.append(url)
        }
        guard !toCopy.isEmpty else { return }

        let total = FileOperations.measure(toCopy) { job.isCancelled }.bytes
        DispatchQueue.main.async {
            job.totalBytes = max(total, 1)
            job.preparing = false
        }
        let box = ProgressBox(job: job)

        for url in toCopy {
            if job.isCancelled { return }
            let sameFolder = url.deletingLastPathComponent().standardizedFileURL == target
            let destination = FileOperations.uniqueURL(for: url.lastPathComponent, in: target,
                                                       copySuffix: job.kind == .copy || sameFolder)
            let name = url.lastPathComponent
            DispatchQueue.main.async { job.currentName = name }
            do {
                try copyWithProgress(url, to: destination, box: box)
            } catch {
                // Si se canceló o falló a medias, no deja una copia incompleta.
                try? fm.removeItem(at: destination)
                if job.isCancelled { return }
                throw error
            }
            if job.kind == .move {
                try fm.removeItem(at: url)
            }
            onItem(TransferPair(from: url, to: destination))
        }
        box.publish(force: true)
    }

    private static func copyWithProgress(_ source: URL, to destination: URL, box: ProgressBox) throws {
        guard let state = copyfile_state_alloc() else { throw CocoaError(.fileWriteUnknown) }
        defer { copyfile_state_free(state) }
        let context = Unmanaged.passUnretained(box).toOpaque()
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), context)
        let callback: copyfile_callback_t = { what, stage, state, _, _, context in
            guard let context else { return COPYFILE_CONTINUE }
            let box = Unmanaged<ProgressBox>.fromOpaque(context).takeUnretainedValue()
            if what == COPYFILE_COPY_DATA && stage == COPYFILE_PROGRESS {
                var copied: off_t = 0
                copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
                box.currentFile = Int64(copied)
                box.publish()
            } else if what == COPYFILE_RECURSE_FILE && stage == COPYFILE_FINISH {
                box.completed += box.currentFile
                box.currentFile = 0
                box.publish()
            }
            return box.job.isCancelled ? COPYFILE_QUIT : COPYFILE_CONTINUE
        }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW_SRC)
        let result = copyfile(source.path, destination.path, state, flags)
        // Un archivo suelto no siempre avisa al terminar: se suma lo que falte.
        box.completed += box.currentFile
        box.currentFile = 0
        box.publish()
        if result != 0 {
            if box.job.isCancelled { throw CocoaError(.userCancelled) }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "No se pudo copiar «\(source.lastPathComponent)»: \(String(cString: strerror(errno)))."])
        }
    }

    static func volumeID(_ url: URL) -> NSObject? {
        var probe = url
        // Si todavía no existe (destino nuevo), se pregunta por la carpeta que lo contiene.
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" {
            probe.deleteLastPathComponent()
        }
        return (try? probe.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
    }

    static func isInside(_ child: URL, _ parent: URL) -> Bool {
        let c = child.standardizedFileURL.path
        let p = parent.standardizedFileURL.path
        return c == p || c.hasPrefix(p.hasSuffix("/") ? p : p + "/")
    }
}

// MARK: - Deshacer y rehacer

/// Una operación que se puede deshacer (Ctrl+Z), como en el Explorador de Windows.
enum UndoRecord {
    case moved([(from: URL, to: URL)])
    case copied([(from: URL, to: URL)])
    case renamed(from: URL, to: URL)
    case trashed([(original: URL, inTrash: URL)])
    case created([URL])

    var undoTitle: String {
        switch self {
        case .moved: return "Deshacer mover"
        case .copied: return "Deshacer copiar"
        case .renamed: return "Deshacer cambiar nombre"
        case .trashed: return "Deshacer eliminar"
        case .created: return "Deshacer nuevo"
        }
    }

    var redoTitle: String {
        switch self {
        case .moved: return "Rehacer mover"
        case .copied: return "Rehacer copiar"
        case .renamed: return "Rehacer cambiar nombre"
        case .trashed: return "Rehacer eliminar"
        case .created: return "Rehacer nuevo"
        }
    }
}

/// Historial compartido por todas las ventanas (como en Windows).
final class UndoHistory: ObservableObject {
    static let shared = UndoHistory()
    @Published private(set) var undoStack: [UndoRecord] = []
    @Published private(set) var redoStack: [UndoRecord] = []

    func record(_ record: UndoRecord) {
        undoStack.append(record)
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Deshace la última operación. `completion` recibe los elementos afectados (para seleccionarlos).
    func undo(completion: @escaping ([URL], Error?) -> Void) {
        guard let last = undoStack.popLast() else { return }
        perform(last, inverse: true) { result in
            switch result {
            case .success(let (urls, redo)):
                if let redo { self.redoStack.append(redo) }
                completion(urls, nil)
            case .failure(let error):
                completion([], error)
            }
        }
    }

    func redo(completion: @escaping ([URL], Error?) -> Void) {
        guard let last = redoStack.popLast() else { return }
        perform(last, inverse: false) { result in
            switch result {
            case .success(let (urls, undo)):
                if let undo { self.undoStack.append(undo) }
                completion(urls, nil)
            case .failure(let error):
                completion([], error)
            }
        }
    }

    /// `inverse: true` deshace `record`; `false` lo vuelve a hacer (record viene de la pila de rehacer).
    /// Devuelve los elementos resultantes y el registro para la otra pila.
    private func perform(_ record: UndoRecord, inverse: Bool,
                         completion: @escaping (Result<([URL], UndoRecord?), Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let result: Result<([URL], UndoRecord?), Error> = Result {
                switch record {
                case .moved(let pairs):
                    // Deshacer: devuelve cada elemento a donde estaba. Rehacer: lo vuelve a mover.
                    var done: [(from: URL, to: URL)] = []
                    for pair in pairs {
                        let (source, target) = inverse ? (pair.to, pair.from) : (pair.from, pair.to)
                        guard fm.fileExists(atPath: source.path), !fm.fileExists(atPath: target.path) else { continue }
                        try fm.moveItem(at: source, to: target)
                        done.append((pair.from, pair.to))
                    }
                    return (done.map { inverse ? $0.from : $0.to }, done.isEmpty ? nil : .moved(done))
                case .copied(let pairs):
                    if inverse {
                        // Las copias van a la Papelera (por si se necesitan).
                        var urls: [URL] = []
                        for pair in pairs where fm.fileExists(atPath: pair.to.path) {
                            try fm.trashItem(at: pair.to, resultingItemURL: nil)
                            urls.append(pair.from)
                        }
                        return (urls, .copied(pairs))
                    }
                    var done: [(from: URL, to: URL)] = []
                    for pair in pairs where fm.fileExists(atPath: pair.from.path) && !fm.fileExists(atPath: pair.to.path) {
                        try fm.copyItem(at: pair.from, to: pair.to)
                        done.append(pair)
                    }
                    return (done.map(\.to), done.isEmpty ? nil : .copied(done))
                case .renamed(let from, let to):
                    let (source, target) = inverse ? (to, from) : (from, to)
                    try fm.moveItem(at: source, to: target)
                    return ([target], .renamed(from: from, to: to))
                case .trashed(let pairs):
                    if inverse {
                        var restored: [URL] = []
                        for pair in pairs where fm.fileExists(atPath: pair.inTrash.path) && !fm.fileExists(atPath: pair.original.path) {
                            try fm.moveItem(at: pair.inTrash, to: pair.original)
                            restored.append(pair.original)
                        }
                        return (restored, .trashed(pairs))
                    }
                    var again: [(original: URL, inTrash: URL)] = []
                    for pair in pairs where fm.fileExists(atPath: pair.original.path) {
                        var resulting: NSURL?
                        try fm.trashItem(at: pair.original, resultingItemURL: &resulting)
                        again.append((pair.original, (resulting as URL?) ?? pair.inTrash))
                    }
                    return ([], .trashed(again))
                case .created(let urls):
                    if inverse {
                        for url in urls where fm.fileExists(atPath: url.path) {
                            try fm.trashItem(at: url, resultingItemURL: nil)
                        }
                    }
                    // Lo creado no se puede «rehacer» (habría que recrearlo desde cero).
                    return ([], nil)
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
