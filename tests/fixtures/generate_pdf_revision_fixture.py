#!/usr/bin/env python3
"""Create a distinct, valid three-page synthetic edition; never touch a library."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path

from pypdf import PdfReader
from reportlab.pdfgen import canvas
from generate_ui_fixtures import PAGE, header, register_font, text_lines


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("--font", type=Path, default=Path("/System/Library/Fonts/Supplemental/Arial Unicode.ttf"))
    args = parser.parse_args()
    if args.output.exists():
        raise SystemExit("Refusing to overwrite an existing fixture")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    register_font(args.font)
    pdf = canvas.Canvas(str(args.output), pagesize=PAGE, pageCompression=1, invariant=1)
    pdf.setTitle("Synthetic research - revised edition two")
    pdf.setAuthor("TokenLibrary synthetic version acceptance")
    topics = [
        ("Revision Two Alpha", "This edition starts a new reading session.", "第二版：文件内容已改变，旧阅读位置不能直接复用。"),
        ("Revision Two Beta", "Old highlight coordinates must remain under review.", "第二版：旧批注文字保留，但不应绘制到新页面。"),
        ("Revision Two Gamma", "Source quotations retain their original file hash.", "第二版：旧摘录来源应明确提示版本变化。"),
    ]
    for index, (anchor, english, chinese) in enumerate(topics, 1):
        header(pdf, "Revised edition / 第二版", f"Synthetic PDF replacement fixture - page {index} of 3", index)
        text_lines(pdf, [anchor, english, chinese, "", "This is a distinct synthetic original, not an annotation export.",
                         "No annotation dictionaries or old selection coordinates are embedded.",
                         "原始第一版文件必须保持字节不变，并可通过正常 API 恢复。"], y=638, size=11)
        pdf.showPage()
    pdf.save()
    reader = PdfReader(args.output, strict=True)
    assert len(reader.pages) == 3 and not reader.is_encrypted
    for page, (anchor, _, chinese) in zip(reader.pages, topics):
        text = page.extract_text()
        assert anchor in text and chinese in text
        assert not page.get("/Annots")
    raw = args.output.read_bytes()
    print(json.dumps({"path": str(args.output.resolve()), "bytes": len(raw), "pages": 3,
                      "sha256": hashlib.sha256(raw).hexdigest(), "hasEmbeddedAnnotations": False}, ensure_ascii=False))


if __name__ == "__main__":
    main()
