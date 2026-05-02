# .github/scripts — slack-mcp-server deploy support utilities

These scripts implement the blue-green deployment pipeline for the slack-mcp-server service. They are owned by this repository (qwickapps/slack) and cover the full deploy lifecycle: Docker image delivery to CapRover, health validation, traffic-light slot rotation, gateway route management, and dev environment cleanup.

## Scripts included

| Script | Purpose |
|--------|---------|
| `build-workspace-package.sh` | Builds monorepo workspace packages before Docker build (skipped in standalone repos when `workspace_packages` is empty) |
| `cleanup-dev-builds.sh` | Removes stale dev build slots from CapRover after a successful deploy |
| `configure-caprover-app.sh` | Creates/updates a CapRover app with env vars and port config |
| `deep-health-check.sh` | Parses structured JSON health response and validates each subsystem |
| `deploy-from-ghcr.sh` | Deploys a GHCR image to a CapRover app slot |
| `deploy-traffic-light.sh` | Orchestrates build → health-check → swap → gateway update (blue-green) |
| `resolve-docker-endpoint.sh` | Resolves the Docker socket endpoint for macmini self-hosted runners |
| `setup-qwickway-route.sh` | Provisions/updates a QwickWay gateway route |
| `swap-instances.sh` | Renames CapRover apps for the build→live→stable slot rotation |
| `validate-deployment-health.sh` | Polls the health endpoint until it returns HTTP 200 or times out |
| `lib/caprover-api.sh` | Shared CapRover API helpers (sourced by configure-caprover-app.sh and deploy-from-ghcr.sh) |
