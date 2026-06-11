# Plugin pin ledger

Some third-party plugins are **vendored** — the marketplace source tree
is committed to this repo so a fresh clone has working plugins without
fetching from GitHub at first session. Others are **referenced** via
`settings.json` `extraKnownMarketplaces` with a `ref: "vX.Y.Z"` tag.

Tags are mutable on the upstream side — anyone with push access can
force-move them. This file records the immutable commit SHA each
pinned tag SHOULD resolve to at the time it was committed/vendored, so
a future maintainer can verify the upstream hasn't silently rewritten
history.

To verify a pin:

```bash
curl -fsSL https://api.github.com/repos/<owner>/<repo>/git/refs/tags/<ref> \
  | python3 -c "import json,sys,urllib.request; r=json.load(sys.stdin); o=r['object']; print(o['sha'] if o['type']!='tag' else json.loads(urllib.request.urlopen(o['url']).read())['object']['sha'])"
```

If the resolved SHA does NOT match the value in this file, do NOT bump — investigate first (the tag may have been moved maliciously, or upstream may have legitimately re-cut a release).

## Pinned refs

| Plugin / marketplace | mode | ref | expected commit SHA |
|---|---|---|---|
| [caveman](https://github.com/JuliusBrussee/caveman) | **vendored** at `claude-sandbox-shared/.claude/plugins/marketplaces/caveman/` | `v1.8.2` | `63a91ecadbf4c4719a4602a5abb00883f9966034` |

The `extraKnownMarketplaces.caveman` entry in `settings.json` is kept as a
fallback — if the vendored tree is ever absent, claude-code can still
clone from upstream at the same pinned ref.

## Automatic drift detection

`docker/start_script.sh` runs a `check_pin` probe for each pinned marketplace at container boot, after MCP registration and before launching `claude`. It compares the cached marketplace's git HEAD against the SHA hardcoded in that script and prints either:

- `pin-check (<name>): OK at <sha>` — match, silent on success otherwise.
- A loud red `PIN DRIFT WARNING` banner with expected vs installed SHA — non-fatal, claude still launches.

The probe is non-blocking; it never wipes the cache automatically.

## Bump procedure (vendored)

1. Pick the new upstream tag (e.g. `v1.9.0`).
2. Clone fresh + verify SHA:
   ```bash
   tmp=$(mktemp -d) && git clone --depth 1 --branch v1.9.0 https://github.com/JuliusBrussee/caveman "$tmp/caveman"
   git -C "$tmp/caveman" rev-parse HEAD       # capture this
   ```
3. Replace the vendored tree (strip `.git/` so git doesn't see a nested repo):
   ```bash
   rm -rf claude-sandbox-shared/.claude/plugins/marketplaces/caveman
   cp -a "$tmp/caveman" claude-sandbox-shared/.claude/plugins/marketplaces/caveman
   rm -rf claude-sandbox-shared/.claude/plugins/marketplaces/caveman/.git
   ```
4. Update `ref:` in `settings.json`, the SHA row in this table, AND the
   hardcoded SHA in `check_pin caveman <SHA>` near the bottom of
   `docker/start_script.sh` — all three must agree.
5. Wipe any host-side claude-code cache so it rebuilds from the new vendored source:
   ```bash
   rm -rf claude-sandbox-shared/.claude/plugins/cache/caveman \
          claude-sandbox-shared/.claude/plugins/data/caveman-caveman
   jq 'del(.caveman)' claude-sandbox-shared/.claude/plugins/known_marketplaces.json \
     > /tmp/km.json && mv /tmp/km.json claude-sandbox-shared/.claude/plugins/known_marketplaces.json
   ```
6. Commit message should reference both the old and new SHAs so the
   upstream-rewrite case stays auditable.

To verify the upstream tag's SHA matches what we vendored, use the
snippet at the top of this file.
