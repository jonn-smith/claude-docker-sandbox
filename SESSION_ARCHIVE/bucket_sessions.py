#!/usr/bin/env python3
# bucket_sessions.py — copy each archived session into by-project/<label>/
# using the operator-confirmed attribution. DRY-RUN by default: prints the
# file->bucket manifest and counts, copies nothing. Pass --go to copy.
#
# Labels are resolved per file by: (1) explicit id override, (2) a couple
# of content disambiguations where one id-prefix covers two sessions,
# (3) a (source,date) default for the uniform blocks, (4) sidecar fallback.
# Sidecars are skipped (or sent to _sidecar/ with --keep-sidecars).
#
# ponytail: copy (not move) so the flat archive stays intact as the source
# of truth; by-project/ is a derived view you can regenerate or delete.
import re
import shutil
import sys
from pathlib import Path

ARCHIVE = Path(__file__).resolve().parent
GO = "--go" in sys.argv
KEEP_SIDE = "--keep-sidecars" in sys.argv
PRUNE = "--prune" in sys.argv   # delete _sidecar files from the archive

# (source, date) -> default label for blocks where every session is one project.
DATE_DEFAULT = {
    ("B", "2026-06-30"): "long-read-pipelines",
    ("B", "2026-07-07"): "meal-plans-and-shopping",
    ("B", "2026-07-16"): "terra_sr_malaria_validation",
    ("main", "2026-05-01"): "claude-sandbox-dev",
    ("main", "2026-05-11"): "hvp-lr-repo",
    ("main", "2026-06-02"): "hvp-lr-repo",
    ("main", "2026-06-22"): "hvp-lr-repo",
    ("main", "2026-06-23"): "hvp-lr-repo",
    ("main", "2026-06-24"): "hvp-lr-repo",
    ("main", "2026-06-28"): "hvp-lr-repo",
    ("main", "2026-07-04"): "claude-sandbox-dev",
    ("main", "2026-07-27"): "drive-cleanup",
    ("GATK", "2026-05-19"): "GATK",
    ("GATK", "2026-07-04"): "genotypegvcfs-vs-gnarly-deck",
    ("GATK", "2026-07-07"): "GATK",
    ("WHB", "2026-06-08"): "chr9_deletions",
    ("WHB", "2026-07-04"): "niare_reproduced",
    ("WHB", "2026-07-07"): "terra_sr_malaria_validation",
    ("WHB", "2026-07-09"): "terra_sr_malaria_validation",
    ("shared", "2026-04-23"): "Terra_Pf8",
    ("shared", "2026-04-25"): "homomorphic_encryption",
    ("shared", "2026-04-27"): "virus_taxonomy_presentation",
    ("shared", "2026-04-29"): "bwa-mem2-gpu",
    ("shared", "2026-05-01"): "pybirdbuddy",
}

# (source, date, id8) -> label. id8 = stem[:8]; for uuid files that's the
# leading hex, for agent files it's "agent-aX" (unique per date except the
# 04-29 agent-ae pair, handled by content below).
ID_OVERRIDE = {
    ("main", "2026-07-22", "041f46c1"): "gambia-joint-call",
    ("main", "2026-07-22", "da1ae5f8"): "meal-plans-and-shopping",
    ("GATK", "2026-05-18", "agent-a1"): "GATK",
    ("GATK", "2026-05-18", "ba10ce07"): "genotypegvcfs-vs-gnarly-deck",
    ("GATK", "2026-07-04", "fe90af34"): "GATK",
    ("shared", "2026-04-23", "4900301e"): "dimensional_stack_visualization",
    ("shared", "2026-04-23", "agent-af"): "claude-sandbox-dev",
    ("shared", "2026-04-29", "85222b5d"): "terra_backups",
    ("shared", "2026-04-29", "90c3fae5"): "voice-cloning-pipeline",
    ("shared", "2026-05-01", "a0575475"): "claude-sandbox-dev",
    ("shared", "2026-05-01", "agent-a4"): "_sidecar",
    ("WHB", "2026-07-07", "d7bba19b"): "terra_sr_malaria_validation",
    ("WHB", "2026-07-15", "2cc1f678"): "_sidecar",   # "respond with ok" RC test ping
    ("main", "2026-07-07", "56feef38"): "claude-sandbox-dev",
}

DATERE = re.compile(r'"timestamp":"(\d{4}-\d\d-\d\d)')


def file_date(f):
    with open(f, "r", errors="ignore") as fh:
        blob = fh.read(65536)
    m = DATERE.search(blob)
    return m.group(1) if m else "?"


def is_sidecar(f, blob):
    # Title-gen, notification-summary, journal, or trivial test ping.
    return (
        '"lastPrompt":"Summarize this task in 5 words' in blob
        or "You are summarizing a completed Claude Code task" in blob
        or f.stem.startswith("journal")
    )


def label_for(source, date, f):
    id8 = f.stem[:8]
    key = (source, date, id8)
    if key in ID_OVERRIDE:
        return ID_OVERRIDE[key]

    # 04-24 shared block: all title-gen / notification / empty shards.
    if source == "shared" and date == "2026-04-24":
        return "_sidecar"
    # WHB 07-14: RC-bridge test pings + empty.
    if source == "WHB" and date == "2026-07-14":
        return "_sidecar"

    with open(f, "r", errors="ignore") as fh:
        blob = fh.read(65536)

    # 04-29 agent-ae pair: voice-cloning vs a session-storage meta question.
    if source == "shared" and date == "2026-04-29" and id8 == "agent-ae":
        return "voice-cloning-pipeline" if re.search(r"herzog|voice", blob, re.I) else "_sidecar"

    if is_sidecar(f, blob):
        return "_sidecar"

    return DATE_DEFAULT.get((source, date), "_UNRESOLVED")


def main():
    plan = []
    for src in sorted(ARCHIVE.glob("*/projects")):
        source = src.parent.name
        for f in sorted(src.rglob("*.jsonl")):
            date = file_date(f)
            plan.append((source, date, f, label_for(source, date, f)))

    from collections import Counter
    counts = Counter(lbl for _, _, _, lbl in plan)

    print(f"{'DRY-RUN — nothing copied' if not GO else 'COPYING'}  "
          f"({len(plan)} sessions)\n")
    for lbl, n in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])):
        print(f"  {n:4d}  {lbl}")

    unresolved = [p for p in plan if p[3] == "_UNRESOLVED"]
    if unresolved:
        print("\n_UNRESOLVED (no rule matched — fix before --go):")
        for source, date, f, _ in unresolved:
            print(f"  {source} {date} {f.name}")

    if not (GO or PRUNE):
        print("\nRe-run with --go to copy into by-project/ "
              "(--keep-sidecars also copies _sidecar), and/or --prune to "
              "delete _sidecar files from the archive.")
        return

    # Prune: delete _sidecar transcripts (and any same-stem sidecar dir) from
    # the archive copies. Originals in the live state dirs are untouched, and
    # archive_sessions.sh regenerates these if ever needed.
    if PRUNE:
        pruned = 0
        for source, date, f, lbl in plan:
            if lbl != "_sidecar":
                continue
            sib = f.with_suffix("")  # projects/-workspace/<uuid>/ sidecar dir
            if sib.is_dir():
                shutil.rmtree(sib, ignore_errors=True)
            f.unlink(missing_ok=True)
            pruned += 1
        print(f"\nPruned {pruned} sidecar files from the archive.")

    if GO:
        dest_root = ARCHIVE / "by-project"
        copied = 0
        for source, date, f, lbl in plan:
            if lbl == "_sidecar":
                if not KEEP_SIDE:
                    continue
                if not f.exists():   # already pruned
                    continue
            d = dest_root / lbl
            d.mkdir(parents=True, exist_ok=True)
            # Prefix with source so same-id sessions from different state
            # dirs (e.g. a0575475 in main and shared) don't collide.
            shutil.copy2(f, d / f"{source}__{f.name}")
            copied += 1
        print(f"Copied {copied} sessions into "
              f"{dest_root.relative_to(ARCHIVE)}/")


if __name__ == "__main__":
    main()
