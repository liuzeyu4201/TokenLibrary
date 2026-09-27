import SwiftUI

/// Vector export glyph (box + up arrow), used in the editor overflow menu.
struct ExportGlyph: View {
    var body: some View {
        Image(systemName: "square.and.arrow.up")
            .symbolRenderingMode(.monochrome)
    }
}

struct LeftTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
