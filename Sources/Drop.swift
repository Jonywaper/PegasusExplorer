import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Soltar archivos en una carpeta (desde el Finder, el Escritorio, otra ventana o la misma lista).
/// Dentro del mismo disco se mueven y entre discos se copian, como en Windows; con ⌥ siempre se copian.
struct FileDropDelegate: DropDelegate {
    let folder: URL
    let state: AppState
    @Binding var targeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        folder.isFileURL && info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) { targeted = true }
    func dropExited(info: DropInfo) { targeted = false }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: NSEvent.modifierFlags.contains(.option) ? .copy : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        let forceCopy = NSEvent.modifierFlags.contains(.option)
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        let folder = folder, state = state
        group.notify(queue: .main) {
            debugLog("soltar \(urls.count) en \(folder.path) (copiar: \(forceCopy))")
            state.drop(urls, into: folder, forceCopy: forceCopy)
        }
        return true
    }
}

/// Marca una vista como lugar donde soltar archivos y la resalta mientras se arrastra encima.
struct FolderDropTarget: ViewModifier {
    let folder: URL
    let state: AppState
    var cornerRadius: CGFloat = 3
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.accentColor.opacity(0.15))
                    .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(Color.accentColor, lineWidth: 2))
                    .opacity(targeted ? 1 : 0)
                    .allowsHitTesting(false))
            .onDrop(of: [.fileURL], delegate: FileDropDelegate(folder: folder, state: state, targeted: $targeted))
    }
}

extension View {
    /// Solo las carpetas aceptan archivos; para lo demás no cambia nada.
    @ViewBuilder
    func dropTarget(_ folder: URL?, state: AppState, cornerRadius: CGFloat = 3) -> some View {
        if let folder {
            modifier(FolderDropTarget(folder: folder, state: state, cornerRadius: cornerRadius))
        } else {
            self
        }
    }
}
