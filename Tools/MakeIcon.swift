// Dibuja el ícono de PegasusExplorer (el elegido es «cara»).
// Uso: swift Tools/MakeIcon.swift <carpeta.iconset> [estilo]   (luego: iconutil -c icns <carpeta.iconset>)
// Estilos: "cara" (dos tonos con el perfil de un Pegaso sonriente), "caballo" (Pegaso de lado), "carpeta" (carpeta con ala).
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
let style = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "cara"
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Dibuja el ícono en un lienzo de 1024 × 1024 (origen abajo a la izquierda).
func drawIcon() {
    switch style {
    case "cara": drawPegasusFace()
    case "caballo": drawPegasusSide()
    default: drawFolderIcon()
    }
}

/// Opción «carpeta»: carpeta amarilla estilo Windows con un ala blanca.
func drawFolderIcon() {
    // Fondo: cuadrado redondeado con un cielo azul (la cuadrícula estándar de macOS deja 100 px de margen).
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGradient(starting: color(0x6CB8FF), ending: color(0x1E5BC6))!.draw(in: tile, angle: -90)

    // Brillo suave en la parte superior.
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    let glow = NSBezierPath(ovalIn: NSRect(x: 120, y: 560, width: 784, height: 520))
    color(0xFFFFFF, 0.12).setFill()
    glow.fill()
    NSGraphicsContext.restoreGraphicsState()

    let shadow = NSShadow()
    shadow.shadowColor = color(0x0A2A66, 0.45)
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.shadowBlurRadius = 28

    // Ala (detrás de la carpeta, saliendo hacia arriba a la derecha).
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    drawWing()
    NSGraphicsContext.restoreGraphicsState()

    // Carpeta.
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    let back = NSBezierPath()
    back.move(to: NSPoint(x: 210, y: 230))
    back.line(to: NSPoint(x: 210, y: 640))
    back.curve(to: NSPoint(x: 240, y: 670), controlPoint1: NSPoint(x: 210, y: 658), controlPoint2: NSPoint(x: 222, y: 670))
    back.line(to: NSPoint(x: 430, y: 670))
    back.line(to: NSPoint(x: 490, y: 610))
    back.line(to: NSPoint(x: 780, y: 610))
    back.curve(to: NSPoint(x: 810, y: 580), controlPoint1: NSPoint(x: 798, y: 610), controlPoint2: NSPoint(x: 810, y: 598))
    back.line(to: NSPoint(x: 810, y: 230))
    back.close()
    color(0xD99A1E).setFill()
    back.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Hoja de papel.
    let paper = NSBezierPath(roundedRect: NSRect(x: 250, y: 400, width: 520, height: 190), xRadius: 10, yRadius: 10)
    color(0xFFFFFF).setFill()
    paper.fill()
    color(0xE6E6E6).setFill()
    NSBezierPath(rect: NSRect(x: 290, y: 540, width: 300, height: 14)).fill()
    NSBezierPath(rect: NSRect(x: 290, y: 505, width: 400, height: 14)).fill()

    // Frente de la carpeta.
    let front = NSBezierPath(roundedRect: NSRect(x: 210, y: 230, width: 600, height: 330), xRadius: 26, yRadius: 26)
    NSGradient(starting: color(0xFFDD70), ending: color(0xF7B92E))!.draw(in: front, angle: -90)
    color(0xFFFFFF, 0.35).setStroke()
    let edge = NSBezierPath()
    edge.move(to: NSPoint(x: 236, y: 548))
    edge.line(to: NSPoint(x: 784, y: 548))
    edge.lineWidth = 6
    edge.stroke()
}

/// Una pluma: redondeada en la base y terminada en punta hacia arriba a la derecha.
func feather(x: CGFloat, y: CGFloat, length: CGFloat, height: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    let r = height / 2
    p.move(to: NSPoint(x: x + r, y: y))
    p.line(to: NSPoint(x: x + length - height * 1.2, y: y))
    p.curve(to: NSPoint(x: x + length, y: y + height * 1.25),
            controlPoint1: NSPoint(x: x + length - height * 0.35, y: y),
            controlPoint2: NSPoint(x: x + length - height * 0.05, y: y + height * 0.55))
    p.curve(to: NSPoint(x: x + length - height * 1.1, y: y + height),
            controlPoint1: NSPoint(x: x + length - height * 0.4, y: y + height * 1.05),
            controlPoint2: NSPoint(x: x + length - height * 0.7, y: y + height))
    p.line(to: NSPoint(x: x + r, y: y + height))
    p.appendArc(withCenter: NSPoint(x: x + r, y: y + r), radius: r, startAngle: 90, endAngle: 270)
    p.close()
    return p
}

/// Ala estilizada: tres plumas escalonadas unidas por el hombro, saliendo de detrás de la carpeta.
func drawWing() {
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: 560, yBy: 520)
    transform.rotate(byDegrees: 14)
    transform.concat()

    // Coordenadas locales: el hombro a la izquierda, las plumas hacia la derecha (la más larga arriba).
    let shoulder = NSBezierPath(ovalIn: NSRect(x: -50, y: 0, width: 160, height: 270))
    let feathers = [
        feather(x: 0, y: 190, length: 350, height: 74),
        feather(x: 0, y: 100, length: 290, height: 74),
        feather(x: 0, y: 10, length: 220, height: 74),
    ]
    let parts = [shoulder] + feathers

    // Contorno: primero un trazo grueso de todas las piezas y luego el relleno encima,
    // así queda un solo borde alrededor de la silueta completa.
    color(0x2D5FA8, 0.9).setStroke()
    for part in parts {
        part.lineWidth = 16
        part.lineJoinStyle = .round
        part.stroke()
    }
    let shades: [UInt32] = [0xF2F6FD, 0xFFFFFF, 0xF7FAFF, 0xEEF4FD]
    for (index, part) in parts.enumerated() {
        color(shades[index]).setFill()
        part.fill()
    }
    // Líneas suaves entre plumas.
    color(0xC2D3EC).setFill()
    NSBezierPath(roundedRect: NSRect(x: 70, y: 180, width: 200, height: 9), xRadius: 4.5, yRadius: 4.5).fill()
    NSBezierPath(roundedRect: NSRect(x: 70, y: 90, width: 150, height: 9), xRadius: 4.5, yRadius: 4.5).fill()

    NSGraphicsContext.restoreGraphicsState()
}

let tileRect = NSRect(x: 100, y: 100, width: 824, height: 824)
var tilePath: NSBezierPath { NSBezierPath(roundedRect: tileRect, xRadius: 185, yRadius: 185) }

/// Dibuja las piezas como una sola silueta: primero el borde de todas y luego el relleno encima.
func drawSilhouette(_ parts: [NSBezierPath], fill: NSColor, outline: NSColor, width: CGFloat) {
    outline.setStroke()
    for part in parts {
        part.lineWidth = width
        part.lineJoinStyle = .round
        part.lineCapStyle = .round
        part.stroke()
    }
    fill.setFill()
    for part in parts { part.fill() }
}

/// Ala de plumas en coordenadas locales (hombro en 0,0; plumas hacia la derecha).
func wingParts() -> [NSBezierPath] {
    [
        NSBezierPath(ovalIn: NSRect(x: -50, y: 0, width: 160, height: 270)),
        feather(x: 0, y: 190, length: 350, height: 74),
        feather(x: 0, y: 100, length: 290, height: 74),
        feather(x: 0, y: 10, length: 220, height: 74),
    ]
}

func withTransform(x: CGFloat, y: CGFloat, rotate: CGFloat = 0, scale: CGFloat = 1, flip: Bool = false, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform()
    t.translateX(by: x, yBy: y)
    t.rotate(byDegrees: rotate)
    t.scaleX(by: flip ? -scale : scale, yBy: scale)
    t.concat()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

/// Opción «cara»: el cuadrado partido en dos azules, como el ícono de Finder, pero la línea
/// que los separa es el perfil de un Pegaso sonriente mirando a la izquierda.
func drawPegasusFace() {
    let tile = tilePath
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()

    // Lado claro (fondo).
    NSGradient(starting: color(0xB8E6FF), ending: color(0x5DB4F5))!.draw(in: tileRect, angle: -90)

    // Lado oscuro: la cabeza y el cuello del Pegaso, de la línea del perfil hacia la derecha.
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 640, y: 940))
    head.curve(to: NSPoint(x: 600, y: 800), controlPoint1: NSPoint(x: 610, y: 890), controlPoint2: NSPoint(x: 600, y: 840))
    // Oreja.
    head.curve(to: NSPoint(x: 520, y: 880), controlPoint1: NSPoint(x: 570, y: 830), controlPoint2: NSPoint(x: 530, y: 860))
    head.curve(to: NSPoint(x: 505, y: 760), controlPoint1: NSPoint(x: 500, y: 850), controlPoint2: NSPoint(x: 495, y: 800))
    // Frente y caña nasal, bajando en diagonal hasta el hocico.
    head.curve(to: NSPoint(x: 330, y: 500), controlPoint1: NSPoint(x: 450, y: 700), controlPoint2: NSPoint(x: 360, y: 590))
    // Hocico redondeado.
    head.curve(to: NSPoint(x: 330, y: 360), controlPoint1: NSPoint(x: 290, y: 460), controlPoint2: NSPoint(x: 280, y: 390))
    // Barbilla y mandíbula.
    head.curve(to: NSPoint(x: 470, y: 350), controlPoint1: NSPoint(x: 370, y: 335), controlPoint2: NSPoint(x: 420, y: 330))
    head.curve(to: NSPoint(x: 560, y: 420), controlPoint1: NSPoint(x: 520, y: 365), controlPoint2: NSPoint(x: 545, y: 390))
    // Garganta y cuello hasta abajo.
    head.curve(to: NSPoint(x: 520, y: 80), controlPoint1: NSPoint(x: 560, y: 300), controlPoint2: NSPoint(x: 520, y: 200))
    head.line(to: NSPoint(x: 940, y: 80))
    head.line(to: NSPoint(x: 940, y: 940))
    head.close()
    NSGradient(starting: color(0x2F8BEA), ending: color(0x1449B8))!.draw(in: head, angle: -90)

    // Crin: mechones más claros a lo largo del cuello.
    color(0x5CA8F5, 0.85).setFill()
    for (i, y) in [860.0, 760.0, 660.0, 560.0].enumerated() {
        let lock = NSBezierPath()
        let x = 700.0 + Double(i) * 18
        lock.move(to: NSPoint(x: x, y: y + 70))
        lock.curve(to: NSPoint(x: x + 70, y: y - 60), controlPoint1: NSPoint(x: x + 70, y: y + 40), controlPoint2: NSPoint(x: x + 90, y: y - 10))
        lock.curve(to: NSPoint(x: x, y: y + 70), controlPoint1: NSPoint(x: x + 30, y: y - 10), controlPoint2: NSPoint(x: x + 10, y: y + 20))
        lock.fill()
    }

    // Ojo feliz (arco cerrado, como sonriendo con los ojos).
    let eye = NSBezierPath()
    eye.move(to: NSPoint(x: 465, y: 650))
    eye.curve(to: NSPoint(x: 545, y: 650), controlPoint1: NSPoint(x: 480, y: 695), controlPoint2: NSPoint(x: 530, y: 695))
    eye.lineWidth = 22
    eye.lineCapStyle = .round
    color(0xFFFFFF).setStroke()
    eye.stroke()

    // Fosa nasal.
    color(0x0E3A8C).setFill()
    NSBezierPath(ovalIn: NSRect(x: 335, y: 430, width: 34, height: 22)).fill()

    // Sonrisa.
    let smile = NSBezierPath()
    smile.move(to: NSPoint(x: 335, y: 395))
    smile.curve(to: NSPoint(x: 440, y: 400), controlPoint1: NSPoint(x: 360, y: 360), controlPoint2: NSPoint(x: 415, y: 360))
    smile.lineWidth = 18
    smile.lineCapStyle = .round
    color(0xFFFFFF).setStroke()
    smile.stroke()

    // Ala blanca en el cuello.
    let shadow = NSShadow()
    shadow.shadowColor = color(0x0A2A66, 0.4)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 22
    withTransform(x: 650, y: 140, rotate: 10, scale: 0.72) {
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        drawSilhouette(wingParts(), fill: color(0xFFFFFF), outline: color(0x1449B8), width: 16)
        NSGraphicsContext.restoreGraphicsState()
        color(0xC2D3EC).setFill()
        NSBezierPath(roundedRect: NSRect(x: 70, y: 180, width: 200, height: 9), xRadius: 4.5, yRadius: 4.5).fill()
        NSBezierPath(roundedRect: NSRect(x: 70, y: 90, width: 150, height: 9), xRadius: 4.5, yRadius: 4.5).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
}

/// Opción «caballo»: un Pegaso blanco de cuerpo entero, de lado, sobre un cielo azul.
func drawPegasusSide() {
    let tile = tilePath
    NSGradient(starting: color(0x7FC8FF), ending: color(0x2163CF))!.draw(in: tile, angle: -90)

    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    // Nubes.
    color(0xFFFFFF, 0.35).setFill()
    for r in [NSRect(x: 150, y: 700, width: 220, height: 70), NSRect(x: 210, y: 735, width: 140, height: 80),
              NSRect(x: 690, y: 210, width: 230, height: 60), NSRect(x: 740, y: 240, width: 120, height: 70)] {
        NSBezierPath(ovalIn: r).fill()
    }
    // Sombra en el suelo.
    color(0x0A2A66, 0.25).setFill()
    NSBezierPath(ovalIn: NSRect(x: 280, y: 175, width: 470, height: 50)).fill()
    NSGraphicsContext.restoreGraphicsState()

    let outline = color(0x173E8A)
    let white = color(0xFFFFFF)

    // Ala lejana (detrás del cuerpo).
    withTransform(x: 470, y: 520, rotate: 62, scale: 0.85) {
        drawSilhouette(wingParts(), fill: color(0xDCE8FA), outline: outline, width: 18)
    }

    // Cuerpo, cuello, cabeza, patas y cola como una sola silueta.
    let body = NSBezierPath(roundedRect: NSRect(x: 330, y: 400, width: 380, height: 170), xRadius: 85, yRadius: 85)

    let neck = NSBezierPath()
    neck.move(to: NSPoint(x: 600, y: 540))
    neck.curve(to: NSPoint(x: 700, y: 770), controlPoint1: NSPoint(x: 630, y: 640), controlPoint2: NSPoint(x: 660, y: 730))
    neck.line(to: NSPoint(x: 790, y: 730))
    neck.curve(to: NSPoint(x: 710, y: 470), controlPoint1: NSPoint(x: 760, y: 640), controlPoint2: NSPoint(x: 730, y: 540))
    neck.close()

    // Cabeza inclinada hacia abajo y adelante.
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 690, y: 790))
    head.curve(to: NSPoint(x: 800, y: 790), controlPoint1: NSPoint(x: 720, y: 830), controlPoint2: NSPoint(x: 775, y: 825))
    head.curve(to: NSPoint(x: 885, y: 640), controlPoint1: NSPoint(x: 835, y: 750), controlPoint2: NSPoint(x: 880, y: 690))
    head.curve(to: NSPoint(x: 835, y: 610), controlPoint1: NSPoint(x: 888, y: 610), controlPoint2: NSPoint(x: 860, y: 600))
    head.curve(to: NSPoint(x: 720, y: 700), controlPoint1: NSPoint(x: 800, y: 625), controlPoint2: NSPoint(x: 750, y: 660))
    head.close()

    let ear = NSBezierPath()
    ear.move(to: NSPoint(x: 715, y: 800))
    ear.line(to: NSPoint(x: 735, y: 875))
    ear.line(to: NSPoint(x: 765, y: 805))
    ear.close()

    func leg(_ x: CGFloat, _ bottom: CGFloat, angle: CGFloat = 0) -> NSBezierPath {
        let p = NSBezierPath(roundedRect: NSRect(x: -24, y: 0, width: 48, height: 470 - bottom), xRadius: 24, yRadius: 24)
        let t = NSAffineTransform()
        t.translateX(by: x, yBy: bottom)
        t.rotate(byDegrees: angle)
        p.transform(using: t as AffineTransform)
        return p
    }
    let legs = [leg(390, 215, angle: -8), leg(455, 215, angle: 6), leg(615, 215, angle: -4), leg(675, 230, angle: 12)]

    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: 345, y: 540))
    tail.curve(to: NSPoint(x: 220, y: 330), controlPoint1: NSPoint(x: 250, y: 560), controlPoint2: NSPoint(x: 200, y: 440))
    tail.curve(to: NSPoint(x: 300, y: 470), controlPoint1: NSPoint(x: 260, y: 390), controlPoint2: NSPoint(x: 270, y: 440))
    tail.curve(to: NSPoint(x: 345, y: 490), controlPoint1: NSPoint(x: 320, y: 485), controlPoint2: NSPoint(x: 335, y: 490))
    tail.close()

    let shadow = NSShadow()
    shadow.shadowColor = color(0x0A2A66, 0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 24
    // Crin: una franja azul claro que asoma por detrás del cuello.
    let mane = NSBezierPath()
    mane.move(to: NSPoint(x: 712, y: 815))
    mane.curve(to: NSPoint(x: 590, y: 545), controlPoint1: NSPoint(x: 640, y: 760), controlPoint2: NSPoint(x: 600, y: 650))
    mane.lineCapStyle = .round
    mane.lineWidth = 92
    outline.setStroke()
    mane.stroke()
    mane.lineWidth = 64
    color(0x8EC5FF).setStroke()
    mane.stroke()

    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    drawSilhouette([tail, body, neck, head, ear] + legs, fill: white, outline: outline, width: 18)
    NSGraphicsContext.restoreGraphicsState()

    // Cascos.
    color(0x3A4F7A).setFill()
    for (x, angle) in [(390.0, -8.0), (455.0, 6.0), (615.0, -4.0), (675.0, 12.0)] {
        let bottom: CGFloat = x == 675 ? 230 : 215
        let hoof = NSBezierPath(roundedRect: NSRect(x: -24, y: 0, width: 48, height: 26), xRadius: 8, yRadius: 8)
        let t = NSAffineTransform()
        t.translateX(by: CGFloat(x), yBy: bottom)
        t.rotate(byDegrees: CGFloat(angle))
        hoof.transform(using: t as AffineTransform)
        hoof.fill()
    }

    // Ojo y fosa nasal.
    color(0x173E8A).setFill()
    NSBezierPath(ovalIn: NSRect(x: 760, y: 735, width: 30, height: 30)).fill()
    NSBezierPath(ovalIn: NSRect(x: 850, y: 640, width: 16, height: 12)).fill()

    // Ala cercana (delante del cuerpo).
    withTransform(x: 470, y: 520, rotate: 48, scale: 0.95) {
        drawSilhouette(wingParts(), fill: white, outline: outline, width: 18)
        color(0xC2D3EC).setFill()
        NSBezierPath(roundedRect: NSRect(x: 70, y: 180, width: 200, height: 9), xRadius: 4.5, yRadius: 4.5).fill()
        NSBezierPath(roundedRect: NSRect(x: 70, y: 90, width: 150, height: 9), xRadius: 4.5, yRadius: 4.5).fill()
    }
}

func render(_ pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let scale = NSAffineTransform()
    scale.scale(by: CGFloat(pixels) / 1024)
    scale.concat()
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name = factor == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        if let data = render(points * factor) {
            try data.write(to: output.appendingPathComponent(name))
        }
    }
}
print("Ícono generado en \(output.path)")
