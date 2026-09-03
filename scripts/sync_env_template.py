#!/usr/bin/env python3
# sync_env_template.py — back-fill fields from envs/env.example.sh into every
# other envs/env.*.sh. Any variable (and its comment) present in the example
# but missing from a local env is inserted at the matching relative position;
# existing local values are never touched.
#
#   scripts/sync_env_template.py            # dry-run: per-file, what it'd add
#   scripts/sync_env_template.py --go       # write changes (.bak backups)
#
# How position is decided: each example field is inserted right after its
# nearest preceding example field that already exists in the local file
# (fields required in every env — INSTANCE, PROJECTS_DIR, USE_SHARED — make
# reliable anchors). A field with no comment directly above it in the example
# (a sibling under a shared comment block, e.g. FISS_MCP_ALLOW_WRITES) is
# inserted as a bare line next to its kin, without duplicating the comment.
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENVS = ROOT / "envs"
EXAMPLE = ENVS / "env.example.sh"
GO = "--go" in sys.argv

EXPORT_RE = re.compile(r'^\s*#?\s*export\s+([A-Za-z_][A-Za-z0-9_]*)=')
HEADER_RE = re.compile(r'^__ENV_SCRIPT_DIR=')


def parse_example(lines):
    """Return ordered [(var, block_text_lines)] for fields after the header.
    block_text = the contiguous comment/blank preamble directly above the
    export line + the export line itself (preamble empty for grouped
    siblings whose line above is another export)."""
    # Start after the __ENV_SCRIPT_DIR header line.
    start = next((i for i, l in enumerate(lines) if HEADER_RE.match(l)), -1) + 1
    blocks = []
    pending = []
    for l in lines[start:]:
        m = EXPORT_RE.match(l)
        if m:
            blocks.append((m.group(1), pending + [l]))
            pending = []
        elif l.strip() == "unset __ENV_SCRIPT_DIR":
            break
        else:
            pending.append(l)
    return blocks


def present_vars(lines):
    """var -> index of its export line, for every export/#export in the file."""
    out = {}
    for i, l in enumerate(lines):
        m = EXPORT_RE.match(l)
        if m and m.group(1) not in out:
            out[m.group(1)] = i
    return out


def sync_file(path, ex_blocks, ex_order):
    lines = path.read_text().splitlines()
    have = present_vars(lines)
    header_idx = next((i for i, l in enumerate(lines) if HEADER_RE.match(l)), 0)

    # For each missing example field, choose an anchor line index in the local.
    inserts = {}   # local_line_index -> [block_text_lines, ...]  (insert AFTER)
    header_inserts = []
    added = []
    for i, var in enumerate(ex_order):
        if var in have:
            continue
        block = dict(ex_blocks)[var]
        # nearest preceding example var present in the local file
        anchor = None
        for j in range(i - 1, -1, -1):
            if ex_order[j] in have:
                anchor = have[ex_order[j]]
                break
        if anchor is None:
            header_inserts.extend(block)
        else:
            inserts.setdefault(anchor, []).extend(block)
        added.append(var)

    if not added:
        return [], None  # nothing to do

    # Rebuild the file, splicing inserts in.
    out = []
    for i, l in enumerate(lines):
        out.append(l)
        if i == header_idx and header_inserts:
            out.extend(header_inserts)
        if i in inserts:
            out.extend(inserts[i])
    return added, "\n".join(out) + "\n"


def main():
    ex_lines = EXAMPLE.read_text().splitlines()
    ex_blocks = parse_example(ex_lines)
    ex_order = [v for v, _ in ex_blocks]

    targets = sorted(p for p in ENVS.glob("env.*.sh") if p.name != "env.example.sh")
    if not targets:
        print("no envs/env.*.sh to sync"); return

    total = 0
    for p in targets:
        added, newtext = sync_file(p, ex_blocks, ex_order)
        if not added:
            print(f"  {p.name}: up to date")
            continue
        total += len(added)
        print(f"  {p.name}: +{len(added)} -> {', '.join(added)}")
        if GO:
            p.with_suffix(".sh.bak").write_text(p.read_text())
            p.write_text(newtext)

    print()
    if GO:
        print(f"Synced {total} field(s). Backups written as env.<name>.sh.bak.")
    else:
        print(f"Dry-run: would add {total} field(s). Re-run with --go to apply.")


if __name__ == "__main__":
    main()
