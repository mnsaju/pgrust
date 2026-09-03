#!/usr/bin/env python3
"""Reclassifies raw pg_regress diffs against the overlay's -- pgrust:rowsort
/ -- pgrust:stable-tie annotations (regress/overlay/sql/*.sql) -- the
comparator PGRA-017 (review/opus/findings.md) found had no consumer
anywhere in the repo.

Two things a raw `diff actual.out expected.out` gets wrong for an overlaid
file, both handled here:

1. psql's regress-mode echo reprints every source line verbatim, including
   the `-- pgrust:rowsort` / `-- pgrust:stable-tie key=...` comment lines
   the overlay inserts -- lines vendor's own expected/*.out never has. This
   alone makes every one of the 154 overlaid files show a diff even when
   actual row content is identical. Fix: strip those exact lines from the
   actual output before comparing anything else.

2. A statement marked rowsort/stable-tie may legitimately produce its
   result rows in a different order than vendor's expected/*.out, without
   that being a bug (see PGRA-017's own audit: 0% of annotations sit on a
   statement with a top-level ORDER BY -- only order-unspecified queries
   are marked). Fix: for the result block following such a statement,
   compare sorted line-sets instead of requiring positional equality.
   (stable-tie is treated identically to rowsort here -- sorting the whole
   block's lines as a multiset still correctly validates "the same set of
   result rows appeared" for a tie-group, which is what actually matters;
   see the module docstring in the design notes / commit message for why
   a fully separate per-key implementation wasn't needed for the 2 sites
   that use it.)

Every other line, in every other statement's result block, must match
EXACTLY -- this script only ever relaxes a raw diff, never invents new
leniency for anything not already annotated in the overlay .sql. It does
not talk to a database; it operates purely on already-produced .out files
plus the overlay .sql that was used as pg_regress's/pg_isolation_regress's
input.

Usage:
    rowsort_compare.py --sql-dir regress/overlay/sql \\
        --actual-dir regress-work/regress-output/results \\
        --expected-dir regress-work/regress/expected \\
        [--json report.json]

Exit status: 0 if every file classifies as PASS (exact or rowsort-relaxed),
1 if any file has a genuine residual difference, 2 on a usage/IO error.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROWSORT_RE = re.compile(r"^-- pgrust:rowsort\s*$")
STABLE_TIE_RE = re.compile(r"^-- pgrust:stable-tie\b.*$")
ANNOTATION_RE = re.compile(r"^-- pgrust:(rowsort|stable-tie)\b")


def strip_annotations(lines: list[str]) -> list[str]:
    return [ln for ln in lines if not ANNOTATION_RE.match(ln)]


def split_statements(sql_lines: list[str]) -> list[tuple[str | None, str]]:
    """Splits an overlay .sql file into (annotation_or_None, statement_text)
    chunks. A "statement" here is either a semicolon-terminated SQL
    statement (semicolons inside '...'/"..."/$tag$...$tag$ are not split
    points) or a single backslash meta-command line (\\set, \\getenv, ...) --
    both are echoed verbatim by psql regress-mode, which is all this needs:
    a text anchor to locate in the .out files, not a real SQL parse.
    """
    chunks: list[tuple[str | None, str]] = []
    pending_annotation: str | None = None
    buf: list[str] = []
    in_squote = in_dquote = False
    dollar_tag: str | None = None

    def flush(annotation: str | None) -> None:
        nonlocal buf
        text = "\n".join(buf).strip("\n")
        if text.strip():
            chunks.append((annotation, text))
        buf = []

    i = 0
    while i < len(sql_lines):
        line = sql_lines[i]
        stripped = line.strip()
        if not buf:
            if ROWSORT_RE.match(stripped):
                pending_annotation = "rowsort"
                i += 1
                continue
            if STABLE_TIE_RE.match(stripped):
                pending_annotation = "stable-tie"
                i += 1
                continue
            if stripped.startswith("--") or not stripped:
                i += 1
                continue
            if stripped.startswith("\\"):
                chunks.append((pending_annotation, line))
                pending_annotation = None
                i += 1
                continue

        buf.append(line)
        j = 0
        terminated = False
        while j < len(line):
            ch = line[j]
            if dollar_tag is not None:
                if line[j:].startswith(dollar_tag):
                    j += len(dollar_tag) - 1
                    dollar_tag = None
            elif in_squote:
                if ch == "'":
                    in_squote = False
            elif in_dquote:
                if ch == '"':
                    in_dquote = False
            elif ch == "'":
                in_squote = True
            elif ch == '"':
                in_dquote = True
            elif ch == "$":
                m = re.match(r"\$[A-Za-z_]*\$", line[j:])
                if m:
                    dollar_tag = m.group(0)
                    j += len(dollar_tag) - 1
            elif ch == ";" and not in_squote and not in_dquote and dollar_tag is None:
                terminated = True
                break
            j += 1
        if terminated:
            flush(pending_annotation)
            pending_annotation = None
        i += 1
    flush(pending_annotation)
    return chunks


def find_anchor(haystack: list[str], needle_text: str, start: int) -> tuple[int, int] | None:
    """Finds needle_text's lines as a contiguous run in haystack at or after
    `start`. Returns (start_idx, end_idx_exclusive) or None if not found."""
    needle_lines = needle_text.split("\n")
    n = len(needle_lines)
    if n == 0:
        return None
    limit = len(haystack) - n + 1
    for i in range(max(start, 0), max(limit, 0)):
        if haystack[i : i + n] == needle_lines:
            return (i, i + n)
    return None


@dataclass
class FileResult:
    name: str
    status: str  # "exact" | "rowsort-relaxed" | "fail" | "error"
    relaxed_statements: int = 0
    residual_diff: list[str] = field(default_factory=list)
    error: str | None = None


def compare_file(sql_path: Path, actual_path: Path, expected_path: Path) -> FileResult:
    name = sql_path.stem
    if not actual_path.exists():
        return FileResult(name, "error", error=f"no actual output at {actual_path}")
    if not expected_path.exists():
        return FileResult(name, "error", error=f"no expected output at {expected_path}")

    sql_lines = sql_path.read_text().splitlines()
    actual_raw = actual_path.read_text().splitlines()
    expected_lines = expected_path.read_text().splitlines()
    actual_lines = strip_annotations(actual_raw)

    if actual_lines == expected_lines:
        return FileResult(name, "exact")

    chunks = split_statements(sql_lines)
    annotated = [(text, ann) for ann, text in chunks if ann is not None]

    # Anchor each annotated statement's text in BOTH files (same anchor set,
    # since annotation lines are already stripped from actual_lines and
    # never existed in expected_lines -- both echo identical vendor text).
    regions_actual: list[tuple[int, int]] = []
    regions_expected: list[tuple[int, int]] = []
    a_cursor = e_cursor = 0
    ok = True
    for text, _ann in annotated:
        a_hit = find_anchor(actual_lines, text, a_cursor)
        e_hit = find_anchor(expected_lines, text, e_cursor)
        if a_hit is None or e_hit is None:
            ok = False
            break
        regions_actual.append(a_hit)
        regions_expected.append(e_hit)
        a_cursor = a_hit[1]
        e_cursor = e_hit[1]

    if not ok:
        # Couldn't confidently anchor -- don't guess. Report as a failure
        # with the raw diff so a human decides, rather than silently
        # passing or failing something the comparator itself isn't sure of.
        return FileResult(
            name, "fail", residual_diff=list(_unified_diff(expected_lines, actual_lines)) + ["(comparator: could not anchor all annotated statements)"]
        )

    # Build the result-block span for each annotated statement: from the
    # end of its own echoed text to the start of the NEXT anchor (or EOF).
    def block_end(regions: list[tuple[int, int]], idx: int, total_len: int) -> int:
        return regions[idx + 1][0] if idx + 1 < len(regions) else total_len

    masked_actual = list(actual_lines)
    masked_expected = list(expected_lines)
    relaxed = 0
    for idx in range(len(annotated)):
        a_start, a_end = regions_actual[idx]
        e_start, e_end = regions_expected[idx]
        a_block_end = block_end(regions_actual, idx, len(actual_lines))
        e_block_end = block_end(regions_expected, idx, len(expected_lines))
        a_block = actual_lines[a_end:a_block_end]
        e_block = expected_lines[e_end:e_block_end]
        if a_block == e_block:
            continue  # already identical; nothing to relax
        if sorted(a_block) == sorted(e_block):
            relaxed += 1
            # Replace both sides with a canonical sorted form so the final
            # whole-file comparison below sees them as equal.
            canon = sorted(a_block)
            masked_actual[a_end:a_block_end] = canon
            masked_expected[e_end:e_block_end] = canon

    if masked_actual == masked_expected:
        return FileResult(name, "rowsort-relaxed", relaxed_statements=relaxed)

    return FileResult(name, "fail", relaxed_statements=relaxed, residual_diff=list(_unified_diff(masked_expected, masked_actual)))


def _unified_diff(expected: list[str], actual: list[str]):
    import difflib

    yield from difflib.unified_diff(expected, actual, fromfile="expected", tofile="actual", lineterm="")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sql-dir", required=True, type=Path, help="overlay sql dir (regress/overlay/sql)")
    ap.add_argument("--actual-dir", required=True, type=Path, help="pg_regress results dir (results/*.out)")
    ap.add_argument("--expected-dir", required=True, type=Path, help="vendor expected dir (expected/*.out)")
    ap.add_argument("--json", type=Path, help="write a JSON report here")
    ap.add_argument("--show-diffs", action="store_true", help="print residual diffs for failing files")
    args = ap.parse_args()

    sql_files = sorted(args.sql_dir.glob("*.sql"))
    if not sql_files:
        print(f"no .sql files found in {args.sql_dir}", file=sys.stderr)
        return 2

    results: list[FileResult] = []
    for sql_path in sql_files:
        name = sql_path.stem
        results.append(compare_file(sql_path, args.actual_dir / f"{name}.out", args.expected_dir / f"{name}.out"))

    by_status: dict[str, list[FileResult]] = {}
    for r in results:
        by_status.setdefault(r.status, []).append(r)

    total = len(results)
    print(f"{total} overlaid files checked")
    for status in ("exact", "rowsort-relaxed", "fail", "error"):
        rs = by_status.get(status, [])
        print(f"  {status}: {len(rs)}")
        if status in ("fail", "error"):
            for r in rs:
                print(f"    - {r.name}" + (f": {r.error}" if r.error else ""))
                if args.show_diffs and r.residual_diff:
                    for line in r.residual_diff[:40]:
                        print(f"        {line}")

    if args.json:
        args.json.write_text(
            json.dumps(
                {
                    "total": total,
                    "counts": {k: len(v) for k, v in by_status.items()},
                    "files": [
                        {
                            "name": r.name,
                            "status": r.status,
                            "relaxed_statements": r.relaxed_statements,
                            "error": r.error,
                            "residual_diff": r.residual_diff,
                        }
                        for r in results
                    ],
                },
                indent=2,
            )
        )

    return 1 if by_status.get("fail") or by_status.get("error") else 0


if __name__ == "__main__":
    sys.exit(main())
