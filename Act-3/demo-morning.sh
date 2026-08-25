#!/usr/bin/env bash
# Morning-of preparation for the Act-3 demo.
#
# The demo cluster is powered off overnight, so the first thing that happens on
# the day of the talk is a cold start. That cold start is not neutral: every
# Argo CD pod is recreated, the application briefly loses its health status, and
# the notifications controller re-fires `on-health-degraded` because its dedupe
# annotation is keyed on the alert condition and gets cleared whenever the app
# leaves Degraded. The result is a stale issue carrying spurious "Deployment
# Failed Again" comments and a handful of extra workflow runs on the Actions tab
# that will be on the projector.
#
# This script takes the cluster from powered-off to the exact pre-demo state:
#
#   ./Act-3/demo-morning.sh          # start the cluster, then stage the demo
#   ./Act-3/demo-morning.sh --skip-start  # cluster already running
#
# On success the repository has one open issue (without the cluster-doctor
# label), no pull requests, and a single workflow run. The only remaining action
# is applying the label on stage.
#
# Requires: az (logged in), gh (authenticated), kubectl, git.

set -euo pipefail

REPO="aperezv01/agentic-platform-engineering"
APP="2-broken-apps"
CONTEXT="aks-ape-demo"
RG="rg-ape-demo"
CLUSTER="aks-ape-demo"
LABEL="cluster-doctor"

cd "$(dirname "$0")/.."

step() { printf '\n\033[1;36m▸ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m  ✗ %s\033[0m\n' "$*"; exit 1; }

SKIP_START=0
case "${1:-}" in
  --skip-start) SKIP_START=1 ;;
  "") ;;
  *) die "unknown argument: $1 (expected --skip-start)" ;;
esac

step "Checking prerequisites"
for tool in az gh kubectl git; do
  command -v "$tool" >/dev/null || die "missing dependency: $tool"
done
az account show >/dev/null 2>&1 || die "az is not logged in — run: az login"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated — run: gh auth login"
ok "az, gh, kubectl and git are ready"

# ---------------------------------------------------------------------------
# 1. Bring the cluster up
# ---------------------------------------------------------------------------

if [ "$SKIP_START" -eq 0 ]; then
  step "Starting the AKS cluster"
  POWER=$(az aks show -g "$RG" -n "$CLUSTER" --query powerState.code -o tsv 2>/dev/null || echo "")
  if [ "$POWER" = "Running" ]; then
    ok "cluster is already running"
  else
    warn "cluster is '${POWER:-unknown}' — starting it (this takes 5-10 minutes)"
    az aks start -g "$RG" -n "$CLUSTER" --only-show-errors >/dev/null \
      || die "az aks start failed"
    ok "cluster started"
  fi
else
  step "Skipping cluster start (--skip-start)"
fi

step "Waiting for nodes to become Ready"
READY=0
for _ in $(seq 1 60); do
  count=$(kubectl --context "$CONTEXT" get nodes --no-headers 2>/dev/null | grep -c " Ready " || true)
  if [ "${count:-0}" -gt 0 ]; then
    ok "$count node(s) Ready"
    READY=1
    break
  fi
  sleep 10
done
[ "$READY" -eq 1 ] || die "no nodes became Ready after 10 minutes"

step "Waiting for Argo CD to come back up"
# The notifications controller is the component this demo depends on: without it
# the Degraded event never reaches the webhook and no issue is ever filed.
if kubectl --context "$CONTEXT" wait --for=condition=Available \
     deploy/argocd-notifications-controller -n argocd --timeout=300s >/dev/null 2>&1; then
  ok "argocd-notifications-controller is available"
else
  die "argocd-notifications-controller did not become available"
fi
if kubectl --context "$CONTEXT" wait --for=condition=Available \
     deploy/argocd-repo-server -n argocd --timeout=300s >/dev/null 2>&1; then
  ok "argocd-repo-server is available"
else
  warn "argocd-repo-server is not reporting Available — sync may lag"
fi

step "Waiting for Argo CD to reconcile the application"
FOUND=0
for _ in $(seq 1 60); do
  health=$(kubectl --context "$CONTEXT" get app "$APP" -n argocd \
           -o jsonpath='{.status.health.status}' 2>/dev/null || echo "")
  case "$health" in
    Healthy|Degraded|Progressing)
      ok "app $APP is reporting status ($health)"
      FOUND=1
      break
      ;;
  esac
  sleep 5
done
[ "$FOUND" -eq 1 ] || die "app $APP never reported a health status"

# ---------------------------------------------------------------------------
# 2. Stage the demo
# ---------------------------------------------------------------------------

refresh() {
  kubectl --context "$CONTEXT" patch app "$APP" -n argocd --type merge \
    -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"normal"}}}' >/dev/null 2>&1 || true
}

wait_for_health() {
  local want="$1" tries="${2:-72}" health=""
  for _ in $(seq 1 "$tries"); do
    refresh
    health=$(kubectl --context "$CONTEXT" get app "$APP" -n argocd \
             -o jsonpath='{.status.health.status}' 2>/dev/null || echo "")
    if [ "$health" = "$want" ]; then
      ok "app is $want"
      return 0
    fi
    sleep 5
  done
  warn "app never reached $want (last status: ${health:-unknown})"
  return 1
}

step "Syncing the repository"
# --autostash keeps a dirty checkout from aborting the rebase. Presenters often
# have local edits on the morning of a talk, and `set -e` would turn that into a
# hard stop halfway through staging.
git pull -q --rebase --autostash origin main
ok "local checkout is up to date"

# The healing commit is pushed *before* any issue is closed, on purpose. Pushing
# a new revision while the app is still Degraded can make Argo re-fire the
# trigger, and the resulting issue would quote the healing commit as the failing
# revision — a SHA that contradicts the typo shown on stage. Leaving the old
# issue open means the handler's dedupe path turns that spurious notification
# into a comment on a doomed issue instead.
step "Restoring the correct image (keeping any open issue as a lightning rod)"
./Act-3/demo-reset.sh --heal || true

step "Waiting for the app to recover"
wait_for_health Healthy || warn "continuing anyway — the break below will still apply"

step "Closing leftover issues and pull requests"
prs=$(gh pr list -R "$REPO" --state open --json number --jq '.[].number' 2>/dev/null || true)
if [ -n "$prs" ]; then
  for pr in $prs; do
    if gh pr close "$pr" -R "$REPO" --delete-branch >/dev/null 2>&1; then
      ok "closed PR #$pr"
    else
      warn "could not close PR #$pr"
    fi
  done
else
  ok "no leftover pull requests"
fi

issues=$(gh issue list -R "$REPO" --state open --label argocd-deployment-failure \
         --json number --jq '.[].number' 2>/dev/null || true)
if [ -n "$issues" ]; then
  for i in $issues; do
    if gh issue close "$i" -R "$REPO" >/dev/null 2>&1; then
      ok "closed issue #$i"
    else
      warn "could not close issue #$i"
    fi
  done
else
  ok "no leftover issues"
fi

step "Re-introducing the order-service typo"
./Act-3/demo-reset.sh --break || true
BREAK_SHA=$(git rev-parse HEAD)
ok "typo committed as ${BREAK_SHA:0:7}"

step "Waiting for Argo CD to detect the failure"
wait_for_health Degraded || warn "app is not Degraded — the pipeline may not fire"

step "Waiting for the pipeline to file a fresh issue"
ISSUE=""
for _ in $(seq 1 48); do
  ISSUE=$(gh issue list -R "$REPO" --state open --label argocd-deployment-failure \
          --json number --jq '.[0].number' 2>/dev/null || echo "")
  if [ -n "$ISSUE" ] && [ "$ISSUE" != "null" ]; then
    ok "issue #$ISSUE created"
    break
  fi
  sleep 10
  ISSUE=""
done
[ -n "$ISSUE" ] || die "no issue appeared — check the argocd-notifications-controller logs"

step "Verifying the issue quotes the typo commit"
ISSUE_REV=$(gh issue view "$ISSUE" -R "$REPO" --json body --jq '.body' 2>/dev/null \
            | grep -oE '[0-9a-f]{40}' | head -1 || echo "")
if [ "$ISSUE_REV" = "$BREAK_SHA" ]; then
  ok "revision matches ${BREAK_SHA:0:7}"
else
  warn "issue quotes ${ISSUE_REV:0:7} but the typo is in ${BREAK_SHA:0:7}"
  warn "the demo still works, but do not put the issue body and the commit side by side"
fi

# GitHub suppresses workflow triggers for events raised with GITHUB_TOKEN, so
# the label the handler applies at creation time never starts the agent. It is
# removed here so that applying it on stage produces a genuine `labeled` event
# from a human actor — a single click rather than a remove-then-add fumble.
step "Removing the $LABEL label so the on-stage click is a clean single action"
if gh issue edit "$ISSUE" -R "$REPO" --remove-label "$LABEL" >/dev/null 2>&1; then
  ok "label removed from issue #$ISSUE"
else
  warn "could not remove the label — check it manually before presenting"
fi

step "Trimming the Actions tab to the run that filed the issue"
# argocd-deployment-failure.yml is only reachable through repository_dispatch, so
# it disappears from the workflow sidebar if it has no runs at all. Keep the most
# recent one.
KEEP=$(gh run list -R "$REPO" --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null || echo "")
DELETED=0
if [ -n "$KEEP" ] && [ "$KEEP" != "null" ]; then
  for id in $(gh run list -R "$REPO" --limit 100 --json databaseId --jq '.[].databaseId' 2>/dev/null); do
    if [ "$id" != "$KEEP" ]; then
      if gh api -X DELETE "repos/$REPO/actions/runs/$id" >/dev/null 2>&1; then
        DELETED=$((DELETED+1))
      fi
    fi
  done
  ok "kept run $KEEP, deleted $DELETED older run(s)"
else
  warn "no workflow runs found"
fi

# ---------------------------------------------------------------------------
# 3. Report
# ---------------------------------------------------------------------------

step "Final state"
HEALTH=$(kubectl --context "$CONTEXT" get app "$APP" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "?")
SYNC=$(kubectl --context "$CONTEXT" get app "$APP" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "?")
BROKEN=$(kubectl --context "$CONTEXT" get pods -n default -l app=order-service \
         -o jsonpath='{range .items[*]}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null \
         | grep -c "ImagePullBackOff\|ErrImagePull" || true)
LABELS=$(gh issue view "$ISSUE" -R "$REPO" --json labels --jq '[.labels[].name] | join(", ")' 2>/dev/null || echo "?")
COMMENTS=$(gh issue view "$ISSUE" -R "$REPO" --json comments --jq '.comments | length' 2>/dev/null || echo "?")
OPEN_PRS=$(gh pr list -R "$REPO" --state open --json number --jq 'length' 2>/dev/null || echo "?")
RUNS=$(gh run list -R "$REPO" --limit 100 --json databaseId --jq 'length' 2>/dev/null || echo "?")

printf '  app          : %s / %s\n' "$HEALTH" "$SYNC"
printf '  failing pod  : %s\n' "${BROKEN:-0}"
printf '  issue        : #%s (%s comment(s))\n' "$ISSUE" "$COMMENTS"
printf '  issue labels : %s\n' "$LABELS"
printf '  open PRs     : %s\n' "$OPEN_PRS"
printf '  workflow runs: %s\n' "$RUNS"
printf '  issue URL    : https://github.com/%s/issues/%s\n' "$REPO" "$ISSUE"

echo
if [ "$HEALTH" = "Degraded" ] && [ "${BROKEN:-0}" -gt 0 ] && [ "$OPEN_PRS" = "0" ]; then
  printf '\033[1;32mReady to present.\033[0m Open issue #%s and apply the "%s" label on stage.\n\n' "$ISSUE" "$LABEL"
else
  printf '\033[1;33mStaged with warnings.\033[0m Review the state above before going on stage.\n\n'
fi
