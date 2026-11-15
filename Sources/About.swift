import SwiftUI

/// Ventana «Acerca de PegasusExplorer».
enum AboutWindow {
    private static var window: NSWindow?

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: AboutView())
        let created = NSWindow(contentViewController: hosting)
        created.title = "Acerca de PegasusExplorer"
        created.styleMask = [.titled, .closable]
        created.isReleasedWhenClosed = false
        created.center()
        created.makeKeyAndOrderFront(nil)
        window = created
    }
}

struct AboutView: View {
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            VStack(spacing: 4) {
                Text("PegasusExplorer").font(.title2).fontWeight(.semibold)
                Text("Versión \(version)").foregroundColor(.secondary)
                Button("Buscar actualizaciones…") { UpdateChecker.check(manual: true) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            Text("Un explorador de archivos al estilo de Windows para Macs con macOS 13 Ventura. Gratis y de código abierto.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(spacing: 6) {
                Text("Hecho por Fugaz").font(.headline)
                Text("Soy músico. Si te sirve este programa, escucha mi música y sígueme:")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                LinkButton(title: "Instagram", symbol: "camera.fill",
                           color: Color(red: 0.84, green: 0.16, blue: 0.47),
                           url: "https://www.instagram.com/fugaz6846/")
                LinkButton(title: "YouTube", symbol: "play.rectangle.fill",
                           color: Color(red: 0.93, green: 0.11, blue: 0.14),
                           url: "https://www.youtube.com/@fugaz6846")
                LinkButton(title: "Spotify", symbol: "music.note",
                           color: Color(red: 0.11, green: 0.73, blue: 0.33),
                           url: "https://open.spotify.com/intl-es/artist/6ZnJh7TjJC2RLkSjCuWiuu")
            }
            Text("@fugaz6846").font(.caption).foregroundColor(.secondary)

            Divider()

            VStack(spacing: 4) {
                Button("Código fuente en GitHub") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/Jonywaper/PegasusExplorer")!)
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                Text("Licencia AGPL-3.0 · Inspirado en OpenXplorer.\nNo está afiliado a Microsoft ni a Apple.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct LinkButton: View {
    let title: String
    let symbol: String
    let color: Color
    let url: String

    var body: some View {
        Button {
            if let link = URL(string: url) { NSWorkspace.shared.open(link) }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 20))
                Text(title).font(.caption).fontWeight(.medium)
            }
            .foregroundColor(.white)
            .frame(width: 96, height: 56)
            .background(RoundedRectangle(cornerRadius: 10).fill(color))
        }
        .buttonStyle(.plain)
        .help(url)
    }
}
