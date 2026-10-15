"""Render this project's constrained Markdown to standalone HTML, no packages."""
import base64
import html
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPORTS = ROOT / "reports"


def inline(text):
    text = html.escape(text)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"\[([^\]]+)\]\((https://[^)]+)\)", r'<a href="\2">\1</a>', text)
    return text


def render():
    lines = (REPORTS / "analysis.md").read_text().splitlines()
    parts = []
    table_open = False
    code = False
    for line in lines:
        if not line.startswith("|") and table_open:
            parts.append("</tbody></table></div>")
            table_open = False
        if line.startswith("```"):
            code = not code
            parts.append("<pre><code>" if code else "</code></pre>")
        elif code:
            parts.append(html.escape(line) + "\n")
        elif not line:
            continue
        elif line.startswith("#"):
            level = len(line) - len(line.lstrip("#"))
            parts.append(f"<h{level}>{inline(line[level:].strip())}</h{level}>")
        elif line.startswith("!["):
            match = re.fullmatch(r"!\[(.*?)\]\((.*?)\)", line)
            alt, path = match.groups()
            payload = base64.b64encode((REPORTS / path).read_bytes()).decode()
            parts.append(f'<figure><img alt="{html.escape(alt)}" src="data:image/png;base64,{payload}"></figure>')
        elif line.startswith("|"):
            values = [v.strip() for v in line.strip("|").split("|")]
            if all(re.fullmatch(r"[-: ]+",v) for v in values):
                continue
            if not table_open:
                parts.append('<div class="table-wrap"><table><thead><tr>'+''.join(f'<th>{inline(v)}</th>' for v in values)+'</tr></thead><tbody>')
                table_open = True
            else:
                parts.append('<tr>'+''.join(f'<td>{inline(v)}</td>' for v in values)+'</tr>')
        else:
            cls = ' class="item"' if line.startswith("- ") or re.match(r"^\d+\. ",line) else ''
            parts.append(f'<p{cls}>{inline(line)}</p>')
    if table_open:
        parts.append("</tbody></table></div>")
    css = """
      :root{color-scheme:light}*{box-sizing:border-box}body{margin:0;background:#edf3f5;color:#163044;font:16px/1.65 system-ui,-apple-system,sans-serif}
      header{background:#163044;color:white;padding:24px max(24px,calc((100vw - 1050px)/2));font-size:14px;letter-spacing:.04em}
      main{max-width:1120px;margin:32px auto 60px;background:white;padding:44px 52px;border-top:5px solid #087f8c;box-shadow:0 6px 32px #1630440c}
      h1{font-size:34px;line-height:1.18;max-width:850px;margin:0 0 24px}h2{font-size:25px;margin-top:42px;padding-top:24px;border-top:1px solid #dce6ea}h3{font-size:19px;margin-top:28px}
      p{margin:14px 0}a{color:#087f8c}strong{font-weight:650}.item{padding-left:18px}figure{margin:28px -12px}img{display:block;width:100%;height:auto}
      .table-wrap{overflow:auto;margin:22px 0}table{border-collapse:collapse;min-width:650px;width:100%;font-size:14px;font-variant-numeric:tabular-nums}
      th{background:#163044;color:#fff;text-align:right;font-weight:550}th:first-child,td:first-child{text-align:left}td,th{padding:11px 12px}td{text-align:right;border-bottom:1px solid #dce6ea}tbody tr:nth-child(even){background:#f2f7f8}
      pre{overflow:auto;background:#edf4f5;border-left:4px solid #087f8c;padding:18px;font-size:13px;line-height:1.6}
      @media(max-width:700px){main{margin:0;padding:30px 20px}h1{font-size:28px}figure{margin:24px -10px}}
      @media print{body{background:white}main{box-shadow:none;margin:0;padding:0;border:0}header{display:none}h2{break-after:avoid}figure,table{break-inside:avoid}}
    """
    document = '<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>DFW Auto Claims Analysis</title><style>'+css+'</style><header>DFW AUTO CLAIMS ANALYSIS / SQL + R / SYNTHETIC INSURANCE DEMONSTRATION</header><main>'+"\n".join(parts)+'</main></html>'
    (REPORTS / "report.html").write_text(document)


if __name__ == "__main__":
    render()

