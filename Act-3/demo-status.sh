#!/usr/bin/env bash
# Pre-presentation checklist for the Act-3 demo.
# Mirrors section 10 of the study guide: run it right before going on stage.

set -uo pipefail

REPO="aperezv01/agentic-platform-engineering"
APP="2-broken-apps"
CONTEXT="aks-ape-demo"
RG="rg-ape-demo"
CLUSTER="aks-ape-demo"

pass() { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m  ✗\033[0m %s\n' "$*"; FAILURES=$((FAILURES+1)); }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*"; }
head_() { printf '\n\033[1;36m%s\033[0m\n' "$*"; }

FAILURES=0

head_ "Cluster"
POWER=$(az aks show -g "$RG" -n "$CLUSTER" --query powerState.code -o tsv 2>/dev/null)
if [ "$POWER" = "Running" ]; then
  pass "AKS $CLUSTER is running"
else
  fail "AKS $CLUSTER is '${POWER:-unreachable}' — start it with: az aks start -g $RG -n $CLUSTER"
fi

NODES=$(kubectl --context "$CONTEXT" get nodes --no-headers 2>/dev/null | grep -c " Ready ")
if [ "${NODES:-0}" -gt 0 ]; then
  pass "$NODES node(s) Ready"
else
  fail "no Ready nodes"
fi

head_ "ArgoCD"
HEALTH=$(kubectl --context "$CONTEXT" get app "$APP" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null)
SYNC=$(kubectl --context "$CONTEXT" get app "$APP" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null)
if [ "$HEALTH" = "Degraded" ]; then
  pass "app $APP is Degraded (expected pre-demo state)"
else
  fail "app $APP is '${HEALTH:-unknown}' — expected Degraded. Run ./Act-3/demo-reset.sh"
fi
[ "$SYNC" = "Synced" ] && pass "sync status: Synced" || warn "sync status: ${SYNC:-unknown}"

BROKEN=$(kubectl --context "$CONTEXT" get pods -n default -l app=order-service \
         -o jsonpath='{range .items[*]}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null \
         | grep -c "ImagePullBackOff\|ErrImagePull")
if [ "${BROKEN:-0}" -gt 0 ]; then
  pass "order-service pod in ImagePullBackOff"
else
  fail "no order-service pod is failing to pull its image"
fi

RESTARTS=$(kubectl --context "$CONTEXT" get pod mongodb-0 -n default \
           -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)
if [ "${RESTARTS:-0}" -le 2 ]; then
  pass "mongodb stable (${RESTARTS:-0} restarts)"
else
  warn "mongodb has ${RESTARTS} restarts — it may emit spurious Degraded notifications"
fi

head_ "GitHub"
ISSUE=$(gh issue list -R "$REPO" --state open --label cluster-doctor --json number --jq '.[0].number' 2>/dev/null)
if [ -n "$ISSUE" ] && [ "$ISSUE" != "null" ]; then
  pass "open cluster-doctor issue: #$ISSUE"
else
  fail "no open issue with the cluster-doctor label"
fi

PR=$(gh pr list -R "$REPO" --state open --json number,headRefName \
     --jq '[.[] | select(.headRefName | startswith("fix/cluster-doctor"))][0].number' 2>/dev/null)
if [ -n "$PR" ] && [ "$PR" != "null" ]; then
  MERGEABLE=$(gh pr view "$PR" -R "$REPO" --json mergeable --jq '.mergeable' 2>/dev/null)
  pass "open agent PR: #$PR (mergeable: ${MERGEABLE:-unknown})"
else
  fail "no open cluster-doctor PR"
fi

head_ "Argo CD UI"
if nc -z localhost 8080 >/dev/null 2>&1; then
  pass "localhost:8080 is listening"
else
  warn "port-forward is down — run: kubectl port-forward svc/argocd-server -n argocd 8080:443"
fi

PW=$(kubectl --context "$CONTEXT" -n argocd get secret argocd-initial-admin-secret \
     -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null)
[ -n "$PW" ] && pass "argo login: admin / $PW" || warn "initial admin secret not found (password may have been rotated)"

head_ "Result"
if [ "$FAILURES" -eq 0 ]; then
  printf '\033[1;32mReady to present.\033[0m\n\n'
else
  printf '\033[1;31m%s check(s) failed — fix before going on stage.\033[0m\n\n' "$FAILURES"
  exit 1
fi
