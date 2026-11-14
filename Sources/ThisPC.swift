import SwiftUI

/// Página «Este equipo»: carpetas, dispositivos y unidades, y ubicaciones de red.
struct ThisPCView: View {
    @ObservedObject var state: AppState
    @ObservedObject var prefs = Preferences.shared
    @State private var foldersExpanded = true
    @State private var drivesExpanded = true
    @State private var networkExpanded = true
    @State private var selected: URL?

    private let folderColumns = [GridItem(.adaptive(minimum: 230), spacing: 8, alignment: .leading)]
    private let driveColumns = [GridItem(.adaptive(minimum: 280), spacing: 8, alignment: .leading)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                group(title: "Carpetas (\(KnownFolder.allCases.count + 1))", expanded: $foldersExpanded) {
                    LazyVGrid(columns: folderColumns, alignment: .leading, spacing: 6) {
                        folderTile(url: FileManager.default.homeDirectoryForCurrentUser,
                                   title: FileManager.default.displayName(atPath: NSHomeDirectory()),
                                   symbol: "house.fill")
                        ForEach(KnownFolder.allCases, id: \.self) { folder in
                            folderTile(url: folder.url, title: folder.title, symbol: folder.symbol)
                        }
                    }
                }

                group(title: "Dispositivos y unidades (\(prefs.localVolumes.count))", expanded: $drivesExpanded) {
                    LazyVGrid(columns: driveColumns, alignment: .leading, spacing: 6) {
                        ForEach(prefs.localVolumes) { volume in driveTile(volume) }
                    }
                }

                let networkCount = prefs.networkVolumes.count + prefs.disconnectedShares.count
                group(title: "Ubicaciones de red (\(networkCount))", expanded: $networkExpanded) {
                    LazyVGrid(columns: driveColumns, alignment: .leading, spacing: 6) {
                        ForEach(prefs.networkVolumes) { volume in driveTile(volume) }
                        ForEach(prefs.disconnectedShares) { share in
                            tile(id: URL(string: share.address) ?? Locations.thisPC,
                                 open: { state.connect(to: share.address, save: false) }) {
                                Image(systemName: "server.rack").font(.system(size: 30)).foregroundColor(.secondary)
                                    .frame(width: 48, height: 48)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(share.name)
                                    Text("Sin conectar · \(share.address)").font(.caption).foregroundColor(.secondary)
                                }
                            }
                            .contextMenu {
                                Button("Conectar") { state.connect(to: share.address, save: false) }
                                Button("Quitar de Red") { prefs.forget(share) }
                            }
                        }
                        tile(id: URL(string: "pegasus://conectar")!, open: { state.showConnectDialog() }) {
                            Image(systemName: "plus.circle").font(.system(size: 30)).foregroundColor(.accentColor)
                                .frame(width: 48, height: 48)
                            Text("Conectar a unidad de red…")
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .contextMenu {
            Button("Conectar a unidad de red…") { state.showConnectDialog() }
            Button("Actualizar") { prefs.refreshVolumes() }
        }
    }

    // MARK: Piezas

    private func group<Content: View>(title: String, expanded: Binding<Bool>,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded.wrappedValue.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text(title).foregroundColor(Color(red: 0.12, green: 0.24, blue: 0.55))
                        .font(.system(size: 13))
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded.wrappedValue { content() }
        }
    }

    private func folderTile(url: URL, title: String, symbol: String) -> some View {
        tile(id: url, open: { state.currentTab.navigate(to: url) }) {
            WindowsFolderIcon(size: 48, symbol: symbol)
            Text(title)
        }
        .contextMenu {
            Button("Abrir") { state.currentTab.navigate(to: url) }
            Button("Abrir en una pestaña nueva") { state.newTab(at: url) }
            Button("Abrir en ventana nueva") { state.newWindow(at: url) }
            Divider()
            Button(prefs.isPinned(url) ? "Desanclar del Acceso rápido" : "Anclar al Acceso rápido") { prefs.togglePin(url) }
            Divider()
            Button("Propiedades") { state.showProperties([url]) }
        }
    }

    private func driveTile(_ volume: Volume) -> some View {
        tile(id: volume.url, open: { state.currentTab.navigate(to: volume.url) }) {
            DriveIcon(volume: volume, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(volume.name).lineLimit(1)
                if volume.totalBytes != nil {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.primary.opacity(0.12))
                            Rectangle()
                                .fill(volume.usedFraction > 0.9 ? Color.red : Color(red: 0.15, green: 0.55, blue: 0.95))
                                .frame(width: geo.size.width * volume.usedFraction)
                        }
                        .overlay(Rectangle().stroke(Color.primary.opacity(0.2)))
                    }
                    .frame(width: 190, height: 12)
                    Text("\(Format.bytes(volume.freeBytes ?? 0)) disponibles de \(Format.bytes(volume.totalBytes ?? 0))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .contextMenu {
            Button("Abrir") { state.currentTab.navigate(to: volume.url) }
            Button("Abrir en una pestaña nueva") { state.newTab(at: volume.url) }
            Button("Abrir en ventana nueva") { state.newWindow(at: volume.url) }
            Button("Abrir en Terminal") { state.openInTerminal(volume.url) }
            if volume.isEjectable {
                Divider()
                Button(volume.isNetwork ? "Desconectar" : "Expulsar") { state.eject(volume) }
            }
            Divider()
            Button("Propiedades") { state.showProperties([volume.url]) }
        }
    }

    private func tile<Content: View>(id: URL, open: @escaping () -> Void,
                                     @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 3)
                .fill(selected == id ? Color.accentColor.opacity(0.2) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 3)
                .stroke(selected == id ? Color.accentColor.opacity(0.5) : Color.clear))
            .contentShape(Rectangle())
            .onTapGesture {
                if NSApp.currentEvent?.clickCount ?? 1 >= 2 { open() } else { selected = id }
            }
    }
}
