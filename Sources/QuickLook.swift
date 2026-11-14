import Quartz
import SwiftUI

/// Vista rápida de Finder (barra espaciadora).
final class QuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLook()
    private var urls: [URL] = []

    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && (QLPreviewPanel.shared()?.isVisible ?? false)
    }

    func toggle(_ urls: [URL]) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if isVisible {
            panel.orderOut(nil)
            return
        }
        guard !urls.isEmpty else { return }
        self.urls = urls
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Si la Vista rápida está abierta, la actualiza al cambiar la selección.
    func update(_ urls: [URL]) {
        guard isVisible, !urls.isEmpty, urls != self.urls else { return }
        self.urls = urls
        QLPreviewPanel.shared()?.reloadData()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls[index] as NSURL
    }
}

/// Panel de vista previa (Alt+P en Windows), a la derecha de la lista.
struct PreviewPane: View {
    let url: URL?

    var body: some View {
        VStack(spacing: 0) {
            if let url {
                QuickLookView(url: url)
                Divider()
                Text(url.lastPathComponent)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(8)
            } else {
                Spacer()
                Text("Selecciona un archivo para obtener una vista previa.")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.shouldCloseWithWindow = false
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url {
            view.previewItem = url as NSURL
        }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}
