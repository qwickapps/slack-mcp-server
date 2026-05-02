# Upstream Tracking

## Pinned upstream version

| Field | Value |
|---|---|
| Upstream repo | https://github.com/korotovsky/slack-mcp-server |
| Pinned tag | `v1.2.3` |
| Pinned digest | `sha256:7ae77761d9f6e8da2b0fc7e7bf9f489615865af533990e0e06bc3eed49e0b91e` |
| Fork date | 2026-04-29 |
| Base image registry | `ghcr.io/korotovsky/slack-mcp-server` |

## Sync cadence

Weekly sync via `.github/workflows/sync-upstream.yml` (TODO: implement in a later phase).

Manual sync procedure until then:
```bash
git fetch upstream
git merge upstream/master --no-edit
# Resolve conflicts in our additions (Dockerfile.qwickapps, .github/, etc.)
# Update PINNED TAG and PINNED DIGEST below when a new version is available.
```

To look up the digest for a new tag:
```bash
docker manifest inspect ghcr.io/korotovsky/slack-mcp-server:<new-tag> \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('config',{}).get('digest',''))"
# or via gh API:
gh api /users/korotovsky/packages/container/slack-mcp-server/versions \
  | python3 -c "import json,sys; [print(v['metadata']['container']['tags'], v['name']) for v in json.load(sys.stdin)[:5]]"
```

## Deviation log

Track every file we modify relative to upstream here. This table is the
authoritative record of divergence for future sync reviewers.

| Date | File | Change | Reason |
|---|---|---|---|
| 2026-04-29 | `Dockerfile.qwickapps` | Added (new file) | QwickApps deployment wrapper image |
| 2026-04-29 | `entrypoint.qwickapps.sh` | Added (new file) | Canonical Tailscale entrypoint v1.2 |
| 2026-04-29 | `.github/` | Added (new directory) | CI/CD pipeline (CapRover blue-green deploy) |
| 2026-04-29 | `package.json` | Added (new file) | Version extraction shim for deploy-app.yml reusable workflow |
| 2026-04-29 | `NOTICE` | Added (new file) | Attribution and license boundary |
| 2026-04-29 | `UPSTREAM.md` | Added (new file) | This file |
