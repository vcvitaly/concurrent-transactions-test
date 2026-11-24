#!/usr/bin/env python3
"""Render a k6 summary export (the JSON written by handleSummary) into a single HTML report page.

Usage:
  python3 build_report.py RUN.json --out report.html
      [--label "SERIALIZABLE"]
      [--baseline BASE.json --baseline-label "READ_COMMITTED + FOR UPDATE"]
      [--title "SERIALIZABLE run 1795455726"]
      [--context "<p>-level HTML describing what changed in this run>"]
      [--notes notes.json]     # JSON list of {"title", "body", "source"}; body and title may hold inline HTML
      [--footer "extra footer text (HTML)"]

Only the Python standard library is used. The page loads no data at runtime: both runs are embedded.
After writing the page it prints a short plain-text summary of the key numbers.
"""
import argparse
import html
import json
import re
import sys
from pathlib import Path

TEMPLATE = Path(__file__).resolve().parent.parent / "assets" / "template.html"


def load_run(path: str) -> dict:
    p = Path(path)
    try:
        data = json.loads(p.read_text())
    except (OSError, json.JSONDecodeError) as e:
        sys.exit(f"Could not read {path}: {e}")
    if not isinstance(data, dict) or "metrics" not in data:
        sys.exit(f"{path} has no 'metrics' key, so it is not a k6 summary export (handleSummary data).")
    return data


def run_number(path: str, data: dict) -> str:
    m = re.search(r"run-(\d+)", Path(path).name)
    if m:
        return m.group(1)
    parts = str(data.get("setup_data", {}).get("runId", "")).split("-")
    if len(parts) > 1 and parts[1].isdigit():
        return str(int(parts[1]) // 1000)
    return Path(path).stem


def embed(obj) -> str:
    # Keep "</script>" (and any "</") from closing the script element early.
    return json.dumps(obj, separators=(",", ":")).replace("</", "<\\/")


def metric(data: dict, name: str, key: str):
    return data.get("metrics", {}).get(name, {}).get("values", {}).get(key)


def summary_line(label: str, data: dict) -> str:
    def f(v, d=1):
        return "-" if v is None else f"{v:,.{d}f}"
    dur = data.get("state", {}).get("testRunDurationMs")
    return (
        f"{label}: transfers ok={f(metric(data, 'transfers_succeeded', 'count'), 0)} "
        f"failed={f(metric(data, 'transfers_failed', 'count'), 0)} "
        f"retries={f(metric(data, 'transfer_retries', 'count'), 0)} "
        f"throughput={f(metric(data, 'iterations', 'rate'))}/s "
        f"duration={f(dur / 1000 if dur else None, 2)}s "
        f"req_p95={f(metric(data, 'http_req_duration', 'p(95)'), 2)}ms "
        f"transfer_p95={f(metric(data, 'iteration_duration', 'p(95)'), 2)}ms "
        f"checks={f(metric(data, 'checks', 'passes'), 0)}/"
        f"{f((metric(data, 'checks', 'passes') or 0) + (metric(data, 'checks', 'fails') or 0), 0)}"
    )


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run", help="k6 summary JSON of the run to report on")
    ap.add_argument("--out", required=True, help="HTML file to write")
    ap.add_argument("--label", default="This run", help="short name of this run's configuration")
    ap.add_argument("--baseline", help="k6 summary JSON of a run to compare against")
    ap.add_argument("--baseline-label", default="Baseline", help="short name of the baseline's configuration")
    ap.add_argument("--title", help="page title; defaults to '<label> run <number>'")
    ap.add_argument("--context", default="", help="intro paragraph (inline HTML allowed)")
    ap.add_argument("--notes", help="JSON file with a list of {title, body, source} notes")
    ap.add_argument("--footer", default="", help="extra footer text (inline HTML allowed)")
    args = ap.parse_args()

    run = load_run(args.run)
    base = load_run(args.baseline) if args.baseline else None

    notes = []
    if args.notes:
        try:
            notes = json.loads(Path(args.notes).read_text())
        except (OSError, json.JSONDecodeError) as e:
            sys.exit(f"Could not read notes {args.notes}: {e}")
        if not isinstance(notes, list) or not all(isinstance(n, dict) and "title" in n and "body" in n for n in notes):
            sys.exit("Notes must be a JSON list of objects with 'title' and 'body' (and optionally 'source').")

    label = args.label
    title = args.title or (f"{label} run {run_number(args.run, run)}" if label != "This run" else f"k6 run {run_number(args.run, run)}")
    meta = {
        "title": title,
        "label": label,
        "baselineLabel": args.baseline_label,
        "context": args.context,
        "notes": notes,
        "runFile": args.run,
        "baselineFile": args.baseline or "",
        "footer": args.footer,
    }

    page = TEMPLATE.read_text()
    for key, value in {
        "__TITLE__": html.escape(title),
        "__RUN__": embed(run),
        "__BASE__": embed(base) if base else "null",
        "__META__": embed(meta),
    }.items():
        if key not in page:
            sys.exit(f"Template is missing the {key} placeholder: {TEMPLATE}")
        page = page.replace(key, value, 1)

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(page)

    print(f"Wrote {out} ({len(page):,} bytes), title: {title}")
    print(summary_line(label, run))
    if base:
        print(summary_line(args.baseline_label, base))


if __name__ == "__main__":
    main()
