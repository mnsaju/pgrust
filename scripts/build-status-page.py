#!/usr/bin/env python3
"""Builds the static status page published to GitHub Pages.

This is PLAN-production-readiness.md's C2 in executable form. The compatibility
contract -- what this build of pgrust is and is not safe for -- is GENERATED
from CI's own artifacts and the ratchet ledgers, not written by hand, so it
cannot drift away from what the gates actually prove. The only hand-maintained
part is regress/contract.json, which holds the claims no artifact can produce
(absent features, known divergences, untested trees).

Inputs, all optional -- a missing one becomes a visible "not available in this
run" rather than a silently absent section, because a status page that hides
what it could not measure is the same defect the harness work spent a session
removing:

    regress-work/compat-lanes.json     Gate B lane results
    regress-work/rowsort-report.json   core regression comparator
    regress-work/build-manifest.txt    what the binary was built from
    regress/*.allow                    the ratchet ledgers
    regress/contract.json              hand-maintained claims

Usage: scripts/build-status-page.py [--out site]
"""
from __future__ import annotations

import argparse
import html
import json
import os
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LEDGERS = [
    ("known-failures.allow", "Core regression suite"),
    ("contrib-known-failures.allow", "contrib modules"),
    ("plpgsql-known-failures.allow", "PL/pgSQL supplementary"),
    ("refusal-known-failures.allow", "Refusal lanes (B6/B8)"),
]


def read_json(p: Path):
    try:
        return json.loads(p.read_text())
    except Exception:
        return None


def parse_ledger(p: Path) -> tuple[list[str], str]:
    """Returns (entries, header prose). The header carries the mechanism notes,
    which are the point of the ledger -- an entry without one is the defect
    PLAN-critical-improvements.md §9 is about."""
    try:
        lines = p.read_text().splitlines()
    except Exception:
        return [], ""
    entries = [ln.strip() for ln in lines
               if ln.strip() and not ln.lstrip().startswith("#")]
    header = "\n".join(ln.lstrip("# ").rstrip() for ln in lines
                       if ln.lstrip().startswith("#"))
    return entries, header


def esc(s) -> str:
    return html.escape(str(s), quote=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, default=ROOT / "site")
    args = ap.parse_args()
    work = ROOT / "regress-work"

    lanes = read_json(work / "compat-lanes.json")
    core = read_json(work / "rowsort-report.json")
    contract = read_json(ROOT / "regress" / "contract.json") or {}
    try:
        manifest = (work / "build-manifest.txt").read_text().strip()
    except Exception:
        manifest = ""

    commit = os.environ.get("GITHUB_SHA") or subprocess.run(
        ["git", "rev-parse", "HEAD"], capture_output=True, text=True,
        cwd=ROOT).stdout.strip() or "unknown"
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    run_url = (f"https://github.com/{repo}/actions/runs/{os.environ['GITHUB_RUN_ID']}"
               if repo and os.environ.get("GITHUB_RUN_ID") else "")
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    P: list[str] = []
    w = P.append

    def section(title, sub=""):
        w(f'<section><h2>{esc(title)}</h2>')
        if sub:
            w(f'<p class="sub">{esc(sub)}</p>')

    def missing(what):
        w(f'<p class="missing">Not available in this run — {esc(what)}. '
          f'The section is shown rather than hidden so an unmeasured tier '
          f'cannot be mistaken for a passing one.</p>')

    # ---- header ----------------------------------------------------------
    total_lanes = lanes["ran"] if lanes else 0
    failed_lanes = lanes["failed"] if lanes else 0
    overall = "unknown"
    if lanes:
        overall = "green" if failed_lanes == 0 else "red"

    w(f'<header><h1>pgrust status</h1>'
      f'<p class="sub">Generated {esc(now)} from CI artifacts · commit '
      f'<code>{esc(commit[:12])}</code>'
      + (f' · <a href="{esc(run_url)}">run log</a>' if run_url else "") + '</p>'
      f'<p class="banner {overall}">'
      + (f"Gate B: {total_lanes - failed_lanes} of {total_lanes} lanes passing"
         if lanes else "Gate B: no lane results in this run")
      + '</p></header>')

    w('<p class="lede">This page is generated, not written. Every claim below '
      'comes from a gate that runs in CI, or from a ratchet ledger that breaks '
      'the build when it stops being true. The hand-maintained parts are '
      'marked as such.</p>')

    w('<p class="warn"><strong>pgrust is not production ready.</strong> '
      'Do not put data you care about in it. This page exists to say exactly '
      'what is and is not proven, not to suggest otherwise.</p>')

    # ---- Gate B lanes ----------------------------------------------------
    section("Ecosystem compatibility lanes",
            "Each lane drives the real C tool against pgrust — never a "
            "reimplementation, because only the genuine binary answers the "
            "compatibility question.")
    if lanes:
        w('<table><thead><tr><th>Lane</th><th>What it proves</th>'
          '<th>Result</th><th>Time</th></tr></thead><tbody>')
        for L in lanes["lanes"]:
            cls = "pass" if L["status"] == "PASS" else "fail"
            w(f'<tr><td><code>{esc(L["id"])}</code></td>'
              f'<td>{esc(L["description"])}</td>'
              f'<td class="{cls}">{esc(L["status"])}</td>'
              f'<td class="num">{esc(L["duration"])}</td></tr>')
        w('</tbody></table>')
    else:
        missing("regress-work/compat-lanes.json was not produced")
    w('</section>')

    # ---- core suite ------------------------------------------------------
    section("Core regression suite",
            "PostgreSQL's own suite, vendored at REL_18_3, scored against every "
            "baseline pg_regress itself would try.")
    if core:
        c = core.get("counts", {})
        w('<div class="stats">')
        for k in ("exact", "rowsort-relaxed", "fail", "error"):
            w(f'<div class="stat"><span class="n">{c.get(k, 0)}</span>'
              f'<span class="l">{esc(k)}</span></div>')
        w(f'<div class="stat"><span class="n">{core.get("total", 0)}</span>'
          f'<span class="l">checked</span></div></div>')
        bad = [f["name"] for f in core.get("files", [])
               if f["status"] in ("fail", "error")]
        if bad:
            w('<p class="sub">Failing, all ledgered:</p><p class="chips">'
              + " ".join(f'<code>{esc(n)}</code>' for n in sorted(bad)) + '</p>')
        nc = core.get("not_checked") or []
        if nc:
            w('<p class="sub">Overlaid but not in the schedule, so not scored: '
              + ", ".join(f'<code>{esc(n)}</code>' for n in nc) + '</p>')
    else:
        missing("regress-work/rowsort-report.json was not produced")
    w('</section>')

    # ---- ledgers ---------------------------------------------------------
    section("Known failures", "Every entry is a defect this build has, "
            "recorded with its mechanism. A ledger can only shrink: an "
            "unlisted failure breaks the build, and so does an entry that "
            "starts passing.")
    for fname, label in LEDGERS:
        entries, header = parse_ledger(ROOT / "regress" / fname)
        w(f'<details><summary><strong>{esc(label)}</strong> — '
          f'{len(entries)} entr{"y" if len(entries)==1 else "ies"} '
          f'<code>{esc(fname)}</code></summary>')
        if entries:
            w('<p class="chips">' + " ".join(f'<code>{esc(e)}</code>'
                                             for e in entries) + '</p>')
        w(f'<pre class="ledger">{esc(header)}</pre></details>')
    w('</section>')

    # ---- contract (hand-maintained) --------------------------------------
    section("Known divergences", "Compatible-but-different behaviour. "
            "Hand-maintained in regress/contract.json.")
    for d in contract.get("divergences", []):
        w(f'<div class="card"><h3>{esc(d["title"])}</h3>'
          f'<p>{esc(d["detail"])}</p>'
          f'<p class="sub">Evidence: <code>{esc(d["evidence"])}</code></p></div>')
    w('</section>')

    section("Not implemented", "Hand-maintained in regress/contract.json.")
    w('<ul>' + "".join(f'<li>{esc(x)}</li>' for x in contract.get("absent", []))
      + '</ul></section>')

    section("Not tested", "No gate covers these. Naming them matters as much "
            "as naming the failures — an untested area is not a passing one.")
    w('<ul>' + "".join(f'<li>{esc(x)}</li>' for x in contract.get("untested", []))
      + '</ul></section>')

    # ---- build provenance ------------------------------------------------
    section("Build provenance", "What this binary was built from. Two builds "
            "of the same commit must produce the same manifest.")
    if manifest:
        w(f'<pre>{esc(manifest)}</pre>')
    else:
        missing("no build manifest was captured")
    w('</section>')

    css = """
:root{--bg:#fbfbfa;--fg:#1c1b19;--mut:#6b6862;--line:#e3e1dc;--card:#fff;
--pass:#1f7a4d;--fail:#b3261e;--warn:#8a5a00;--warnbg:#fff8e6}
@media(prefers-color-scheme:dark){:root{--bg:#16151a;--fg:#e9e7e3;--mut:#9c9890;
--line:#2e2c33;--card:#1e1d23;--pass:#5cc98d;--fail:#f2867d;--warn:#e0b25e;--warnbg:#2a2317}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);
font:15px/1.6 ui-sans-serif,system-ui,-apple-system,"Segoe UI",sans-serif}
.wrap{max-width:60rem;margin:0 auto;padding:2.5rem 1.25rem 5rem}
h1{font-size:1.9rem;margin:0 0 .25rem;letter-spacing:-.02em}
h2{font-size:1.15rem;margin:0 0 .35rem;letter-spacing:-.01em}
h3{font-size:1rem;margin:0 0 .35rem}
section{margin:2.5rem 0;padding-top:1.5rem;border-top:1px solid var(--line)}
.sub{color:var(--mut);margin:.25rem 0 1rem;font-size:.9rem}
.lede{font-size:1.02rem;color:var(--mut);margin:1.25rem 0}
.banner{display:inline-block;margin:.75rem 0 0;padding:.35rem .75rem;
border-radius:.4rem;font-weight:600;font-size:.9rem}
.banner.green{background:color-mix(in srgb,var(--pass) 15%,transparent);color:var(--pass)}
.banner.red{background:color-mix(in srgb,var(--fail) 15%,transparent);color:var(--fail)}
.banner.unknown{background:var(--line);color:var(--mut)}
.warn{background:var(--warnbg);border:1px solid color-mix(in srgb,var(--warn) 40%,transparent);
color:var(--warn);padding:.75rem 1rem;border-radius:.5rem}
.missing{color:var(--mut);font-style:italic}
table{width:100%;border-collapse:collapse;font-size:.92rem}
th,td{text-align:left;padding:.5rem .6rem;border-bottom:1px solid var(--line)}
th{font-weight:600;color:var(--mut);font-size:.82rem;text-transform:uppercase;letter-spacing:.04em}
td.pass{color:var(--pass);font-weight:600}
td.fail{color:var(--fail);font-weight:600}
td.num{color:var(--mut);text-align:right;font-variant-numeric:tabular-nums}
.stats{display:flex;flex-wrap:wrap;gap:.6rem;margin:.5rem 0 1rem}
.stat{background:var(--card);border:1px solid var(--line);border-radius:.5rem;
padding:.6rem .9rem;min-width:6rem}
.stat .n{display:block;font-size:1.5rem;font-weight:650;font-variant-numeric:tabular-nums}
.stat .l{display:block;color:var(--mut);font-size:.78rem}
.chips code{display:inline-block;margin:.12rem .18rem .12rem 0}
code{background:var(--card);border:1px solid var(--line);border-radius:.3rem;
padding:.08rem .32rem;font:.86em ui-monospace,SFMono-Regular,Menlo,monospace}
pre{background:var(--card);border:1px solid var(--line);border-radius:.5rem;
padding:.9rem;overflow-x:auto;font:.82rem/1.5 ui-monospace,SFMono-Regular,Menlo,monospace}
pre.ledger{max-height:22rem;overflow-y:auto;color:var(--mut);white-space:pre-wrap}
details{margin:.5rem 0;padding:.6rem .8rem;background:var(--card);
border:1px solid var(--line);border-radius:.5rem}
summary{cursor:pointer}
.card{background:var(--card);border:1px solid var(--line);border-radius:.5rem;
padding:.9rem 1rem;margin:.6rem 0}
ul{padding-left:1.15rem}li{margin:.3rem 0}
a{color:inherit}
footer{margin-top:3rem;color:var(--mut);font-size:.85rem}
"""
    out = args.out
    out.mkdir(parents=True, exist_ok=True)
    (out / "index.html").write_text(
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
        "<title>pgrust status</title><style>" + css + "</style></head><body>"
        "<div class=\"wrap\">" + "".join(P) +
        "<footer>Generated by <code>scripts/build-status-page.py</code> from "
        "CI artifacts and the ratchet ledgers.</footer></div></body></html>")
    # The JSON the page was rendered from, published alongside it so the page
    # is inspectable rather than merely readable.
    # Trim the per-file residual diffs out of the core report before
    # republishing it: they are ~360 KB of unified diff that nobody reads from
    # a status page, and they are already in the CI artifact for anyone who
    # needs them.
    core_slim = None
    if core:
        core_slim = {k: v for k, v in core.items() if k != "files"}
        core_slim["files"] = [{k: v for k, v in f.items() if k != "residual_diff"}
                              for f in core.get("files", [])]
    (out / "status.json").write_text(json.dumps(
        {"generated": now, "commit": commit, "lanes": lanes, "core": core_slim,
         "contract": contract, "manifest": manifest}, indent=2))
    print(f"wrote {out/'index.html'} and {out/'status.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
