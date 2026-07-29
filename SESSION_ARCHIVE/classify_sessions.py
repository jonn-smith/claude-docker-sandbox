#!/usr/bin/env python3
# classify_sessions.py — assign each archived session to a project, using
# the operator-supplied project list as the label set. Emits a PROPOSAL
# table (CLASSIFIED.md); moves nothing. Run archive_sessions.sh first.
#
# Why a fixed label set: with the known list of projects per env, this is
# classification (closed set) not discovery (open set) — far more reliable.
# Scoring is weighted keyword match over each transcript's raw text:
#   path form  /workspace/<exact-dir>   weight 10  (near ground-truth: the
#                                                   actual checkout dir)
#   distinctive token                    weight 3
#   weak/generic token                   weight 1  (used sparingly; tokens
#                                                   like "GATK" or "fiss-mcp"
#                                                   appear as tool-use noise
#                                                   everywhere, so those
#                                                   projects lean on the path
#                                                   form instead)
# argmax wins; 0 -> UNKNOWN; top two within 1 and from different projects
# -> AMBIGUOUS (both shown). Human confirms before any files move.
#
# ponytail: raw-text grep per file, stdlib only, no json parse per line.
import os
import re
import sys
from pathlib import Path

ARCHIVE = Path(__file__).resolve().parent

# (project, env, [(pattern, weight), ...]). Patterns matched
# case-insensitively against the whole transcript text.
PROJECTS = [
    # main
    # Only patterns UNIQUE to sandbox-dev work. Deliberately NOT ponytail
    # / caveman / CLAUDE_SANDBOX_ / statusline — those are injected into
    # EVERY transcript by hooks + system reminders, so they identify the
    # sandbox environment, not the session's project. Including them
    # mis-bucketed 169/238 sessions here.
    ("claude-sandbox-dev", "main", [
        (r"unix-socket-remote-control", 10), (r"anthropic-router", 10),
        (r"run_claude_docker", 6), (r"rc-bridge", 5),
        (r"SESSION_ARCHIVE", 5), (r"remote control", 3)]),
    ("hvp-lr-repo", "main", [
        (r"/workspace/HVP-LR", 10), (r"hvp-dasc", 5), (r"HvpReadRescue", 5),
        (r"human[_ ]virome", 3), (r"\bhvp-lr\b", 3)]),
    ("gambia-joint-call", "main", [
        (r"gambia", 5), (r"joint[_-]call", 5)]),
    # B
    ("bwa-mem2-gpu", "B/WHB", [(r"bwa-mem2", 8)]),
    ("lxh2-pedal-stuff", "B", [(r"\bLXH2\b", 8), (r"pedal", 4)]),
    ("ProtBindScreen", "B", [(r"ProtBindScreen", 10)]),
    ("fiss-mcp", "B", [(r"/workspace/fiss-mcp", 10), (r"run-server\.py", 4)]),
    ("annual-eval-drafter", "B", [
        (r"annual[_ ]eval", 8), (r"evaluation_drafter", 8)]),
    ("citi_training", "B", [(r"citi[_ ]training", 8), (r"\bCITI\b", 4)]),
    ("egpu_setup", "B", [(r"\begpu\b", 8)]),
    ("long-read-pipelines", "B", [
        (r"long[_-]read[_-]pipelines", 10), (r"configure-statusline", 4)]),
    ("meal-plans-and-shopping", "B", [
        (r"meal[_ -]plan", 8), (r"shopping list", 5)]),
    # WHB
    ("genomicsdb-audit", "WHB", [
        (r"/workspace/GenomicsDB", 10), (r"GenomicsDB", 4), (r"vectorization", 3)]),
    ("voice-cloning-pipeline", "WHB", [(r"voice[_ -]clon", 8)]),
    ("Terra_Pf8", "WHB", [
        (r"/workspace/terra_pf7_pf8", 10), (r"\bPf8\b", 5), (r"\bPf7\b", 3)]),
    ("riker_vs_picard", "WHB", [(r"riker", 8), (r"riker_vs_picard", 10)]),
    ("lr_malaria", "WHB", [(r"/workspace/lr_malaria", 10), (r"lr_malaria", 6)]),
    ("chr9_deletions", "WHB", [
        (r"/workspace/chr9_deletions", 10), (r"senegal_chr9", 8), (r"chr9", 3)]),
    ("niare_reproduced", "WHB", [(r"niare", 8)]),
    ("terra_sr_malaria_validation", "WHB", [
        (r"terra_sr_malaria", 10), (r"sr_malaria", 6)]),
    # GATK
    ("GATK", "GATK", [(r"/workspace/GATK\b", 10), (r"GATK_EXPLORE", 8)]),
    ("server_dashboard", "GATK", [(r"server[_ ]dashboard", 8)]),
    ("genotypegvcfs-vs-gnarly-deck", "GATK", [
        (r"gnarlygenotyper", 8), (r"\bgnarly\b", 5), (r"genotypegvcfs", 4)]),
]

COMPILED = [
    (proj, env, [(re.compile(p, re.I), w) for p, w in pats])
    for proj, env, pats in PROJECTS
]


def score(text):
    out = []
    for proj, env, pats in COMPILED:
        s = sum(w * len(r.findall(text)) for r, w in pats)
        if s:
            out.append((s, proj, env))
    out.sort(reverse=True)
    return out


def classify(text):
    ranked = score(text)
    if not ranked:
        return "UNKNOWN", "", 0
    top = ranked[0]
    if len(ranked) > 1 and top[0] - ranked[1][0] <= 1 and ranked[1][1] != top[1]:
        return f"AMBIGUOUS:{top[1]}|{ranked[1][1]}", top[2], top[0]
    return top[1], top[2], top[0]


# Pull the signal-bearing slice out of a transcript: the custom title,
# the first real user prompt (not the title-gen boilerplate), and every
# /workspace/<path> mention. Everything else — hook output, system
# reminders, tool results quoting other projects — is noise that made
# infra tokens match every session. Score only this slice.
TITLE_RE = re.compile(r'"customTitle":"((?:[^"\\]|\\.)*)"')
WS_PATH_RE = re.compile(r"/workspace/[A-Za-z0-9_.-]+")
PROMPT_RE = re.compile(r'"role":"user".*?"content":"((?:[^"\\]|\\.){0,400})')


def signal_text(text):
    parts = []
    parts += TITLE_RE.findall(text)
    parts += WS_PATH_RE.findall(text)
    for m in PROMPT_RE.finditer(text):
        p = m.group(1)
        if not p.startswith(("Summarize this task", "Reply with only", "<")):
            parts.append(p)
            if len(parts) > 40:
                break
    return " ".join(parts)


def main():
    rows = []
    for src in sorted(ARCHIVE.glob("*/projects")):
        label = src.parent.name
        for f in sorted(src.rglob("*.jsonl")):
            text = f.read_text(errors="ignore")
            date = ""
            m = re.search(r'"timestamp":"(\d{4}-\d\d-\d\d)', text)
            if m:
                date = m.group(1)
            proj, penv, sc = classify(signal_text(text))
            rows.append((label, date, f.stem[:8], proj, penv, sc))

    rows.sort(key=lambda r: (r[0], r[1]))

    out = ARCHIVE / "CLASSIFIED.md"
    with out.open("w") as fh:
        fh.write("# Proposed session -> project classification\n\n")
        fh.write("Generated by classify_sessions.py. PROPOSAL — nothing moved.\n\n")
        fh.write("| source | date | session | project | env | score |\n")
        fh.write("|---|---|---|---|---|---|\n")
        for label, date, sid, proj, penv, sc in rows:
            fh.write(f"| {label} | {date or '?'} | {sid} | {proj} | {penv} | {sc} |\n")

        # summary
        from collections import Counter
        c = Counter(r[3] for r in rows)
        fh.write("\n## Counts by project\n\n")
        for proj, n in sorted(c.items(), key=lambda kv: -kv[1]):
            fh.write(f"- {proj}: {n}\n")

    unknown = sum(1 for r in rows if r[3] == "UNKNOWN")
    ambig = sum(1 for r in rows if r[3].startswith("AMBIGUOUS"))
    print(f"Classified {len(rows)} sessions -> {out.name}")
    print(f"  UNKNOWN: {unknown}   AMBIGUOUS: {ambig}   "
          f"assigned: {len(rows) - unknown - ambig}")


if __name__ == "__main__":
    main()
