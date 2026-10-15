"""One command: R simulation -> SQL analysis -> invariants -> R model/report."""
import os
import shutil
import subprocess
import sys
from pathlib import Path
from build_sql import build

ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)
rscript = os.environ.get("RSCRIPT") or shutil.which("Rscript")
if not rscript:
    sys.exit("Rscript is required. Install R >= 4.4 from https://cran.r-project.org/ and rerun.")
for folder in ("reports/figures", "reports/tables", "work"):
    Path(folder).mkdir(parents=True, exist_ok=True)
subprocess.run([rscript, "R/01_simulate.R"], check=True)
build()
subprocess.run([sys.executable, "-m", "unittest", "discover", "-s", "tests", "-v"], check=True)
subprocess.run([rscript, "R/02_analyze.R"], check=True)
subprocess.run([sys.executable, "scripts/render_report.py"], check=True)
print("Complete. Open reports/report.html or reports/analysis.md.")

