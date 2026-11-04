"""Extracts raw text from DATA/Sources/*.pdf into tool/jurisprudence/out/raw/*.txt."""
import pathlib
import sys

from pypdf import PdfReader

root = pathlib.Path(__file__).resolve().parents[2]
src = root / "DATA" / "Sources"
out = pathlib.Path(__file__).resolve().parent / "out" / "raw"
out.mkdir(parents=True, exist_ok=True)

for pdf in sorted(src.glob("*.pdf")):
    try:
        reader = PdfReader(str(pdf))
        text = "\n".join((page.extract_text() or "") for page in reader.pages)
    except Exception as error:  # a damaged PDF must not stop the batch
        print(f"FAIL {pdf.name}: {type(error).__name__}", file=sys.stderr)
        continue
    (out / f"{pdf.stem}.txt").write_text(text, encoding="utf-8")
    print(f"{pdf.stem}\tpages={len(reader.pages)}\tchars={len(text)}")
