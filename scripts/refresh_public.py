"""Optional source refresh; pip install pdfplumber first. Retains only DFW rows."""
import csv
import hashlib
import json
import tempfile
import urllib.request
from pathlib import Path
from datetime import datetime, timezone
import pdfplumber

ROOT = Path(__file__).resolve().parents[1]
manifest_path = ROOT / "data/public/source_manifest.json"
manifest = json.loads(manifest_path.read_text())
payload = urllib.request.urlopen(manifest["source_url"], timeout=60).read()
target = ROOT / "data/public/dfw_county_crashes_2024.csv"
with target.open() as f:
    columns = next(csv.reader(f))
rows = []
with tempfile.NamedTemporaryFile(suffix=".pdf") as tmp:
    tmp.write(payload)
    tmp.flush()
    with pdfplumber.open(tmp.name) as doc:
        for page_number, page in enumerate(doc.pages, 1):
            for line in page.extract_text().splitlines():
                parts = line.split()
                if parts and parts[0] in manifest["counties"]:
                    if len(parts) != 14:
                        raise ValueError("Source layout changed: inspect the original before refreshing")
                    values = [int(x.replace(",", "")) for x in parts[1:]]
                    assert sum(values[i] for i in (0,2,4,6,8,10)) == values[-1]
                    rows.append([parts[0], *values, page_number])
assert len(rows)==12 and {r[0] for r in rows}==set(manifest["counties"])
with target.open("w", newline="") as f:
    writer=csv.writer(f); writer.writerow(columns); writer.writerows(sorted(rows))
manifest["source_pdf_sha256"] = hashlib.sha256(payload).hexdigest()
manifest["retrieved_on"] = datetime.now(timezone.utc).date().isoformat()
manifest_path.write_text(json.dumps(manifest, indent=2)+"\n")
print("Refreshed DFW-only source extract. Review source dates and changes before committing.")
