#!/usr/bin/env python3
"""Derive import rejection cases from the existing synthetic PDF fixtures."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from pypdf import PdfReader, PdfWriter


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", type=Path, default=Path("/tmp/tokenlibrary-ui-fixtures"))
    directory = parser.parse_args().directory
    research = directory / "research-three-pages.pdf"
    large = directory / "large-near-50mb.pdf"
    encrypted = directory / "encrypted-password.pdf"
    writer = PdfWriter(clone_from=research)
    writer.encrypt(user_password="synthetic-reader", owner_password="synthetic-owner", algorithm="AES-256")
    writer.write(encrypted)
    reader = PdfReader(encrypted, strict=True)
    assert reader.is_encrypted
    assert reader.decrypt("synthetic-reader")
    assert len(reader.pages) == 3

    corrupt = directory / "corrupt.pdf"
    corrupt.write_bytes(b"%PDF-1.7\nSynthetic intentionally broken PDF; missing objects and trailer.\n")

    oversized = directory / "oversize-valid.pdf"
    writer = PdfWriter(clone_from=large)
    # A fresh reader prevents object deduplication of the additional rendered
    # image page. All size comes from referenced page resources, not EOF padding.
    writer.add_page(PdfReader(large, strict=True).pages[0])
    writer.write(oversized)
    assert oversized.stat().st_size > 50_000_000
    reader = PdfReader(oversized, strict=True)
    assert len(reader.pages) == 9
    for page in reader.pages:
        assert page.extract_text()
        page.get_contents().get_data()
        for reference in page["/Resources"].get("/XObject", {}).values():
            reference.get_object().get_data()

    output = {
        "encrypted-password.pdf": "需要打开密码；原件保留，提示先另存无需打开密码的副本",
        "corrupt.pdf": "损坏或不是有效 PDF，未入库",
        "oversize-valid.pdf": "超过 50 MB（50,000,000 字节），读取/入库前拒绝",
    }
    result = []
    for filename, expected in output.items():
        data = (directory / filename).read_bytes()
        result.append({"file": filename, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(), "expected": expected})
    (directory / "pdf-rejection-manifest.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
