import SwiftUI

/// Ventana Propiedades, como la pestaña General de Windows, con datos extra de Finder.
struct PropertiesSheet: View {
    @ObservedObject var state: AppState
    let urls: [URL]

    @State private var size = FileOperations.SizeInfo()
    @State private var measuring = true
    @State private var cancelled = false
    @State private var readOnly = false
    @State private var hidden = false
    @State private var originalReadOnly = false
    @State private var originalHidden = false

    private var single: URL? { urls.count == 1 ? urls[0] : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                icon
                Text(title).font(.headline).lineLimit(2)
                Spacer()
            }
            .padding(.bottom, 12)

            Divider()
            grid {
                row("Tipo:", kind)
                if let single { row("Ubicación:", single.deletingLastPathComponent().path) }
                if let opener = opensWith { row("Se abre con:", opener) }
            }
            Divider()
            grid {
                row("Tamaño:", measuring ? "Calculando… \(Format.bytesLong(size.bytes))" : Format.bytesLong(size.bytes))
                row("Tamaño en disco:", Format.bytesLong(size.onDisk))
                if size.folders > 0 || isFolderSelection {
                    row("Contiene:", "\(Format.number(Int64(size.files))) archivos, \(Format.number(Int64(size.folders))) carpetas")
                }
            }
            if let single, let values = try? single.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .contentAccessDateKey, .tagNamesKey, .volumeLocalizedFormatDescriptionKey]) {
                Divider()
                grid {
                    row("Creado:", Format.longDate(values.creationDate))
                    row("Modificado:", Format.longDate(values.contentModificationDate))
                    row("Último acceso:", Format.longDate(values.contentAccessDate))
                }
                if let tags = values.tagNames, !tags.isEmpty {
                    Divider()
                    grid {
                        GridRow {
                            Text("Etiquetas:").foregroundColor(.secondary)
                            HStack { TagDots(tags: tags); Text(tags.joined(separator: ", ")) }
                        }
                    }
                }
            }
            Divider()
            grid {
                GridRow(alignment: .top) {
                    Text("Atributos:").foregroundColor(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Solo lectura (bloqueado)", isOn: $readOnly)
                        Toggle("Oculto", isOn: $hidden)
                    }
                    .toggleStyle(.checkbox)
                }
            }

            Spacer(minLength: 12)
            HStack {
                Spacer()
                Button("Cancelar") { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Aplicar") { apply() }
                    .disabled(readOnly == originalReadOnly && hidden == originalHidden)
                Button("Aceptar") { apply(); close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 440)
        .onAppear(perform: load)
        .onDisappear { cancelled = true }
    }

    // MARK: Datos

    private var title: String {
        if let single {
            if single.path == "/" { return Volume.mounted().first(where: \.isRoot)?.name ?? "Disco local" }
            return FileManager.default.displayName(atPath: single.path)
        }
        return "\(urls.count) elementos"
    }

    private var isFolderSelection: Bool { urls.contains(where: AppState.isFolder) }

    private var kind: String {
        if let single {
            let values = try? single.resourceValues(forKeys: [.isVolumeKey, .localizedTypeDescriptionKey, .volumeLocalizedFormatDescriptionKey])
            if values?.isVolume == true {
                return "Disco · \(values?.volumeLocalizedFormatDescription ?? "")"
            }
            if AppState.isFolder(single) { return "Carpeta de archivos" }
            return values?.localizedTypeDescription ?? "Archivo"
        }
        return "Varios tipos"
    }

    private var opensWith: String? {
        guard let single, !AppState.isFolder(single),
              let app = NSWorkspace.shared.urlForApplication(toOpen: single) else { return nil }
        return FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    @ViewBuilder
    private var icon: some View {
        if let single, AppState.isFolder(single),
           (try? single.resourceValues(forKeys: [.isVolumeKey]).isVolume) != true {
            WindowsFolderIcon(size: 40)
        } else if let single {
            Image(nsImage: IconCache.shared.icon(for: single)).resizable().frame(width: 40, height: 40)
        } else {
            Image(systemName: "doc.on.doc").font(.system(size: 30)).frame(width: 40, height: 40)
        }
    }

    private func load() {
        let keys: Set<URLResourceKey> = [.isUserImmutableKey, .isHiddenKey]
        let values = urls.compactMap { try? $0.resourceValues(forKeys: keys) }
        readOnly = !values.isEmpty && values.allSatisfy { $0.isUserImmutable ?? false }
        hidden = !values.isEmpty && values.allSatisfy { $0.isHidden ?? false }
        originalReadOnly = readOnly
        originalHidden = hidden

        // Para un disco, el tamaño es lo usado del volumen (medirlo entero tardaría mucho).
        if let single, (try? single.resourceValues(forKeys: [.isVolumeKey]).isVolume) == true,
           let volume = Volume.mounted().first(where: { $0.url.standardizedFileURL == single.standardizedFileURL }) {
            let used = (volume.totalBytes ?? 0) - (volume.freeBytes ?? 0)
            size = .init(bytes: used, onDisk: used, files: 0, folders: 0)
            measuring = false
            return
        }

        let targets = urls
        DispatchQueue.global(qos: .userInitiated).async {
            let result = FileOperations.measure(targets) { cancelled }
            DispatchQueue.main.async {
                size = result
                measuring = false
            }
        }
    }

    private func apply() {
        if readOnly != originalReadOnly { state.runAttribute { try FileOperations.setLocked(readOnly, for: urls) } }
        if hidden != originalHidden { state.setHidden(hidden, urls) }
        originalReadOnly = readOnly
        originalHidden = hidden
    }

    private func close() {
        state.propertiesTarget = nil
    }

    // MARK: Diseño

    private func grid<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) { content() }
            .padding(.vertical, 10)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .top) {
            Text(label).foregroundColor(.secondary).frame(width: 110, alignment: .leading)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension AppState {
    func runAttribute(_ work: @escaping () throws -> Void) {
        let tab = currentTab
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try work()
                DispatchQueue.main.async { tab.reload() }
            } catch {
                DispatchQueue.main.async { self.alertMessage = error.localizedDescription }
            }
        }
    }
}
