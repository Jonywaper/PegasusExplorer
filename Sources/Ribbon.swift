import SwiftUI

/// Cinta de opciones como la del Explorador de Windows 10: Archivo, Inicio, Compartir y Vista.
struct Ribbon: View {
    @ObservedObject var state: AppState
    @ObservedObject var tab: ExplorerTab
    @ObservedObject var prefs = Preferences.shared
    @AppStorage("ribbonTab") private var selected = "Inicio"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button { PopupMenu.show(fileMenu) } label: {
                    Text("Archivo")
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 24)
                        .background(Color(red: 0.10, green: 0.42, blue: 0.80))
                }
                .buttonStyle(.plain)

                ForEach(["Inicio", "Compartir", "Vista"], id: \.self) { name in
                    Button {
                        if selected == name && prefs.showRibbon { prefs.showRibbon = false } else {
                            selected = name
                            prefs.showRibbon = true
                        }
                    } label: {
                        Text(name)
                            .padding(.horizontal, 12)
                            .frame(height: 24)
                            .background(selected == name && prefs.showRibbon ? Color(nsColor: .controlBackgroundColor) : .clear)
                            .overlay(alignment: .top) {
                                if selected == name && prefs.showRibbon {
                                    Rectangle().fill(Color.primary.opacity(0.15)).frame(height: 1)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button { prefs.showRibbon.toggle() } label: {
                    Image(systemName: prefs.showRibbon ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 26, height: 24)
                }
                .buttonStyle(.plain)
                .help(prefs.showRibbon ? "Minimizar la cinta de opciones" : "Expandir la cinta de opciones")
            }
            .font(.system(size: 12))
            .background(Color(nsColor: .windowBackgroundColor))

            if prefs.showRibbon {
                Divider()
                // Sin área desplazable: si la ventana es angosta, la cinta se recorta a la derecha.
                HStack(alignment: .top, spacing: 0) {
                    switch selected {
                    case "Compartir": shareTab
                    case "Vista": viewTab
                    default: homeTab
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, maxHeight: 92, alignment: .topLeading)
                .frame(height: 92)
                .clipped()
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
    }

    // MARK: Pestaña Inicio

    private var homeTab: some View {
        let selection = state.selectedURLs
        let has = !selection.isEmpty
        let writable = state.canWriteHere
        let canPaste = writable && FileClipboard.shared.hasContent
        let single = selection.count == 1 ? selection[0] : nil
        let pinTarget = single.flatMap { AppState.isFolder($0) ? $0 : nil } ?? (tab.isThisPC ? nil : tab.url)

        return HStack(alignment: .top, spacing: 0) {
            RibbonGroup("Portapapeles") {
                BigButton(title: "Anclar al\nAcceso rápido", symbol: "pin.fill", color: .blue, enabled: pinTarget != nil) {
                    if let pinTarget { prefs.togglePin(pinTarget) }
                }
                BigButton(title: "Copiar", symbol: "doc.on.doc.fill", color: .blue, enabled: has) { state.copy(selection) }
                BigButton(title: "Pegar", symbol: "doc.on.clipboard.fill", color: .orange, enabled: canPaste) { state.paste() }
                VStack(alignment: .leading, spacing: 2) {
                    SmallButton(title: "Cortar", symbol: "scissors", enabled: has) { state.cut(selection) }
                    SmallButton(title: "Copiar ruta de acceso", symbol: "link", enabled: true) { state.copyPath(selection) }
                    SmallButton(title: "Pegar acceso directo", symbol: "arrowshape.turn.up.right", enabled: canPaste) { state.pasteShortcut() }
                }
            }
            RibbonGroup("Organizar") {
                BigButton(title: "Mover\na ▾", symbol: "folder.fill.badge.plus", color: .orange, enabled: has) {
                    PopupMenu.show(state.destinationEntries(copying: false))
                }
                BigButton(title: "Copiar\na ▾", symbol: "folder.fill", color: .orange, enabled: has) {
                    PopupMenu.show(state.destinationEntries(copying: true))
                }
                BigButton(title: "Eliminar\n▾", symbol: "xmark", color: .red, enabled: has) {
                    PopupMenu.show([
                        MenuEntry(title: "Reciclar (enviar a la Papelera)") { state.trash(selection) },
                        MenuEntry(title: "Eliminar permanentemente…") { state.askDeletePermanently(selection) },
                    ])
                }
                BigButton(title: "Cambiar\nnombre", symbol: "character.cursor.ibeam", color: .blue, enabled: single != nil) {
                    state.beginRename()
                }
            }
            RibbonGroup("Nuevo") {
                BigButton(title: "Nueva\ncarpeta", symbol: "folder.fill.badge.plus", color: .yellow, enabled: writable) { state.newFolder() }
                VStack(alignment: .leading, spacing: 2) {
                    SmallButton(title: "Nuevo elemento ▾", symbol: "doc.badge.plus", enabled: writable) {
                        PopupMenu.show([
                            MenuEntry(title: "Carpeta") { state.newFolder() },
                            .separator,
                            MenuEntry(title: "Documento de texto") { state.newTextDocument() },
                            MenuEntry(title: "Documento de texto enriquecido") { state.newTextDocument(rich: true) },
                            MenuEntry(title: "Acceso directo de lo copiado", enabled: FileClipboard.shared.hasContent) { state.pasteShortcut() },
                        ])
                    }
                    SmallButton(title: "Nueva carpeta con selección", symbol: "folder.badge.plus", enabled: writable && selection.count > 1) {
                        state.newFolder(with: selection)
                    }
                }
            }
            RibbonGroup("Abrir") {
                BigButton(title: "Propiedades", symbol: "checkmark.rectangle.fill", color: .gray, enabled: true) {
                    state.showProperties(selection)
                }
                VStack(alignment: .leading, spacing: 2) {
                    SmallButton(title: "Abrir ▾", symbol: "arrow.up.forward.app", enabled: has) {
                        PopupMenu.show(openEntries(selection))
                    }
                    SmallButton(title: "Vista rápida", symbol: "eye", enabled: has) { state.quickLook(selection) }
                    SmallButton(title: "Mostrar en Finder", symbol: "macwindow", enabled: !tab.isThisPC) { state.showInFinder(selection) }
                }
            }
            RibbonGroup("Seleccionar") {
                VStack(alignment: .leading, spacing: 2) {
                    SmallButton(title: "Seleccionar todo", symbol: "checkmark.square", enabled: true) { state.selectAll() }
                    SmallButton(title: "No seleccionar ninguno", symbol: "square", enabled: has) { state.selectNone() }
                    SmallButton(title: "Invertir selección", symbol: "square.on.square", enabled: true) { state.invertSelection() }
                }
            }
        }
    }

    // MARK: Pestaña Compartir

    private var shareTab: some View {
        let selection = state.selectedURLs
        let has = !selection.isEmpty
        return HStack(alignment: .top, spacing: 0) {
            RibbonGroup("Enviar") {
                BigButton(title: "Compartir", symbol: "square.and.arrow.up", color: .blue, enabled: has) { state.share(selection) }
                BigButton(title: "Correo\nelectrónico", symbol: "envelope.fill", color: .blue, enabled: has) { state.email(selection) }
                BigButton(title: "Comprimir\n(zip)", symbol: "doc.zipper", color: .orange, enabled: has) { state.compress(selection) }
                BigButton(title: "AirDrop", symbol: "dot.radiowaves.left.and.right", color: .blue, enabled: has) {
                    NSSharingService(named: .sendViaAirDrop)?.perform(withItems: selection)
                }
            }
            RibbonGroup("Etiquetas") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        ForEach(FinderTags.all, id: \.self) { tag in
                            Button { state.toggleTag(tag.name, on: selection) } label: {
                                Circle().fill(Color(nsColor: tag.color)).frame(width: 16, height: 16)
                            }
                            .buttonStyle(.plain)
                            .disabled(!has)
                            .help(tag.name)
                        }
                    }
                    SmallButton(title: "Quitar etiquetas", symbol: "tag.slash", enabled: has) { state.clearTags(selection) }
                }
                .padding(.top, 6)
            }
            RibbonGroup("Red") {
                BigButton(title: "Conectar a\nunidad de red", symbol: "externaldrive.connected.to.line.below", color: .green, enabled: true) {
                    state.showConnectDialog()
                }
            }
        }
    }

    // MARK: Pestaña Vista

    private var viewTab: some View {
        let selection = state.selectedURLs
        return HStack(alignment: .top, spacing: 0) {
            RibbonGroup("Paneles") {
                BigButton(title: "Panel de\nnavegación", symbol: "sidebar.left", color: .blue, enabled: true,
                          isOn: prefs.showNavigationPane) { prefs.showNavigationPane.toggle() }
                BigButton(title: "Panel de\nvista previa", symbol: "sidebar.right", color: .blue, enabled: true,
                          isOn: prefs.showPreviewPane) { prefs.showPreviewPane.toggle() }
            }
            RibbonGroup("Diseño") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach([ViewMode.largeIcons, .mediumIcons], id: \.self) { mode in
                        SmallButton(title: mode.title, symbol: mode.symbol, enabled: true, isOn: tab.viewMode == mode) {
                            state.setViewMode(mode)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach([ViewMode.tiles, .details], id: \.self) { mode in
                        SmallButton(title: mode.title, symbol: mode.symbol, enabled: true, isOn: tab.viewMode == mode) {
                            state.setViewMode(mode)
                        }
                    }
                }
            }
            RibbonGroup("Vista actual") {
                BigButton(title: "Ordenar\npor ▾", symbol: "arrow.up.arrow.down", color: .blue, enabled: !tab.isThisPC) {
                    PopupMenu.show(sortEntries)
                }
            }
            RibbonGroup("Mostrar u ocultar") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Extensiones de nombre de archivo", isOn: $prefs.showExtensions)
                    Toggle("Elementos ocultos", isOn: $prefs.showHidden)
                }
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .padding(.top, 6)
                BigButton(title: "Ocultar elementos\nseleccionados", symbol: "eye.slash", color: .gray,
                          enabled: !selection.isEmpty) {
                    let allHidden = state.currentTab.items.filter { selection.contains($0.url) }.allSatisfy(\.isHidden)
                    state.setHidden(!allHidden, selection)
                }
            }
        }
    }

    // MARK: Menús

    private var fileMenu: [MenuEntry] {
        [
            MenuEntry(title: "Abrir ventana nueva") { state.newWindow() },
            MenuEntry(title: "Abrir pestaña nueva") { state.newTab(at: state.currentTab.url) },
            MenuEntry(title: "Abrir Terminal aquí", enabled: !tab.isThisPC) { state.openInTerminal() },
            .separator,
            MenuEntry(title: "Conectar a unidad de red…") { state.showConnectDialog() },
            .separator,
            MenuEntry(title: "Usar como explorador predeterminado", checked: prefs.isDefaultFolderHandler) {
                prefs.setAsDefaultFolderHandler(!prefs.isDefaultFolderHandler) { error in
                    if let error { state.alertMessage = error.localizedDescription }
                }
            },
            .separator,
            MenuEntry(title: "Buscar actualizaciones…") { UpdateChecker.check(manual: true) },
            MenuEntry(title: "Buscar actualizaciones al abrir", checked: UpdateChecker.autoCheckEnabled) {
                UpdateChecker.autoCheckEnabled.toggle()
            },
            MenuEntry(title: "Acerca de PegasusExplorer") { AboutWindow.show() },
            MenuEntry(title: "Cerrar") { state.window?.performClose(nil) },
        ]
    }

    private var sortEntries: [MenuEntry] {
        let current = tab.currentSort
        var entries = SortField.allCases.map { field in
            MenuEntry(title: field.title, checked: current.field == field) {
                field.apply(to: tab, ascending: field.defaultAscending)
            }
        }
        entries.append(.separator)
        entries.append(MenuEntry(title: "Ascendente", checked: current.ascending) {
            current.field.apply(to: tab, ascending: true)
        })
        entries.append(MenuEntry(title: "Descendente", checked: !current.ascending) {
            current.field.apply(to: tab, ascending: false)
        })
        return entries
    }

    private func openEntries(_ urls: [URL]) -> [MenuEntry] {
        var entries = [MenuEntry(title: "Abrir") { state.open(urls) }]
        let files = urls.filter { !AppState.isFolder($0) }
        if let first = files.first {
            entries.append(.separator)
            if let app = NSWorkspace.shared.urlForApplication(toOpen: first) {
                entries.append(MenuEntry(title: "\(appName(app)) (predeterminada)", image: smallIcon(app)) {
                    state.open(files, with: app)
                })
            }
            for app in NSWorkspace.shared.urlsForApplications(toOpen: first).prefix(15)
            where app != NSWorkspace.shared.urlForApplication(toOpen: first) {
                entries.append(MenuEntry(title: appName(app), image: smallIcon(app)) { state.open(files, with: app) })
            }
            entries.append(.separator)
            entries.append(MenuEntry(title: "Elegir otra aplicación…") { state.chooseAppAndOpen(files) })
        }
        return entries
    }

    private func appName(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

// MARK: - Piezas de la cinta

struct RibbonGroup<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 2) { content }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
                Text(title)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.bottom, 3)
            }
            Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1).padding(.vertical, 6)
        }
    }
}

struct BigButton: View {
    let title: String
    let symbol: String
    let color: Color
    let enabled: Bool
    var isOn = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 22))
                    .foregroundColor(enabled ? color : .secondary)
                    .frame(height: 28)
                Text(title)
                    .font(.system(size: 11))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize()
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .frame(minWidth: 52, minHeight: 66, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 2)
                .fill(isOn ? Color.accentColor.opacity(0.22) : (hovering && enabled ? Color.accentColor.opacity(0.12) : .clear)))
            .overlay(RoundedRectangle(cornerRadius: 2)
                .stroke(hovering && enabled ? Color.accentColor.opacity(0.4) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovering = $0 }
    }
}

struct SmallButton: View {
    let title: String
    let symbol: String
    let enabled: Bool
    var isOn = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundColor(enabled ? .accentColor : .secondary)
                    .frame(width: 16)
                Text(title).font(.system(size: 11)).fixedSize()
            }
            .padding(.horizontal, 4)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 2)
                .fill(isOn ? Color.accentColor.opacity(0.22) : (hovering && enabled ? Color.accentColor.opacity(0.12) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovering = $0 }
    }
}
