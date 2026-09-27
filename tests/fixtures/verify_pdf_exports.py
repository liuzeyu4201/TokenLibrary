#!/usr/bin/env python3
"""Strict external-reader check; unlike opening PdfReader, decode every stream."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

from pypdf import PdfReader
from pypdf.generic import IndirectObject, StreamObject, TextStringObject


def verify(path: Path, render_directory: Path | None) -> dict:
    reader = PdfReader(path, strict=True)
    count = 0
    references = {(number, generation) for generation, entries in reader.xref.items()
                  for number in entries if number}
    references.update((number, 0) for number in reader.xref_objStm)
    for number, generation in sorted(references):
        obj = reader.get_object(IndirectObject(number, generation, reader))
        if isinstance(obj, StreamObject):
            obj.get_data()
            count += 1
    managed = []
    for page in reader.pages:
        for reference in page.get("/Annots", []):
            annotation = reference.get_object()
            name = str(annotation.get("/NM", ""))
            if not name.startswith("tokenlibrary:"):
                continue
            if annotation.get("/Subtype") == "/FreeText":
                assert isinstance(annotation.get("/DA"), TextStringObject), "FreeText /DA must be a string"
                assert annotation.get("/AP", {}).get("/N") is not None, "FreeText appearance missing"
            if annotation.get("/Subtype") == "/Highlight":
                rectangle = annotation["/Rect"]
                points = annotation["/QuadPoints"]
                assert len(points) >= 8 and len(points) % 8 == 0
                for x, y in zip(points[::2], points[1::2]):
                    assert rectangle[0] - 0.01 <= x <= rectangle[2] + 0.01, "Highlight x outside annotation"
                    assert rectangle[1] - 0.01 <= y <= rectangle[3] + 0.01, "Highlight y outside annotation"
            managed.append({"id": name, "type": str(annotation.get("/Subtype")),
                            "contents": str(annotation.get("/Contents", ""))})
    record = {"name": path.name, "bytes": path.stat().st_size, "pages": len(reader.pages),
              "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
              "strict_decoded_streams": count, "managed_annotations": managed}
    if render_directory:
        tool = shutil.which("pdftoppm")
        if not tool:
            raise RuntimeError("pdftoppm is required for --render; no software is installed automatically")
        render_directory.mkdir(parents=True, exist_ok=True)
        result = subprocess.run([tool, "-scale-to", "1100", "-png", str(path),
                                 str(render_directory / path.stem)], capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        assert not result.stderr.strip(), result.stderr
        record["poppler_all_pages_no_warnings"] = True
    return record


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("pdf", nargs="+", type=Path)
    parser.add_argument("--render", type=Path)
    args = parser.parse_args()
    print(json.dumps([verify(path, args.render) for path in args.pdf], indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
