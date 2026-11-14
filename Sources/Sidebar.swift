import SwiftUI

/// Nodo del árbol de carpetas. Sus subcarpetas se cargan al expandirlo.
final class FolderNode: ObservableObject, Identifiable {
    let url: URL
    let name: String
    @Published var children: [FolderNode]?
    @Published var isExpanded = false {
        didSet { if isExpanded && children == nil { loadChildren() } }
    }

    var id: URL { url }

    init(url: URL, name: String? = nil) {
        self.url = url
        self.name = name ?? FileManager.default.displayName(atPath: url.path)
    }

    func loadChildren() {
        let parent = url
        DispatchQueue.global(qos: .userInitiated).async {
            let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey]
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: parent, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            let folders = urls.filter { url in
                guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return false }
                return (v.isDirectory ?? false) && !(v.isPackage ?? false) && !(v.isHidden ?? false)
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { FolderNode(url: $0) }
            DispatchQueue.main.async { self.children = folders }
        }
    }
}

/// Árbol de nodos reutilizados para que no se cierren al redibujar.
final class SidebarModel: ObservableObject {
    @Published var quickAccessExpanded = true
    @Published var thisPCExpanded = true
    @Published var networkExpanded = true
    private var nodes: [URL: FolderNode] = [:]

    func node(_ url: URL, name: String? = nil) -> FolderNode {
        if let existing = nodes[url] { return existing }
        let created = FolderNode(url: url, name: name)
        nodes[url] = created
        return created
    }
}

/// Panel de navegación como el de Windows: Acceso rápido, Este equipo y Red.
struct SidebarView: View {
    @ObservedObject var state: AppState
    @ObservedObject var tab: ExplorerTab
    @ObservedObject var prefs = Preferences.shared
    @StateObject private var model = SidebarModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Acceso rápido
                SectionHeader(title: "Acceso rápido", symbol: "star.fill", tint: .blue,
                              isExpanded: $model.quickAccessExpanded, isCurrent: false) {
                    model.quickAccessExpanded.toggle()
                }
                if model.quickAccessExpanded {
                    ForEach(prefs.pinned, id: \.self) { url in
                        SidebarRow(depth: 1, isCurrent: tab.url == url.standardizedFileURL,
                                   action: { state.currentTab.navigate(to: url) }) {
                            folderIcon(for: url)
                        } label: {
                            Text(KnownFolder.matching(url)?.title ?? FileManager.default.displayName(atPath: url.path))
                            Spacer(minLength: 0)
                            Image(systemName: "pin.fill").font(.system(size: 9)).foregroundColor(.secondary)
                        }
                        .contextMenu {
                            Button("Abrir en una pestaña nueva") { state.newTab(at: url) }
                            Button("Abrir en ventana nueva") { state.newWindow(at: url) }
                            Divider()
                            Button("Desanclar del Acceso rápido") { prefs.togglePin(url) }
                            Divider()
                            Button("Propiedades") { state.showProperties([url]) }
                        }
                    }
                }

                Spacer().frame(height: 8)

                // Este equipo
                SectionHeader(title: "Este equipo", symbol: "desktopcomputer", tint: .blue,
                              isExpanded: $model.thisPCExpanded,
                              isCurrent: tab.isThisPC) {
                    state.currentTab.navigate(to: Locations.thisPC)
                }
                if model.thisPCExpanded {
                    FolderTreeRow(node: model.node(FileManager.default.homeDirectoryForCurrentUser),
                                  model: model, state: state, tab: tab, depth: 1, customIcon: AnyView(
                                    Image(systemName: "house.fill").foregroundColor(.blue)))
                    ForEach(KnownFolder.allCases, id: \.self) { folder in
                        FolderTreeRow(node: model.node(folder.url, name: folder.title),
                                      model: model, state: state, tab: tab, depth: 1)
                    }
                    ForEach(prefs.cloudDrives) { drive in
                        FolderTreeRow(node: model.node(drive.url, name: drive.name),
                                      model: model, state: state, tab: tab, depth: 1,
                                      customIcon: AnyView(CloudIcon(drive: drive)))
                    }
                    ForEach(prefs.localVolumes) { volume in
                        FolderTreeRow(node: model.node(volume.url, name: volume.name),
                                      model: model, state: state, tab: tab, depth: 1,
                                      customIcon: AnyView(DriveIcon(volume: volume)), volume: volume)
                    }
                }

                Spacer().frame(height: 8)

                // Red
                SectionHeader(title: "Red", symbol: "network", tint: .blue,
                              isExpanded: $model.networkExpanded, isCurrent: false) {
                    model.networkExpanded.toggle()
                }
                if model.networkExpanded {
                    ForEach(prefs.networkVolumes) { volume in
                        FolderTreeRow(node: model.node(volume.url, name: volume.name),
                                      model: model, state: state, tab: tab, depth: 1,
                                      customIcon: AnyView(Image(systemName: "server.rack").foregroundColor(.green)),
                                      volume: volume)
                    }
                    ForEach(prefs.disconnectedShares) { share in
                        SidebarRow(depth: 1, isCurrent: false,
                                   action: { state.connect(to: share.address, save: false) }) {
                            Image(systemName: "server.rack").foregroundColor(.secondary)
                        } label: {
                            Text(share.name).foregroundColor(.secondary)
                        }
                        .help("\(share.address) · sin conectar. Haz clic para conectar.")
                        .contextMenu {
                            Button("Conectar") { state.connect(to: share.address, save: false) }
                            Button("Quitar de Red") { prefs.forget(share) }
                        }
                    }
                    SidebarRow(depth: 1, isCurrent: false, action: { state.showConnectDialog() }) {
                        Image(systemName: "plus.circle.fill").foregroundColor(.accentColor)
                    } label: {
                        Text("Conectar a unidad de red…")
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private func folderIcon(for url: URL) -> some View {
        if let known = KnownFolder.matching(url) {
            Image(systemName: known.symbol).foregroundColor(.blue)
        } else {
            WindowsFolderIcon(size: 16)
        }
    }
}

struct SectionHeader: View {
    let title: String
    let symbol: String
    let tint: Color
    @Binding var isExpanded: Bool
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button { isExpanded.toggle() } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 14, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundColor(tint).frame(width: 18)
                Text(title).fontWeight(.semibold)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .background(isCurrent ? Color.accentColor.opacity(0.18) : .clear)
            .cornerRadius(4)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
        }
    }
}

struct SidebarRow<Icon: View, Content: View>: View {
    let depth: Int
    let isCurrent: Bool
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder let label: () -> Content
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            icon().frame(width: 18, height: 16)
            label().lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(isCurrent ? Color.accentColor.opacity(0.18) : (hovering ? Color.primary.opacity(0.05) : .clear))
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
        .padding(.leading, CGFloat(depth) * 14 + 16)
    }
}

struct FolderTreeRow: View {
    @ObservedObject var node: FolderNode
    let model: SidebarModel
    let state: AppState
    @ObservedObject var tab: ExplorerTab
    var depth: Int
    var customIcon: AnyView?
    var volume: Volume?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Button { node.isExpanded.toggle() } label: {
                    Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 14, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(node.children?.isEmpty == true ? 0 : 1)

                HStack(spacing: 6) {
                    icon.frame(width: 18, height: 16)
                    Text(node.name).lineLimit(1)
                    Spacer(minLength: 0)
                    if let volume, volume.isEjectable {
                        Button { state.eject(volume) } label: {
                            Image(systemName: "eject.fill").font(.system(size: 9))
                        }
                        .buttonStyle(.borderless)
                        .opacity(hovering ? 1 : 0)
                        .help(volume.isNetwork ? "Desconectar" : "Expulsar")
                    }
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 4)
                .background(isCurrent ? Color.accentColor.opacity(0.18) : (hovering ? Color.primary.opacity(0.05) : .clear))
                .cornerRadius(4)
                .contentShape(Rectangle())
                .onTapGesture { state.currentTab.navigate(to: node.url) }
                .onHover { hovering = $0 }
                .contextMenu { menu }
            }
            .padding(.leading, CGFloat(depth) * 14)

            if node.isExpanded {
                if let children = node.children {
                    ForEach(children) { child in
                        FolderTreeRow(node: model.node(child.url, name: child.name), model: model,
                                      state: state, tab: tab, depth: depth + 1)
                    }
                } else {
                    Text("Cargando…")
                        .foregroundColor(.secondary).font(.caption)
                        .padding(.leading, CGFloat(depth + 1) * 14 + 20)
                }
            }
        }
    }

    private var isCurrent: Bool { tab.url == node.url.standardizedFileURL }

    private var icon: some View {
        Group {
            if let customIcon {
                customIcon
            } else if let known = KnownFolder.matching(node.url) {
                Image(systemName: known.symbol).foregroundColor(.blue)
            } else {
                WindowsFolderIcon(size: 16)
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("Abrir en una pestaña nueva") { state.newTab(at: node.url) }
        Button("Abrir en ventana nueva") { state.newWindow(at: node.url) }
        Divider()
        Button(state.prefs.isPinned(node.url) ? "Desanclar del Acceso rápido" : "Anclar al Acceso rápido") {
            state.prefs.togglePin(node.url)
        }
        Button("Abrir en Terminal") { state.openInTerminal(node.url) }
        if let volume, volume.isEjectable {
            Divider()
            Button(volume.isNetwork ? "Desconectar" : "Expulsar") { state.eject(volume) }
        }
        Divider()
        Button("Propiedades") { state.showProperties([node.url]) }
    }
}
