import SwiftUI

/// Paper and ink from the library mark: warm ivory and burgundy line art.
enum LibraryPalette {
    static let ink = Color(red: 94 / 255, green: 34 / 255, blue: 55 / 255)
    static let paper = Color(red: 232 / 255, green: 223 / 255, blue: 204 / 255)
}

/// Line icon in the same stroke as the toucan mark. `name` accepts the existing symbol names.
struct InkGlyph: View {
    var name: String
    var body: some View {
        InkGlyphShape(name: name)
            .stroke(LibraryPalette.ink, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
            .padding(2)
            .aspectRatio(1, contentMode: .fit)
            .accessibilityHidden(true)
    }
}

/// Toolbar and form actions keep the full label inside the border.
struct InkButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: true)
            .padding(.horizontal, 14)
            .frame(minHeight: 32)
            .foregroundStyle(prominent ? LibraryPalette.paper : LibraryPalette.ink)
            .background(prominent ? LibraryPalette.ink : LibraryPalette.paper, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(LibraryPalette.ink.opacity(prominent ? 0 : 0.28), lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.84 : 1)
            .layoutPriority(1)
    }
}

struct InkUnavailable<Extra: View>: View {
    var title: String
    var symbol: String
    var message: String
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        ContentUnavailableView {
            VStack(spacing: 12) {
                InkGlyph(name: symbol).frame(width: 44, height: 44)
                Text(title).font(.title3.weight(.semibold))
            }
        } description: {
            Text(message)
        } actions: {
            extra()
        }
    }
}

extension Label where Title == Text, Icon == InkGlyph {
    init(_ title: String, ink: String) {
        self.init { Text(title) } icon: { InkGlyph(name: ink) }
    }
}

/// Vector export glyph used in the editor overflow menu.
struct ExportGlyph: View {
    var body: some View {
        InkGlyph(name: "square.and.arrow.up")
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

private struct InkGlyphShape: Shape {
    var name: String
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        let path = glyph(name)
        let scale = side / 24
        let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: origin.x, ty: origin.y)
        return path.applying(transform)
    }

    private func glyph(_ name: String) -> Path {
        switch name {
        case "folder", "folder.badge.plus": return folder(plus: name.contains("plus"))
        case "doc", "doc.richtext", "note.text": return page(lines: 3)
        case "books.vertical", "book": return books()
        case "doc.text.magnifyingglass": return pageSearch()
        case "square.grid.2x2": return grid()
        case "tray": return tray()
        case "archivebox": return archive()
        case "square.stack.3d.up": return stack()
        case "magnifyingglass": return search()
        case "ellipsis", "ellipsis.circle": return dots(circled: name.contains("circle"))
        case "chevron.left": return chevron(left: true)
        case "chevron.right": return chevron(left: false)
        case "xmark.circle": return circled(cross())
        case "info.circle": return circled(infoMark())
        case "checkmark": return check()
        case "checkmark.circle": return circled(check())
        case "trash": return trash()
        case "pencil.tip", "square.and.pencil": return pencil()
        case "square.and.arrow.up": return upload()
        case "line.3.horizontal.decrease.circle": return filter()
        case "link.badge.plus": return link()
        case "externaldrive.badge.exclamationmark", "exclamationmark.triangle": return warning()
        case "arrow.uturn.backward": return back()
        case "photo": return photo()
        case "plus.circle.fill": return circled(plus())
        case "play.circle.fill": return circled(play())
        case "stop.circle.fill": return circled(stopSquare())
        case "mic": return mic()
        default: return page(lines: 3)
        }
    }

    private func folder(plus: Bool) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 3, y: 8))
        p.addLine(to: CGPoint(x: 3, y: 20))
        p.addLine(to: CGPoint(x: 21, y: 20))
        p.addLine(to: CGPoint(x: 21, y: 8))
        p.addLine(to: CGPoint(x: 11, y: 8))
        p.addLine(to: CGPoint(x: 9, y: 5))
        p.addLine(to: CGPoint(x: 3, y: 5))
        p.closeSubpath()
        if plus {
            p.move(to: CGPoint(x: 12, y: 11)); p.addLine(to: CGPoint(x: 12, y: 17))
            p.move(to: CGPoint(x: 9, y: 14)); p.addLine(to: CGPoint(x: 15, y: 14))
        }
        return p
    }

    private func page(lines: Int) -> Path {
        var p = Path()
        p.addRoundedRect(in: CGRect(x: 5, y: 3, width: 14, height: 18), cornerSize: CGSize(width: 1.5, height: 1.5))
        for index in 0..<lines {
            let y = 8 + CGFloat(index) * 3.4
            p.move(to: CGPoint(x: 8, y: y))
            p.addLine(to: CGPoint(x: index == lines - 1 ? 13 : 16, y: y))
        }
        return p
    }

    private func books() -> Path {
        var p = page(lines: 2)
        p.addRoundedRect(in: CGRect(x: 8, y: 5, width: 13, height: 16), cornerSize: CGSize(width: 1.5, height: 1.5))
        return p
    }

    private func pageSearch() -> Path {
        var p = page(lines: 2)
        p.addEllipse(in: CGRect(x: 12, y: 12, width: 6, height: 6))
        p.move(to: CGPoint(x: 16.5, y: 16.5)); p.addLine(to: CGPoint(x: 19, y: 19))
        return p
    }

    private func grid() -> Path {
        var p = Path()
        p.addRoundedRect(in: CGRect(x: 3, y: 3, width: 8, height: 8), cornerSize: CGSize(width: 1, height: 1))
        p.addRoundedRect(in: CGRect(x: 13, y: 3, width: 8, height: 8), cornerSize: CGSize(width: 1, height: 1))
        p.addRoundedRect(in: CGRect(x: 3, y: 13, width: 8, height: 8), cornerSize: CGSize(width: 1, height: 1))
        p.addRoundedRect(in: CGRect(x: 13, y: 13, width: 8, height: 8), cornerSize: CGSize(width: 1, height: 1))
        return p
    }

    private func tray() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 4, y: 8))
        p.addLine(to: CGPoint(x: 4, y: 18))
        p.addLine(to: CGPoint(x: 20, y: 18))
        p.addLine(to: CGPoint(x: 20, y: 8))
        p.move(to: CGPoint(x: 4, y: 13))
        p.addLine(to: CGPoint(x: 9, y: 13))
        p.addLine(to: CGPoint(x: 10.5, y: 15))
        p.addLine(to: CGPoint(x: 13.5, y: 15))
        p.addLine(to: CGPoint(x: 15, y: 13))
        p.addLine(to: CGPoint(x: 20, y: 13))
        return p
    }

    private func archive() -> Path {
        var p = Path()
        p.addRoundedRect(in: CGRect(x: 4, y: 4, width: 16, height: 5), cornerSize: CGSize(width: 1, height: 1))
        p.move(to: CGPoint(x: 5, y: 9)); p.addLine(to: CGPoint(x: 5, y: 20)); p.addLine(to: CGPoint(x: 19, y: 20)); p.addLine(to: CGPoint(x: 19, y: 9))
        p.move(to: CGPoint(x: 9, y: 14)); p.addLine(to: CGPoint(x: 15, y: 14))
        return p
    }

    private func stack() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 6, y: 7)); p.addLine(to: CGPoint(x: 18, y: 7)); p.addLine(to: CGPoint(x: 18, y: 18)); p.addLine(to: CGPoint(x: 6, y: 18)); p.closeSubpath()
        p.move(to: CGPoint(x: 8, y: 7)); p.addLine(to: CGPoint(x: 8, y: 4)); p.addLine(to: CGPoint(x: 20, y: 4)); p.addLine(to: CGPoint(x: 20, y: 15)); p.addLine(to: CGPoint(x: 18, y: 15))
        return p
    }

    private func search() -> Path {
        var p = Path()
        p.addEllipse(in: CGRect(x: 4, y: 4, width: 11, height: 11))
        p.move(to: CGPoint(x: 13.5, y: 13.5)); p.addLine(to: CGPoint(x: 20, y: 20))
        return p
    }

    private func dots(circled: Bool) -> Path {
        var p = Path()
        if circled { p.addEllipse(in: CGRect(x: 2.5, y: 2.5, width: 19, height: 19)) }
        for x in [7.0, 12.0, 17.0] { p.addEllipse(in: CGRect(x: x - 0.8, y: 11.2, width: 1.6, height: 1.6)) }
        return p
    }

    private func chevron(left: Bool) -> Path {
        var p = Path()
        if left {
            p.move(to: CGPoint(x: 14, y: 5)); p.addLine(to: CGPoint(x: 8, y: 12)); p.addLine(to: CGPoint(x: 14, y: 19))
        } else {
            p.move(to: CGPoint(x: 10, y: 5)); p.addLine(to: CGPoint(x: 16, y: 12)); p.addLine(to: CGPoint(x: 10, y: 19))
        }
        return p
    }

    private func circled(_ extra: Path) -> Path {
        var p = Path()
        p.addEllipse(in: CGRect(x: 2.5, y: 2.5, width: 19, height: 19))
        p.addPath(extra)
        return p
    }

    private func cross() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 8, y: 8)); p.addLine(to: CGPoint(x: 16, y: 16))
        p.move(to: CGPoint(x: 16, y: 8)); p.addLine(to: CGPoint(x: 8, y: 16))
        return p
    }

    private func infoMark() -> Path {
        var p = Path()
        p.addEllipse(in: CGRect(x: 11.2, y: 6.2, width: 1.6, height: 1.6))
        p.move(to: CGPoint(x: 12, y: 10)); p.addLine(to: CGPoint(x: 12, y: 17))
        return p
    }

    private func check() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 5, y: 12.5)); p.addLine(to: CGPoint(x: 10, y: 17.5)); p.addLine(to: CGPoint(x: 19, y: 7))
        return p
    }

    private func plus() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 12, y: 7)); p.addLine(to: CGPoint(x: 12, y: 17))
        p.move(to: CGPoint(x: 7, y: 12)); p.addLine(to: CGPoint(x: 17, y: 12))
        return p
    }

    private func play() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 10, y: 8)); p.addLine(to: CGPoint(x: 16, y: 12)); p.addLine(to: CGPoint(x: 10, y: 16)); p.closeSubpath()
        return p
    }

    private func stopSquare() -> Path {
        var p = Path()
        p.addRoundedRect(in: CGRect(x: 8, y: 8, width: 8, height: 8), cornerSize: CGSize(width: 1, height: 1))
        return p
    }

    private func trash() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 5, y: 7)); p.addLine(to: CGPoint(x: 19, y: 7))
        p.move(to: CGPoint(x: 9, y: 7)); p.addLine(to: CGPoint(x: 9, y: 4)); p.addLine(to: CGPoint(x: 15, y: 4)); p.addLine(to: CGPoint(x: 15, y: 7))
        p.move(to: CGPoint(x: 7, y: 7)); p.addLine(to: CGPoint(x: 8, y: 20)); p.addLine(to: CGPoint(x: 16, y: 20)); p.addLine(to: CGPoint(x: 17, y: 7))
        return p
    }

    private func pencil() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 14, y: 4)); p.addLine(to: CGPoint(x: 20, y: 10)); p.addLine(to: CGPoint(x: 9, y: 21)); p.addLine(to: CGPoint(x: 3, y: 21)); p.addLine(to: CGPoint(x: 3, y: 15)); p.closeSubpath()
        p.move(to: CGPoint(x: 12, y: 6)); p.addLine(to: CGPoint(x: 18, y: 12))
        return p
    }

    private func upload() -> Path {
        var p = Path()
        p.addRoundedRect(in: CGRect(x: 4, y: 10, width: 16, height: 10), cornerSize: CGSize(width: 1.5, height: 1.5))
        p.move(to: CGPoint(x: 12, y: 16)); p.addLine(to: CGPoint(x: 12, y: 3))
        p.move(to: CGPoint(x: 8, y: 7)); p.addLine(to: CGPoint(x: 12, y: 3)); p.addLine(to: CGPoint(x: 16, y: 7))
        return p
    }

    private func filter() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 4, y: 7)); p.addLine(to: CGPoint(x: 20, y: 7))
        p.move(to: CGPoint(x: 7, y: 12)); p.addLine(to: CGPoint(x: 17, y: 12))
        p.move(to: CGPoint(x: 10, y: 17)); p.addLine(to: CGPoint(x: 14, y: 17))
        return p
    }

    private func link() -> Path {
        var p = Path()
        p.addRoundedRect(in: CGRect(x: 3, y: 9, width: 8, height: 6), cornerSize: CGSize(width: 3, height: 3))
        p.addRoundedRect(in: CGRect(x: 13, y: 9, width: 8, height: 6), cornerSize: CGSize(width: 3, height: 3))
        p.move(to: CGPoint(x: 10, y: 12)); p.addLine(to: CGPoint(x: 14, y: 12))
        return p
    }

    private func warning() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 12, y: 3)); p.addLine(to: CGPoint(x: 22, y: 20)); p.addLine(to: CGPoint(x: 2, y: 20)); p.closeSubpath()
        p.move(to: CGPoint(x: 12, y: 9)); p.addLine(to: CGPoint(x: 12, y: 14))
        p.addEllipse(in: CGRect(x: 11.2, y: 16.2, width: 1.6, height: 1.6))
        return p
    }

    private func back() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 9, y: 7)); p.addLine(to: CGPoint(x: 4, y: 12)); p.addLine(to: CGPoint(x: 9, y: 17))
        p.move(to: CGPoint(x: 4, y: 12)); p.addLine(to: CGPoint(x: 14, y: 12))
        p.addArc(center: CGPoint(x: 14, y: 8), radius: 4, startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
        return p
    }

    private func photo() -> Path {
        var p = Path()
        p.addRoundedRect(in: CGRect(x: 3, y: 5, width: 18, height: 14), cornerSize: CGSize(width: 1.5, height: 1.5))
        p.addEllipse(in: CGRect(x: 7, y: 8, width: 3, height: 3))
        p.move(to: CGPoint(x: 4, y: 16)); p.addLine(to: CGPoint(x: 9, y: 12)); p.addLine(to: CGPoint(x: 13, y: 15)); p.addLine(to: CGPoint(x: 16, y: 13)); p.addLine(to: CGPoint(x: 20, y: 16))
        return p
    }

    private func mic() -> Path {
        var p = Path()
        p.addRoundedRect(in: CGRect(x: 9, y: 3, width: 6, height: 11), cornerSize: CGSize(width: 3, height: 3))
        p.move(to: CGPoint(x: 7, y: 11)); p.addQuadCurve(to: CGPoint(x: 17, y: 11), control: CGPoint(x: 12, y: 19))
        p.move(to: CGPoint(x: 12, y: 17)); p.addLine(to: CGPoint(x: 12, y: 21))
        p.move(to: CGPoint(x: 8, y: 21)); p.addLine(to: CGPoint(x: 16, y: 21))
        return p
    }
}
