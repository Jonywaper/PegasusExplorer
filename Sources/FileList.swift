import SwiftUI

/// Contenido de la carpeta en la vista elegida (Detalles, iconos o mosaicos).
struct FileListView: View {
    @ObservedObject var state: AppState
    @ObservedObject var tab: ExplorerTab
    @ObservedObject var prefs = Preferences.shared

    var body: some View {
        let items = tab.visibleItems(showHidden: prefs.showHidden)
        ZStack {
            if tab.viewMode == .details {
                DetailsTable(state: state, tab: tab, items: items, showExtensions: prefs.showExtensions)
            } else {
                IconGrid(state: state, tab: tab, items: items, showExtensions: prefs.showExtensions)
            }

            if let error = tab.loadError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundColor(.orange)
                    Text(error).multilineTextAlignment(.center).frame(maxWidth: 420)
                }
                .padding()
            } else if items.isEmpty && !tab.isLoading {
                Text(tab.searchText.isEmpty ? "Esta carpeta está vacía." : "Ningún elemento coincide con la búsqueda.")
                    .foregroundColor(.secondary)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: tab.selection) { _ in QuickLook.shared.update(state.selectedURLs) }
    }
}

// MARK: - Detalles

struct DetailsTable: View {
    let state: AppState
    @ObservedObject var tab: ExplorerTab
    let items: [FileItem]
    let showExtensions: Bool

    var body: some View {
        Table(items, selection: $tab.selection, sortOrder: $tab.sortOrder) {
            TableColumn("Nombre", value: \.name, comparator: .localizedStandard) { item in
                HStack(spacing: 6) {
                    ItemIcon(item: item, size: 16)
                    Text(item.displayName(showExtensions: showExtensions)).lineLimit(1)
                    if !item.tags.isEmpty { TagDots(tags: item.tags) }
                }
                .opacity(item.isHidden ? 0.55 : 1)
            }
            .width(min: 180, ideal: 260)

            TableColumn("Fecha de modificación", value: \.sortDate) { item in
                Text(Format.date(item.modified)).foregroundColor(.secondary)
            }
            .width(min: 110, ideal: 150)

            TableColumn("Tipo", value: \.kind, comparator: .localizedStandard) { item in
                Text(item.kind).foregroundColor(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 130)

            TableColumn("Tamaño", value: \.sortSize) { item in
                Text(Format.size(item.size))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 90)
        }
        .contextMenu(forSelectionType: URL.self) { urls in
            if urls.isEmpty {
                BackgroundContextMenu(state: state, tab: tab)
            } else {
                ItemContextMenu(state: state, urls: state.targets(urls))
            }
        } primaryAction: { urls in
            state.open(state.targets(urls))
        }
    }
}

// MARK: - Iconos y mosaicos

struct IconGrid: View {
    let state: AppState
    @ObservedObject var tab: ExplorerTab
    let items: [FileItem]
    let showExtensions: Bool
    @State private var anchor: URL?

    private var iconSize: CGFloat {
        switch tab.viewMode {
        case .largeIcons: return 96
        case .mediumIcons: return 48
        default: return 48
        }
    }

    private var columns: [GridItem] {
        switch tab.viewMode {
        case .largeIcons: return [GridItem(.adaptive(minimum: 120), spacing: 4)]
        case .tiles: return [GridItem(.adaptive(minimum: 250), spacing: 4, alignment: .leading)]
        default: return [GridItem(.adaptive(minimum: 88), spacing: 4)]
        }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                ForEach(items) { item in
                    cell(item)
                        .contentShape(Rectangle())
                        .onTapGesture { click(item) }
                        .contextMenu {
                            ItemContextMenu(state: state,
                                            urls: tab.selection.contains(item.url) ? state.targets(tab.selection) : [item.url])
                        }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .contentShape(Rectangle())
        .onTapGesture { tab.selection = [] }
        .contextMenu { BackgroundContextMenu(state: state, tab: tab) }
    }

    @ViewBuilder
    private func cell(_ item: FileItem) -> some View {
        let isSelected = tab.selection.contains(item.url)
        let name = item.displayName(showExtensions: showExtensions)
        Group {
            if tab.viewMode == .tiles {
                HStack(spacing: 8) {
                    ItemIcon(item: item, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(name).lineLimit(1)
                            if !item.tags.isEmpty { TagDots(tags: item.tags) }
                        }
                        Text(item.kind).font(.caption).foregroundColor(.secondary).lineLimit(1)
                        if let size = item.size {
                            Text(Format.bytes(size)).font(.caption).foregroundColor(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(6)
            } else {
                VStack(spacing: 4) {
                    ItemIcon(item: item, size: iconSize)
                    HStack(spacing: 3) {
                        if !item.tags.isEmpty { TagDots(tags: item.tags) }
                        Text(name)
                            .font(.system(size: 11))
                            .multilineTextAlignment(.center)
                            .lineLimit(isSelected ? 4 : 2)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity)
            }
        }
        .opacity(item.isHidden ? 0.55 : 1)
        .background(RoundedRectangle(cornerRadius: 3).fill(isSelected ? Color.accentColor.opacity(0.22) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(isSelected ? Color.accentColor.opacity(0.55) : .clear))
    }

    /// Clic, Ctrl/Cmd+clic (agregar o quitar), Mayús+clic (rango) y doble clic (abrir).
    private func click(_ item: FileItem) {
        let event = NSApp.currentEvent
        if (event?.clickCount ?? 1) >= 2 {
            state.open([item.url])
            return
        }
        let flags = event?.modifierFlags ?? []
        if flags.contains(.shift), let anchor,
           let a = items.firstIndex(where: { $0.url == anchor }),
           let b = items.firstIndex(where: { $0.url == item.url }) {
            tab.selection = Set(items[min(a, b)...max(a, b)].map(\.url))
        } else if flags.contains(.command) || flags.contains(.control) {
            if tab.selection.contains(item.url) { tab.selection.remove(item.url) } else { tab.selection.insert(item.url) }
            anchor = item.url
        } else {
            tab.selection = [item.url]
            anchor = item.url
        }
    }
}
