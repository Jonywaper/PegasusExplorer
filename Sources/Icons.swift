import SwiftUI

/// Carpeta amarilla al estilo de Windows (en lugar de la azul de macOS).
struct WindowsFolderIcon: View {
    var size: CGFloat = 16
    var symbol: String?

    var body: some View {
        ZStack {
            Canvas { ctx, sz in
                let w = sz.width, h = sz.height
                // Parte trasera con la pestaña.
                var back = Path()
                back.move(to: CGPoint(x: 0.06 * w, y: 0.20 * h))
                back.addLine(to: CGPoint(x: 0.38 * w, y: 0.20 * h))
                back.addLine(to: CGPoint(x: 0.47 * w, y: 0.29 * h))
                back.addLine(to: CGPoint(x: 0.94 * w, y: 0.29 * h))
                back.addLine(to: CGPoint(x: 0.94 * w, y: 0.84 * h))
                back.addLine(to: CGPoint(x: 0.06 * w, y: 0.84 * h))
                back.closeSubpath()
                ctx.fill(back, with: .color(Color(red: 0.86, green: 0.63, blue: 0.16)))

                // Hoja de papel asomando.
                ctx.fill(Path(CGRect(x: 0.14 * w, y: 0.33 * h, width: 0.72 * w, height: 0.3 * h)),
                         with: .color(.white))

                // Parte delantera.
                let front = Path(roundedRect: CGRect(x: 0.06 * w, y: 0.40 * h, width: 0.88 * w, height: 0.44 * h),
                                 cornerRadius: max(1, 0.04 * w))
                ctx.fill(front, with: .linearGradient(
                    Gradient(colors: [Color(red: 1.0, green: 0.86, blue: 0.45), Color(red: 0.98, green: 0.76, blue: 0.28)]),
                    startPoint: CGPoint(x: 0, y: 0.40 * h), endPoint: CGPoint(x: 0, y: 0.84 * h)))
            }
            if let symbol, size >= 28 {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.24, weight: .semibold))
                    .foregroundColor(Color(red: 0.15, green: 0.45, blue: 0.85))
                    .offset(y: size * 0.12)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Ícono de un elemento: carpeta amarilla o el ícono del sistema para archivos y apps.
struct ItemIcon: View {
    let item: FileItem
    var size: CGFloat = 16

    var body: some View {
        if item.isDirectory {
            WindowsFolderIcon(size: size, symbol: KnownFolder.matching(item.url)?.symbol)
        } else {
            Image(nsImage: IconCache.shared.icon(for: item.url))
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        }
    }
}

/// Puntos de colores de las etiquetas de Finder.
struct TagDots: View {
    let tags: [String]

    var body: some View {
        HStack(spacing: -3) {
            ForEach(tags.prefix(3), id: \.self) { tag in
                if let color = FinderTags.color(for: tag) {
                    Circle()
                        .fill(Color(nsColor: color))
                        .overlay(Circle().stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 1))
                        .frame(width: 9, height: 9)
                }
            }
        }
    }
}

/// Ícono de un disco.
struct DriveIcon: View {
    let volume: Volume
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: IconCache.shared.icon(for: volume.url))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}
