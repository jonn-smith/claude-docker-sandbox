# Plugin pin ledger

`settings.json` pins each third-party plugin/marketplace to a tag (`ref: "vX.Y.Z"`). Tags are mutable on the upstream side — anyone with push access can force-move them. This file records the immutable commit SHA each pinned tag SHOULD resolve to at the time it was committed, so a future maintainer can verify the upstream hasn't silently rewritten history.

To verify a pin:

```bash
curl -fsSL https://api.github.com/repos/<owner>/<repo>/git/refs/tags/<ref> \
  | python3 -c "import json,sys,urllib.request; r=json.load(sys.stdin); o=r['object']; print(o['sha'] if o['type']!='tag' else json.loads(urllib.request.urlopen(o['url']).read())['object']['sha'])"
```

If the resolved SHA does NOT match the value in this file, do NOT bump — investigate first (the tag may have been moved maliciously, or upstream may have legitimately re-cut a release).

## Pinned refs

| Plugin / marketplace | settings.json key | ref | expected commit SHA |
|---|---|---|---|
| [caveman](https://github.com/JuliusBrussee/caveman) | `extraKnownMarketplaces.caveman` | `v1.8.2` | `63a91ecadbf4c4719a4602a5abb00883f9966034` |

## Automatic drift detection

`docker/start_script.sh` runs a `check_pin` probe for each pinned marketplace at container boot, after MCP registration and before launching `claude`. It compares the cached marketplace's git HEAD against the SHA hardcoded in that script and prints either:

- `pin-check (<name>): OK at <sha>` — match, silent on success otherwise.
- A loud red `PIN DRIFT WARNING` banner with expected vs installed SHA — non-fatal, claude still launches.

The probe is non-blocking; it never wipes the cache automatically.

## Bump procedure

1. Pick the new upstream tag.
2. Resolve its commit SHA with the snippet above.
3. Update `ref:` in `settings.json`, the SHA row in this table, AND the hardcoded SHA in `check_pin caveman <SHA>` near the bottom of `docker/start_script.sh` — all three must agree, all in the same commit.
4. Commit message should reference both the old and new SHAs so the upstream-rewrite case stays auditable.
5. To force every running sandbox to actually pull the new ref (Claude Code uses `known_marketplaces.json` as the source-of-truth for *existing* installs, not `settings.json`), wipe the cache and let claude re-resolve:
   ```bash
   cd claude-sandbox-shared/.claude/plugins
   rm -rf marketplaces/<name> cache/<name> data/<name>-<name>
   jq 'del(.["<name>"])' known_marketplaces.json > tmp \
     && mv tmp known_marketplaces.json
   ```
   Then restart the sandbox.
