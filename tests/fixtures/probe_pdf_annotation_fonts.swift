import Foundation
import PDFKit
import AppKit

let root = URL(fileURLWithPath: "/tmp/tokenlibrary-ui-fixtures")
let variants = ["System", "Default", "Helvetica", "ArialUnicodeMS", "PingFangSC-Regular", "STSongti-SC-Regular"]
for name in variants {
    guard let document = PDFDocument(url: root.appendingPathComponent("research-three-pages.pdf")),
          let page = document.page(at: 0) else { fatalError("fixture missing") }
    let note = PDFAnnotation(bounds: CGRect(x: 55, y: 95, width: 490, height: 64), forType: .freeText, withProperties: nil)
    note.contents = "文字备注、读书研究\nEnglish research comment - original bytes preserved."
    if name == "System" { note.font = NSFont.systemFont(ofSize: 14) }
    else if name != "Default" {
        guard let font = NSFont(name: name, size: 14) else { print("Unavailable:", name); continue }
        note.font = font
    }
    note.fontColor = .black
    note.color = NSColor(calibratedRed: 0.93, green: 0.97, blue: 0.94, alpha: 1)
    note.setValue("fixture-font-" + name, forAnnotationKey: .name)
    page.addAnnotation(note)
    guard let data = document.dataRepresentation() else { fatalError("export failed") }
    try data.write(to: root.appendingPathComponent("font-" + name + ".pdf"), options: .atomic)
    print(name, note.font?.fontName ?? "nil", data.count)
}
