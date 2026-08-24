#!/usr/bin/env bash
# Reset the Act-3 demo to its "broken" starting state.
#
# Seeds the order-service image typo, clears the artifacts left over from the
# previous run, and waits for the pipeline to produce a fresh issue and PR.
#
#   ./Act-3/demo-reset.sh          # full reset, waits for issue + PR
#   ./Act-3/demo-reset.sh --break  # only seed the typo and push
#   ./Act-3/demo-reset.sh --heal   # restore the fix (post-demo cleanup)
#
# Requires: gh (authenticated), kubectl pointed at the demo cluster, git.

set -euo pipefail

REPO="aperezv01/agentic-platform-engineering"
APP="2-broken-apps"
MANIFEST="Act-3/argocd/apps/broken-aks-store-all-in-one.yaml"
GOOD="ghcr.io/azure-samples/aks-store-demo/order-service:2.1.0"
BAD="ghcr.io/azure-samples/aks-store-demo/order-servie:2.1.0"
CONTEXT="aks-ape-demo"

cd "$(dirname "$0")/.."

log()  { printf '\033[1;36m▸\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }

require() {
  command -v "$1" >/dev/null || { echo "missing dependency: $1" >&2; exit 1; }
}
require gh
require kubectl
require git

# Rewrites the image reference and pushes. Argo's selfHeal picks it up from git,
# so the cluster state always follows the repo rather than a manual kubectl edit.
set_image() {
  local from="$1" to="$2" subject="$3"
  if ! grep -q "$from" "$MANIFEST"; then
    warn "manifest already at target state, skipping commit"
    return 1
  fi
  # BSD sed (macOS) needs the empty-string argument to -i.
  sed -i '' "s|${from}|${to}|g" "$MANIFEST"
  git add "$MANIFEST"
  git commit -q -m "$subject"
  git push -q origin main
  ok "pushed: $subject"
  return 0
}

# Argo polls git every ~3 minutes; this annotation forces an immediate
# comparison so the script does not wait out the polling interval.
refresh() {
  kubectl --context "$CONTEXT" patch app "$APP" -n argocd --type merge \
    -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"normal"}}}' >/dev/null 2>&1 || true
}

wait_for_health() {
  local want="$1" label="$2" tries="${3:-60}" health
  log "waiting for ArgoCD to report $want ($label)"
  for _ in $(seq 1 "$tries"); do
    refresh
    health=$(kubectl --context "$CONTEXT" get app "$APP" -n argocd \
             -o jsonpath='{.status.health.status}' 2>/dev/null || echo "")
    [ "$health" = "$want" ] && { ok "app is $want"; return 0; }
    sleep 5
  done
  warn "app never reached $want (last status: ${health:-unknown})"
  return 1
}

heal() {
  log "restoring the correct image reference"
  set_image "$BAD" "$GOOD" "demo: restore order-service image after rehearsal" || true
}

close_leftovers() {
  log "closing open cluster-doctor pull requests"
  local prs
  prs=$(gh pr list -R "$REPO" --state open --json number,headRefName \
        --jq '.[] | select(.headRefName | startswith("fix/cluster-doctor")) | .number')
  for pr in $prs; do
    gh pr close "$pr" -R "$REPO" --delete-branch >/dev/null 2>&1 \
      && ok "closed PR #$pr" || warn "could not close PR #$pr"
  done
  [ -z "$prs" ] && ok "no leftover PRs"

  log "closing open ArgoCD failure issues"
  local issues
  issues=$(gh issue list -R "$REPO" --state open --label argocd-deployment-failure \
           --json number --jq '.[].number')
  for i in $issues; do
    gh issue close "$i" -R "$REPO" >/dev/null 2>&1 \
      && ok "closed issue #$i" || warn "could not close issue #$i"
  done
  [ -z "$issues" ] && ok "no leftover issues"
}

wait_for_issue() {
  log "waiting for the agent pipeline to open a fresh issue (up to 3 min)"
  local num
  for _ in $(seq 1 36); do
    num=$(gh issue list -R "$REPO" --state open --label cluster-doctor \
          --json number --jq '.[0].number' 2>/dev/null || echo "")
    [ -n "$num" ] && [ "$num" != "null" ] && { ok "issue #$num created"; return 0; }
    sleep 5
  done
  warn "no issue appeared — check the argocd-notifications-controller logs"
  return 1
}

wait_for_pr() {
  log "waiting for the cluster-doctor PR (up to 8 min)"
  local num
  for _ in $(seq 1 96); do
    num=$(gh pr list -R "$REPO" --state open --json number,headRefName \
          --jq '[.[] | select(.headRefName | startswith("fix/cluster-doctor"))][0].number' 2>/dev/null || echo "")
    [ -n "$num" ] && [ "$num" != "null" ] && { ok "PR #$num opened"; return 0; }
    sleep 5
  done
  warn "no PR appeared — check the Trigger Cluster Doctor workflow run"
  return 1
}

case "${1:-}" in
  --heal)
    heal
    ;;
  --break)
    git pull -q --rebase origin main
    set_image "$GOOD" "$BAD" "demo: re-introduce order-service typo for keynote rehearsal" || true
    ;;
  *)
    git pull -q --rebase origin main
    # The notifications controller dedupes on an annotation keyed by the alert
    # condition, so an app that is already Degraded will not fire again. Drive
    # it back to Healthy and wait for Argo to observe that before re-breaking,
    # otherwise the reset silently produces no issue.
    heal
    wait_for_health Healthy "clearing the previous alert" || true
    close_leftovers
    set_image "$GOOD" "$BAD" "demo: re-introduce order-service typo for keynote rehearsal" || true
    wait_for_health Degraded "seeded failure detected" || true
    wait_for_issue || true
    wait_for_pr || true
    echo
    ok "demo reset complete — verify with ./Act-3/demo-status.sh"
    ;;
esac
