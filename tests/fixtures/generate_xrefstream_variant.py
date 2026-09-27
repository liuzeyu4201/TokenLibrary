#!/usr/bin/env python3
"""Make a synthetic fixture use an xref stream and a compressed Info object.

The input must be a complete, unencrypted classic-xref fixture. This is for
SDK compatibility tests; it never edits the input PDF.
"""
import argparse
import io
from pathlib import Path
import zlib
from pypdf import PdfReader

parser = argparse.ArgumentParser()
parser.add_argument("input", type=Path)
parser.add_argument("output", type=Path)
args = parser.parse_args()
source = args.input.read_bytes()
reader = PdfReader(io.BytesIO(source), strict=True)
assert not reader.is_encrypted and not reader.xref_objStm
start = int(source.rsplit(b"startxref", 1)[1].split()[0])
assert source[start:].startswith(b"xref")
body = source[:start]
info = reader.trailer.raw_get("/Info")
root = reader.trailer.raw_get("/Root")
count = max(reader.xref[0]) + 1
stream_object = count
xref_object = count + 1
value = io.BytesIO()
info.get_object().write_to_stream(value)
header = f"{info.idnum} 0 ".encode()
compressed = zlib.compress(header + value.getvalue())
stream_offset = len(body)
body += (f"{stream_object} 0 obj\n<< /Type /ObjStm /N 1 /First {len(header)} "
         f"/Length {len(compressed)} /Filter /FlateDecode >>\nstream\n").encode()
body += compressed + b"\nendstream\nendobj\n"
xref_offset = len(body)
size = xref_object + 1
entries = []
for number in range(size):
    if number == 0:
        kind, offset, generation = 0, 0, 65535
    elif number == info.idnum:
        kind, offset, generation = 2, stream_object, 0
    elif number == stream_object:
        kind, offset, generation = 1, stream_offset, 0
    elif number == xref_object:
        kind, offset, generation = 1, xref_offset, 0
    else:
        kind, offset, generation = 1, reader.xref[0][number], 0
    entries.append(bytes([kind]) + offset.to_bytes(4, "big") + generation.to_bytes(2, "big"))
xref = b"".join(entries)
body += (f"{xref_object} 0 obj\n<< /Type /XRef /Size {size} /W [1 4 2] "
         f"/Root {root.idnum} 0 R /Info {info.idnum} 0 R /Length {len(xref)} >>\nstream\n").encode()
body += xref + b"\nendstream\nendobj\n" + f"startxref\n{xref_offset}\n%%EOF\n".encode()
# Header length stays fixed so every offset remains valid.
body = body[:8].replace(b"%PDF-1.3", b"%PDF-1.5").replace(b"%PDF-1.4", b"%PDF-1.5") + body[8:]
args.output.write_bytes(body)
check = PdfReader(args.output, strict=True)
assert len(check.pages) == len(reader.pages)
assert check.xref_objStm[info.idnum] == (stream_object, 0)
print(f"{len(check.pages)} pages; Info uses ObjStm {stream_object}; xref stream {xref_object}")
