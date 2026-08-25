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
# The pre-demo state is an issue the pipeline filed on its own, *without* the
# cluster-doctor label. GitHub does not start a workflow from an event raised
# with GITHUB_TOKEN, so the label the handler applies at creation time never
# triggers the agent. Applying it by hand on stage is what starts the run, and
# staging the issue without it keeps that a single click.
ISSUE=$(gh issue list -R "$REPO" --state open --label argocd-deployment-failure \
        --json number --jq '.[0].number' 2>/dev/null)
if [ -n "$ISSUE" ] && [ "$ISSUE" != "null" ]; then
  pass "open failure issue: #$ISSUE"
  # gh prints an empty string for a null --jq result, so test a boolean the
  # filter always emits rather than comparing against the literal "null".
  HAS_LABEL=$(gh issue view "$ISSUE" -R "$REPO" --json labels \
              --jq '[.labels[].name] | any(. == "cluster-doctor")' 2>/dev/null)
  if [ "$HAS_LABEL" = "false" ]; then
    pass "cluster-doctor label is not applied yet (apply it on stage)"
  else
    fail "issue #$ISSUE already carries the cluster-doctor label — remove it so the on-stage click is a single action"
  fi
  COMMENTS=$(gh issue view "$ISSUE" -R "$REPO" --json comments --jq '.comments | length' 2>/dev/null)
  if [ "${COMMENTS:-0}" -eq 0 ]; then
    pass "issue has no stray comments"
  else
    warn "issue #$ISSUE has ${COMMENTS} comment(s) from earlier notifications — run ./Act-3/demo-morning.sh to regenerate it"
  fi
else
  fail "no open argocd-deployment-failure issue — run ./Act-3/demo-morning.sh"
fi

PR=$(gh pr list -R "$REPO" --state open --json number --jq 'length' 2>/dev/null)
if [ "${PR:-0}" -eq 0 ]; then
  pass "no open pull requests (the agent opens one live)"
else
  fail "${PR} pull request(s) still open — close them before presenting"
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
