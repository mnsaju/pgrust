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

Scope: every test in the schedule gets a verdict, not just the overlaid ones.
The overlay covers 154 of the suite's 230 scheduled tests; the rest are
compared verbatim against vendor's expected output, because a comparator that
examines only the files it has annotations for reports a green ratchet over a
silently shortened list. Baseline selection follows pg_regress: a test matching
any of expected/<name>.out or expected/<name>_0..9.out passes, and a failing
test's diff is reported against the closest of them, named in the output.

Usage:
    rowsort_compare.py --sql-dir regress/overlay/sql \\
        --actual-dir regress-work/regress-output/results \\
        --expected-dir regress-work/regress/expected \\
        --schedule-file regress-work/regress/schedule.run \\
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


def read_lines(path: Path) -> list[str]:
    """Reads a .out/.sql file for byte-exact comparison. Several of vendor's
    expected files are not UTF-8 (euc_kr, collate.windows.win1252, ...), and
    pg_regress compares them with plain diff, i.e. as bytes. surrogateescape
    round-trips those bytes losslessly, so equality here means byte equality;
    _unified_diff sanitises before anything is printed or serialised.
    """
    return path.read_text(encoding="utf-8", errors="surrogateescape").splitlines()


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
    # Which baseline the verdict was reached against, and whether this test
    # carries an overlay .sql (and therefore rowsort/stable-tie annotations)
    # or was compared verbatim against vendor's expected output.
    expected_file: str | None = None
    overlaid: bool = False


def expected_candidates(expected_dir: Path, name: str) -> list[Path]:
    """pg_regress's comparison baselines for one test, in its own order:
    expected/<name>.out first, then the secondary comparison files
    expected/<name>_0.out .. <name>_9.out (pg_regress.c results_differ ->
    get_alternative_expectfile). A test PASSES if it matches ANY of them, and
    the diff pg_regress reports is the one against the closest match.

    32 of the vendored suite's expected files are such alternatives, 8 of them
    for overlaid tests. Comparing only against <name>.out therefore both
    invents failures (collate.linux.utf8, collate.windows.win1252 and numa all
    legitimately match their _1 variant) and, worse, describes the ones that do
    fail against the wrong baseline: `compression` diffs by 181 lines against
    compression.out and by 6 against compression_1.out, so a ledger entry
    written from the former would be describing the wrong mechanism.

    resultmap (the other pg_regress baseline override) is not consulted: the
    vendored REL_18_3 resultmap maps float4 on cygwin/mingw only, and this
    harness runs on Linux.
    """
    out = []
    default = expected_dir / f"{name}.out"
    if default.exists():
        out.append(default)
    for i in range(10):
        alt = expected_dir / f"{name}_{i}.out"
        if alt.exists():
            out.append(alt)
    return out


def compare_test(name: str, sql_path: Path | None, actual_path: Path, expected_dir: Path) -> FileResult:
    """Verdict for one test against every baseline pg_regress would have
    tried, keeping the closest match's diff when none of them pass."""
    if not actual_path.exists():
        return FileResult(name, "error", overlaid=sql_path is not None, error=f"no actual output at {actual_path}")
    candidates = expected_candidates(expected_dir, name)
    if not candidates:
        return FileResult(
            name, "error", overlaid=sql_path is not None, error=f"no expected output at {expected_dir}/{name}.out"
        )

    best: FileResult | None = None
    for expected_path in candidates:
        r = compare_file(name, sql_path, actual_path, expected_path)
        r.expected_file = expected_path.name
        r.overlaid = sql_path is not None
        if r.status in ("exact", "rowsort-relaxed"):
            return r
        if best is None or len(r.residual_diff) < len(best.residual_diff):
            best = r
    assert best is not None
    return best


def compare_file(name: str, sql_path: Path | None, actual_path: Path, expected_path: Path) -> FileResult:
    # sql_path is None for a test with no overlay .sql: there are no
    # rowsort/stable-tie annotations to honour, so the comparison is the plain
    # one pg_regress itself does.
    sql_lines = read_lines(sql_path) if sql_path is not None else []
    actual_raw = read_lines(actual_path)
    expected_lines = read_lines(expected_path)
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

    for line in difflib.unified_diff(expected, actual, fromfile="expected", tofile="actual", lineterm=""):
        # Undo read_lines' surrogateescape so the diff can be printed and
        # JSON-serialised; the comparison itself already happened on the
        # lossless form.
        yield line.encode("utf-8", "surrogateescape").decode("utf-8", "backslashreplace")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sql-dir", required=True, type=Path, help="overlay sql dir (regress/overlay/sql)")
    ap.add_argument("--actual-dir", required=True, type=Path, help="pg_regress results dir (results/*.out)")
    ap.add_argument("--expected-dir", required=True, type=Path, help="vendor expected dir (expected/*.out)")
    ap.add_argument(
        "--schedule-file",
        type=Path,
        help="the pg_regress schedule that was run (regress-work/regress/schedule.run). It is the "
        "authoritative list of what had to be checked: every test in it gets a verdict, a scheduled "
        "test with no results file is an error, and an overlay .sql that is not in it is reported as "
        "unchecked rather than silently dropped. Without it the test set is whatever .out files the "
        "run produced, which cannot show a test that died before writing any.",
    )
    ap.add_argument("--json", type=Path, help="write a JSON report here")
    ap.add_argument("--show-diffs", action="store_true", help="print residual diffs for failing files")
    ap.add_argument(
        "--allow-file",
        type=Path,
        help="ratchet ledger of known-failing test names (one per line, '#' comments). "
        "Listed files may fail without failing the run; a listed file that PASSES is "
        "reported as stale and also fails, so the ledger can only shrink.",
    )
    args = ap.parse_args()

    allowed: set[str] = set()
    if args.allow_file:
        if not args.allow_file.exists():
            print(f"allow-file not found: {args.allow_file}", file=sys.stderr)
            return 2
        for line in args.allow_file.read_text().splitlines():
            line = line.split("#", 1)[0].strip()
            if line:
                allowed.add(line)

    overlay = {p.stem: p for p in sorted(args.sql_dir.glob("*.sql"))}
    if not overlay:
        print(f"no .sql files found in {args.sql_dir}", file=sys.stderr)
        return 2

    # What had to be checked. The overlay is only 154 of the suite's 230
    # scheduled tests; deriving the test set from it alone gave the other 76 no
    # verdict at all -- a silently shortened test list, in which four real
    # failures sat invisible behind a green ratchet. The schedule is the
    # authoritative answer to "what ran"; the results directory is the fallback.
    if args.schedule_file:
        if not args.schedule_file.exists():
            print(f"schedule-file not found: {args.schedule_file}", file=sys.stderr)
            return 2
        names: list[str] = []
        seen: set[str] = set()
        for line in args.schedule_file.read_text().splitlines():
            line = line.split("#", 1)[0].strip()
            if not line.startswith("test:"):
                continue
            for n in line[len("test:") :].split():
                if n not in seen:
                    seen.add(n)
                    names.append(n)
        source = f"schedule {args.schedule_file}"
    else:
        # Fallback: "what ran" is whatever the run produced. Taking the union
        # with the overlay instead would score numeric_big -- overlaid, never
        # scheduled -- as an error again. A test that crashed before writing
        # any output is invisible here, which is why --schedule-file is the
        # supported path and the source is printed either way.
        names = sorted(p.stem for p in args.actual_dir.glob("*.out"))
        source = f"{args.actual_dir} (no --schedule-file)"
    names = sorted(names)

    results: list[FileResult] = []
    for name in names:
        results.append(
            compare_test(name, overlay.get(name), args.actual_dir / f"{name}.out", args.expected_dir)
        )

    # Overlay files outside the test set were never run, so they carry no
    # verdict either way. Say so instead of scoring them: numeric_big is
    # overlaid but absent from parallel_schedule (upstream runs it only via
    # EXTRA_TESTS), and calling that an "error" put a test that never executed
    # into the ledger as though pgrust had failed it.
    not_run = sorted(set(overlay) - set(names))

    by_status: dict[str, list[FileResult]] = {}
    for r in results:
        by_status.setdefault(r.status, []).append(r)

    total = len(results)
    n_overlaid = sum(1 for r in results if r.overlaid)
    print(f"{total} tests checked (from {source})")
    print(f"  {n_overlaid} with an overlay .sql (rowsort/stable-tie honoured), {total - n_overlaid} compared verbatim")
    for status in ("exact", "rowsort-relaxed", "fail", "error"):
        rs = by_status.get(status, [])
        print(f"  {status}: {len(rs)}")
        if status in ("fail", "error"):
            for r in rs:
                detail = r.error if r.error else f"vs {r.expected_file}"
                print(f"    - {r.name}: {detail}")
                if args.show_diffs and r.residual_diff:
                    for line in r.residual_diff[:40]:
                        print(f"        {line}")
    if not_run:
        print(f"  NOT CHECKED (overlaid but not in the test set): {len(not_run)}")
        for n in not_run:
            print(f"    - {n}")

    if args.json:
        args.json.write_text(
            json.dumps(
                {
                    "total": total,
                    "counts": {k: len(v) for k, v in by_status.items()},
                    "not_checked": not_run,
                    "files": [
                        {
                            "name": r.name,
                            "status": r.status,
                            "overlaid": r.overlaid,
                            "expected_file": r.expected_file,
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

    bad = {r.name for r in by_status.get("fail", [])} | {r.name for r in by_status.get("error", [])}

    if not args.allow_file:
        return 1 if bad else 0

    # Ratchet: only failures absent from the ledger break the build, and a
    # ledger entry that has started passing must be removed (otherwise the
    # baseline silently permits a future regression in that file).
    new_failures = sorted(bad - allowed)
    stale = sorted(allowed - bad)
    print()
    print(f"ratchet ledger: {args.allow_file} ({len(allowed)} entries)")
    print(f"  known failures still failing : {len(allowed) - len(stale)}")
    if new_failures:
        print(f"  NEW failures (not in ledger) : {len(new_failures)}")
        for n in new_failures:
            print(f"    - {n}")
    if stale:
        print(f"  STALE entries (now passing)  : {len(stale)}")
        for n in stale:
            # Not necessarily "fixed": an entry also goes stale when the test
            # stopped being scored at all, which is how numeric_big -- never in
            # parallel_schedule -- sat in the ledger as a pgrust failure.
            print(f"    - {n}  <- no longer failing; remove it from the ledger")
    if new_failures or stale:
        return 1
    print("  no new failures, no stale entries")
    return 0


if __name__ == "__main__":
    sys.exit(main())
