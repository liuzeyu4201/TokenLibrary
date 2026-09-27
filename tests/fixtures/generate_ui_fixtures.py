#!/usr/bin/env python3
"""Deterministic synthetic files for native import/read/export acceptance.

Requires reportlab, Pillow and pypdf. No network, production data or credentials.
Default output: /tmp/tokenlibrary-ui-fixtures. The large PDF contains real RGB
image samples, not appended padding, duplicate unused objects or invalid bytes.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import random
import shutil
import time

from PIL import Image, ImageDraw, ImageFont
from pypdf import PdfReader
from reportlab import rl_config
from reportlab.lib.colors import HexColor
from reportlab.lib.utils import ImageReader
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfgen import canvas

PAGE = (612, 792)
INK = HexColor("#16372d")
GRAY = HexColor("#4a5d56")


def register_font(path: Path) -> None:
    pdfmetrics.registerFont(TTFont("UIFixture", str(path)))


def header(pdf: canvas.Canvas, title: str, label: str, number: int) -> None:
    pdf.setFillColor(HexColor("#edf4ef"))
    pdf.rect(0, 722, 612, 70, fill=1, stroke=0)
    pdf.setFillColor(INK)
    pdf.setFont("UIFixture", 20)
    pdf.drawString(48, 753, title)
    pdf.setFont("UIFixture", 10)
    pdf.drawString(48, 735, label)
    pdf.setStrokeColor(HexColor("#cbd8d1"))
    pdf.line(48, 48, 564, 48)
    pdf.setFont("UIFixture", 9)
    pdf.setFillColor(GRAY)
    pdf.drawString(48, 32, "SYNTHETIC TEST DATA - No personal or published material")
    pdf.drawRightString(564, 32, str(number))


def text_lines(pdf: canvas.Canvas, lines: list[str], y: int = 686, size: int = 12, leading: int = 22) -> None:
    pdf.setFont("UIFixture", size)
    pdf.setFillColor(INK)
    for line in lines:
        pdf.drawString(48, y, line)
        y -= leading


def research_pdf(path: Path) -> None:
    pdf = canvas.Canvas(str(path), pagesize=PAGE, pageCompression=1, invariant=1)
    pdf.setTitle("Synthetic Research: Personal Library and Reproducible Notes")
    pdf.setAuthor("TokenLibrary synthetic acceptance fixture")
    pages = [
        ("Research notes / 研究笔记", "Page 1 - questions and provenance", [
            "Research Anchor Alpha: Local-first reading preserves personal context.",
            "研究锚点甲：书籍、论文和笔记共同构成个人资料库。",
            "A source quotation and the reader's interpretation are different records.",
            "引用原文与个人评论应当分别保存，并保留来源页码。",
            "The immutable original file remains available after annotation.",
            "修改标题、作者和批注不应改变原始 PDF 的字节。",
            "",
            "Acceptance activity: select this paragraph and create a yellow highlight.",
            "Add a comment: this is an original synthetic research sample.",
        ]),
        ("Methods / 方法", "Page 2 - reproducibility and navigation", [
            "Research Anchor Beta: A stable identifier survives rename and move.",
            "研究锚点乙：重命名和移动后仍可从笔记返回原文。",
            "Device A reads page three; Device B may intentionally return to page one.",
            "跨设备阅读进度不能简单取最大页码。",
            "A changed file hash requires the old excerpt location to be reviewed.",
            "来源文件版本变化时，旧摘录位置需要核对。",
            "",
            "Method 1: create an excerpt from Research Anchor Beta.",
            "Method 2: write a separate interpretation and return to this page.",
        ]),
        ("Results / 结果", "Page 3 - offline work and preservation", [
            "Research Anchor Gamma: Reliable export includes images and provenance.",
            "研究锚点丙：归档保留资料，删除才进入回收站。",
            "An archived paper can still be searched, read and exported.",
            "专题成员通过关系组织，不应因为删除专题而丢失原件。",
            "Offline edits wait for a durable server receipt before becoming synced.",
            "本地保存成功与服务器同步成功是两个不同状态。",
            "",
            "Expected search targets: Research Anchor Alpha / Beta / Gamma.",
            "Expected page counts: exactly three pages with selectable text.",
        ]),
    ]
    for number, (title, subtitle, lines) in enumerate(pages, 1):
        header(pdf, title, subtitle, number)
        text_lines(pdf, lines)
        pdf.setFillColor(HexColor("#eef5f1")); pdf.roundRect(48, 326, 516, 72, 10, fill=1, stroke=0)
        text_lines(pdf, ["Notes for UI testing / 界面测试备注", "Select text, add an excerpt, rename, export, and reopen."], y=373, size=11)
        pdf.showPage()
    pdf.save()


def diagram_png(path: Path, font_path: Path) -> None:
    image = Image.new("RGB", (1600, 900), "#f6faf7")
    draw = ImageDraw.Draw(image)
    title = ImageFont.truetype(str(font_path), 48)
    body = ImageFont.truetype(str(font_path), 31)
    small = ImageFont.truetype(str(font_path), 25)
    draw.text((90, 75), "Personal library / 个人资料库", font=title, fill="#16372d")
    labels = [("Read / 阅读", "PDF original"), ("Think / 思考", "Source + comment"), ("Preserve / 保存", "Export + verify")]
    for i, (a, b) in enumerate(labels):
        x = 90 + 500 * i
        draw.rounded_rectangle((x, 240, x + 420, 510), radius=30, fill="#dceee3", outline="#527f68", width=3)
        draw.text((x + 30, 300), a, font=body, fill="#16372d")
        draw.text((x + 30, 360), b, font=small, fill="#385849")
        if i < 2:
            draw.line((x + 430, 375, x + 486, 375), fill="#527f68", width=7)
            draw.polygon([(x + 486, 375), (x + 470, 362), (x + 470, 388)], fill="#527f68")
    draw.text((90, 660), "Deterministic synthetic diagram. No external image rights or network dependency.", font=small, fill="#385849")
    draw.text((90, 715), "Fixture image: 1600 x 900 pixels", font=small, fill="#385849")
    image.save(path)


def scanned_pdf(path: Path, font_path: Path) -> None:
    image = Image.new("RGB", (1600, 2200), "#faf9f3")
    draw = ImageDraw.Draw(image)
    title = ImageFont.truetype(str(font_path), 58)
    body = ImageFont.truetype(str(font_path), 35)
    draw.text((120, 145), "Scanned page / 扫描资料", font=title, fill="#1f3930")
    for i, line in enumerate([
        "This page is a raster image only.",
        "RasterOnlyAnchor should not be found by text search.",
        "这是一张只有图像、没有隐藏文字层的合成扫描页。",
        "可以阅读和添加文字备注，不能假装能够选择原文。",
        "",
        "Acceptance activity:",
        "1. Import and read the page offline.",
        "2. Attempt a text search; explain coverage honestly.",
        "3. Add a page comment and export the annotated PDF.",
    ]):
        draw.text((120, 330 + i * 78), line, font=body, fill="#2c443b")
    for i in range(6):
        draw.rectangle((120, 1260 + i * 95, 280 + i * 165, 1310 + i * 95), fill=(80, 130 + i * 12, 105))
    pdf = canvas.Canvas(str(path), pagesize=PAGE, pageCompression=1, invariant=1)
    pdf.setTitle("Synthetic raster-only scanned page")
    pdf.drawImage(ImageReader(image), 0, 0, width=612, height=792)
    pdf.showPage(); pdf.save()


def large_pdf(path: Path, height: int = 1150) -> None:
    """Eight independent 1800 x height high-entropy RGB sensor images.

    Every pixel belongs to a displayed image XObject. Lossless deflate keeps
    this a genuine decode/read/export workload near the product's 50 MB limit.
    """
    pdf = canvas.Canvas(str(path), pagesize=PAGE, pageCompression=1, invariant=1)
    pdf.setTitle("Synthetic high-resolution sensor atlas near 50 MB")
    pdf.setAuthor("TokenLibrary synthetic acceptance fixture")
    for page in range(1, 9):
        header(pdf, "Sensor atlas / 传感器图集", f"Lossless RGB field - page {page} of 8", page)
        text_lines(pdf, [
            f"Large PDF Anchor {page}: reproducible sensor noise observation.",
            "大文件检索锚点：真实图像对象与可选择文字同时存在。",
            "Each image contains independent deterministic RGB samples.",
        ], y=685, size=11, leading=21)
        pixels = random.Random(91000 + page).randbytes(1800 * height * 3)
        image = Image.frombytes("RGB", (1800, height), pixels)
        image_height = 516 * height / 1800
        pdf.drawImage(ImageReader(image), 48, 257, width=516, height=image_height)
        text_lines(pdf, [
            f"Field dimensions: 1800 x {height} pixels; RGB, 8 bits per channel.",
            "Purpose: exercise real image decoding, page render and PDF export.",
            "No unused payload, invalid PDF padding or external attachment is used.",
            "Try highlighting Large PDF Anchor and export without changing the original.",
        ], y=216, size=10, leading=21)
        pdf.showPage()
    pdf.save()


MARKDOWN = r'''# Personal research notebook / 个人研究笔记

This synthetic note exercises **bold**, *italic*, ~~removed text~~, `inline code`, and [a public documentation link](https://www.rfc-editor.org/rfc/rfc9110).

## Tasks / 任务

- [x] Import the research PDF.
- [ ] Add a source excerpt and a separate personal comment.
- [ ] Export this note with its image and reopen it outside the app.

| Topic | Item | Status |
| :--- | :--- | ---: |
| 个人图书馆 | 书籍、论文、笔记 | 3 |
| Preservation | Sources and original bytes | 2 |

> 引用原文应与个人评论分开。
>
> This block is entirely original synthetic test text.

My comment: a stable source ID is still useful after moving or renaming a document.

## Equations / 数学公式

Inline math: $E = mc^2$ and $\alpha + \beta = \gamma$.

$$
\int_0^1 x^2\,dx = \frac{1}{3}
$$

## Workflow / 流程图

```mermaid
flowchart LR
    A[Collect] --> B[Read]
    B --> C[Excerpt]
    C --> D[Note]
    D --> E[Archive]
```

## Image / 图片

![Personal library diagram](media/fixture-diagram.png)

## Code and literal characters

```javascript
const literal = "${notInterpolation}";
const path = "C:\\Research\\notes";
console.log(literal, path);
```

1. Read the source.
2. Keep quotation and interpretation distinct.
3. Verify the exported artifact.

---

中文搜索锚点：来源与长期保存。English search anchor: reproducible evidence.
'''


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=Path("/tmp/tokenlibrary-ui-fixtures"))
    parser.add_argument("--font", type=Path, default=Path("/System/Library/Fonts/Supplemental/Arial Unicode.ttf"))
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    if not args.font.is_file():
        raise SystemExit("Pass --font with an available TrueType font covering Chinese; no fonts are downloaded.")
    register_font(args.font)
    rl_config.useA85 = False
    started = time.perf_counter()
    research_pdf(args.output / "research-three-pages.pdf")
    diagram_png(args.output / "fixture-diagram.png", args.font)
    (args.output / "media").mkdir(exist_ok=True)
    shutil.copyfile(args.output / "fixture-diagram.png", args.output / "media/fixture-diagram.png")
    scanned_pdf(args.output / "scanned-no-text.pdf", args.font)
    large = args.output / "large-near-50mb.pdf"
    large_pdf(large)
    # The font subset and metadata can vary by runtime. Tune actual image rows,
    # never insert padding, until this valid corpus fits a tight target band.
    height = 1150
    for _ in range(4):
        size = large.stat().st_size
        if 49_500_000 <= size <= 49_950_000: break
        height += round((49_750_000 - size) / (8 * 1800 * 3))
        large_pdf(large, height)
    if not 49_500_000 <= large.stat().st_size <= 50_000_000:
        raise RuntimeError("Actual image corpus missed the near-50 MB target; inspect sizes before use.")
    (args.output / "research-notebook.md").write_text(MARKDOWN, encoding="utf-8")
    records = []
    for name in sorted(["research-three-pages.pdf", "large-near-50mb.pdf", "scanned-no-text.pdf",
                        "fixture-diagram.png", "research-notebook.md"]):
        file = args.output / name
        data = file.read_bytes()
        row = {"name": file.name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
        if file.suffix == ".pdf":
            reader = PdfReader(file)
            row["pages"] = len(reader.pages)
            row["text_characters"] = sum(len(page.extract_text() or "") for page in reader.pages)
            if file.name == "scanned-no-text.pdf": assert row["text_characters"] == 0
        records.append(row)
    manifest = {"synthetic": True, "large_pdf_limit_bytes": 50_000_000, "large_image_dimensions": [1800, height], "generation_seconds": round(time.perf_counter() - started, 3), "files": records}
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps(manifest, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
