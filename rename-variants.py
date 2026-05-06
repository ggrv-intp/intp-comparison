#!/usr/bin/env python3
"""
One-shot migration: legacy variant naming (v1..v6) -> current (v0..v3.1).

Run from the repo root.

Phase 1: rewrite directory-path tokens (longest match, exact substring) in
         every text file under git's view (tracked + non-ignored untracked).
Phase 2: rewrite standalone variant identifiers (v1, v2, ...) using a
         regex that excludes "v1.1" / "v10" / "myv1" etc.
Phase 3: `git mv` the directory entries.

Lowercase identifiers and path strings are rewritten. UPPERCASE bash variable
names (V1_STP, V3_STP, ...) are NOT touched -- handle those in a follow-up
commit if desired.

Usage:
  python3 rename-variants.py --dry-run            # summary
  python3 rename-variants.py --dry-run --diff-out rename.diff
  python3 rename-variants.py                      # apply
"""

import argparse
import difflib
import re
import subprocess
import sys
from pathlib import Path

# Phase 1: directory-path tokens.
DIR_RENAMES = [
    ("v1-original",        "v0-stap-classic"),
    ("v2-updated",         "v0.1-stap-k68"),
    ("v3-updated-resctrl", "v1-stap-native"),
    ("v4-hybrid-procfs",   "v2-c-stable-abi"),
    ("v5-bpftrace",        "v3.1-bpftrace"),
    ("v6-ebpf-core",       "v3-ebpf-libbpf"),
]

# Phase 2: variant identifiers. ORDER MATTERS -- rename an old name BEFORE
# any later mapping uses it as a new name.
ID_RENAMES = [
    ("v1", "v0"),
    ("v3", "v1"),
    ("v2", "v0.1"),
    ("v4", "v2"),
    ("v6", "v3"),
    ("v5", "v3.1"),
]

# Files whose content is the migration record itself; must NOT be rewritten.
EXCLUDE_PATHS = {
    "VERSIONS.md",
    "rename-variants.py",
}

# Path prefixes / glob-like prefixes to skip entirely.
EXCLUDE_PREFIXES = [
    "results/",
    ".git/",
]

# Specific files (often binaries or backups) to skip.
EXCLUDE_FILES = {
    "v1.1-stap-helper/intp-helper",
    "v1.1-stap-helper/helper.log",
    "v3-updated-resctrl/intp-resctrl.stp.pre-v1-restore.bak",
}


def is_excluded(rel: str) -> bool:
    if rel in EXCLUDE_PATHS or rel in EXCLUDE_FILES:
        return True
    return any(rel.startswith(p) for p in EXCLUDE_PREFIXES)


def is_text_file(path: Path) -> bool:
    try:
        with open(path, "rb") as f:
            chunk = f.read(8192)
    except OSError:
        return False
    return b"\x00" not in chunk


def list_files(repo_root: Path):
    """Tracked + non-ignored untracked, filtered."""
    res = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard"],
        cwd=repo_root, check=True, capture_output=True, text=True,
    )
    for line in res.stdout.splitlines():
        if not line:
            continue
        p = repo_root / line
        if not p.is_file():
            continue
        rel = p.relative_to(repo_root).as_posix()
        if is_excluded(rel):
            continue
        if not is_text_file(p):
            continue
        yield p


def transform(text: str) -> str:
    # Phase 1: directory paths (exact substring, longest first by ordering).
    for old, new in DIR_RENAMES:
        text = text.replace(old, new)
    # Phase 2: standalone identifiers.
    for old, new in ID_RENAMES:
        # Not preceded by alnum/_, not followed by digit, dot, hyphen, or letter.
        # Excludes "v1.1", "v10", "myv1", "v1-stap-native" (already path-rewritten
        # in Phase 1), but allows "v1," "v1)" "[v1]" "v1 " etc.
        pattern = re.compile(
            rf"(?<![a-zA-Z0-9_]){re.escape(old)}(?![\d.\-a-zA-Z])"
        )
        text = pattern.sub(new, text)
    return text


def count_changed_lines(before: str, after: str) -> int:
    a, b = before.splitlines(), after.splitlines()
    sm = difflib.SequenceMatcher(a=a, b=b)
    n = 0
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag != "equal":
            n += max(i2 - i1, j2 - j1)
    return n


def make_diff(rel: str, before: str, after: str) -> str:
    return "".join(difflib.unified_diff(
        before.splitlines(keepends=True),
        after.splitlines(keepends=True),
        fromfile=f"a/{rel}",
        tofile=f"b/{rel}",
        n=2,
    ))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true",
                    help="preview without writing or running git mv")
    ap.add_argument("--diff-out",
                    help="path to write full unified diff (only useful with --dry-run)")
    ap.add_argument("--repo-root", default=".",
                    help="repository root (default: current dir)")
    args = ap.parse_args()

    repo_root = Path(args.repo_root).resolve()
    if not (repo_root / ".git").exists():
        print(f"error: {repo_root} is not a git repo root", file=sys.stderr)
        return 2

    # ---- File-content rewrites ----
    rewrites = []
    for path in list_files(repo_root):
        try:
            before = path.read_text()
        except UnicodeDecodeError:
            continue
        after = transform(before)
        if before == after:
            continue
        rewrites.append((path, before, after))

    rewrites.sort(key=lambda t: t[0])

    print(f"Files {'that would be' if args.dry_run else ''} rewritten: "
          f"{len(rewrites)}\n", file=sys.stderr)
    for path, before, after in rewrites:
        rel = path.relative_to(repo_root).as_posix()
        n = count_changed_lines(before, after)
        prefix = "  would" if args.dry_run else "  wrote"
        print(f"{prefix}: {n:>3} line(s)  {rel}", file=sys.stderr)
        if not args.dry_run:
            path.write_text(after)

    if args.dry_run and args.diff_out:
        diff_path = Path(args.diff_out).resolve()
        with open(diff_path, "w") as f:
            for path, before, after in rewrites:
                rel = path.relative_to(repo_root).as_posix()
                f.write(make_diff(rel, before, after))
        print(f"\nFull diff written to: {diff_path}", file=sys.stderr)

    # ---- Directory renames ----
    print("\nDirectory renames:", file=sys.stderr)
    for old, new in DIR_RENAMES:
        old_path = repo_root / old
        if not old_path.exists():
            print(f"  skip: {old} (not present)", file=sys.stderr)
            continue
        if args.dry_run:
            print(f"  would: git mv {old} {new}", file=sys.stderr)
        else:
            subprocess.run(["git", "mv", old, new], cwd=repo_root, check=True)
            print(f"  done:  {old} -> {new}", file=sys.stderr)

    if args.dry_run:
        print("\n(dry-run: no files written, no git mv executed)", file=sys.stderr)
    else:
        print("\nDone. Review with `git status` and `git diff --stat`.", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
