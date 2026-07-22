#!/usr/bin/env bash
# morning-sync usage + bugs gatherer
# Prints a compact markdown block: a Sentry BUGS summary + a PostHog USAGE summary.
# Read-only. Safe to run unattended. Every external call is guarded so one failure
# never aborts the brief. Sentry works today; PostHog activates once a personal
# read key is stashed (see POSTHOG setup at the bottom of this file).
#
# Usage:  usage-bugs.sh            # both blocks
#         usage-bugs.sh sentry     # bugs only
#         usage-bugs.sh posthog    # usage only
set -u
export PATH="$HOME/.local/bin:$HOME/.bun/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
WHICH="${1:-all}"

py() { python3 "$@"; }

default_sentry_projects() {
  cat <<'EOF'
rust
javascript-react
javascript-react-xq
lastdb-mini
exemem-backend
agent-cli
routines
lastgit
remote
discovery
photos
EOF
}

sentry_projects_from_signal_sources() {
  local record
  record=""
  if command -v fbrain >/dev/null 2>&1; then
    record=$(fbrain get signal-sources --type reference 2>/dev/null || true)
  fi
  if [ -z "$record" ] && command -v brain >/dev/null 2>&1; then
    record=$(brain get signal-sources --type reference 2>/dev/null || true)
  fi
  if [ -z "$record" ]; then
    return 1
  fi

  SIGNAL_SOURCES_RECORD="$record" py - <<'PY'
import os, re, sys

record = os.environ.get("SIGNAL_SOURCES_RECORD", "")
match = re.search(r"^- \*\*scopes\*\*:\s*(.+)$", record, re.MULTILINE)
if not match:
    sys.exit(1)

raw_scopes = re.findall(r"`([^`]+)`", match.group(1))
if not raw_scopes:
    raw_scopes = [part.strip() for part in match.group(1).split(",")]

seen = set()
for scope in raw_scopes:
    scope = scope.strip().strip("`")
    if "/" not in scope:
        continue
    project = scope.rsplit("/", 1)[1].strip()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", project):
        continue
    if project in seen:
        continue
    seen.add(project)
    print(project)
PY
}

sentry_projects() {
  if sentry_projects_from_signal_sources; then
    return
  fi
  default_sentry_projects
}

sentry_next_link() {
  local headers="$1"
  SENTRY_HEADERS="$headers" py - <<'PY'
import os, re

headers_path = os.environ["SENTRY_HEADERS"]
try:
    text = open(headers_path, encoding="utf-8", errors="replace").read()
except OSError:
    raise SystemExit

for line in text.splitlines():
    if not line.lower().startswith("link:"):
        continue
    value = line.split(":", 1)[1].strip()
    for part in re.split(r",\s*(?=<)", value):
        match = re.match(r"<([^>]+)>\s*;(.*)$", part.strip())
        if not match:
            continue
        url, attrs_raw = match.groups()
        attrs = dict(
            (key, val)
            for key, val in re.findall(r';?\s*([A-Za-z_-]+)="([^"]*)"', attrs_raw)
        )
        if attrs.get("rel") == "next" and attrs.get("results", "true").lower() == "true":
            print(url)
            raise SystemExit
PY
}

sentry_project_issues_json() {
  local token="$1"
  local slug="$2"
  local url="https://sentry.io/api/0/projects/edge-vector/$slug/issues/?query=is:unresolved&statsPeriod=14d&limit=100"
  local page_limit="${SENTRY_PAGE_LIMIT:-20}"
  local tmp_dir page headers body next_url
  tmp_dir="$(mktemp -d)"
  page=0

  while [ -n "$url" ] && [ "$page" -lt "$page_limit" ]; do
    page=$((page + 1))
    headers="$tmp_dir/headers-$page"
    body="$tmp_dir/body-$page.json"
    if ! curl -sS --max-time 25 -D "$headers" -o "$body" \
      -H "Authorization: Bearer $token" \
      "$url" 2>/dev/null; then
      rm -rf "$tmp_dir"
      return 1
    fi
    next_url="$(sentry_next_link "$headers" || true)"
    [ "$next_url" = "$url" ] && next_url=""
    url="$next_url"
  done

  py - "$tmp_dir"/body-*.json <<'PY'
import json, sys

combined = []
for path in sys.argv[1:]:
    try:
        with open(path, encoding="utf-8") as handle:
            page = json.load(handle)
    except Exception as exc:
        print(json.dumps({"error": f"unparseable page {path}: {exc}"}))
        raise SystemExit(1)
    if not isinstance(page, list):
        print(json.dumps(page))
        raise SystemExit
    combined.extend(page)
print(json.dumps(combined))
PY
  local rc=$?
  rm -rf "$tmp_dir"
  return "$rc"
}

# ----------------------------------------------------------------------------
# 🐛 BUGS — Sentry (edge-vector org; fleet projects)
# ----------------------------------------------------------------------------
sentry_block() {
  echo "### 🐛 Bugs (Sentry · last 14d unresolved)"
  local TOKEN
  TOKEN=$(security find-generic-password -s "sentry-auth-token" -a "edge-vector" -w 2>/dev/null)
  if [ -z "${TOKEN:-}" ]; then
    TOKEN=$(awk -F'=' '/^token/{gsub(/ /,"",$2);print $2}' "$HOME/.sentryclirc" 2>/dev/null | head -1)
  fi
  if [ -z "${TOKEN:-}" ]; then
    echo "- ⚠️ Sentry token unavailable (keychain \`sentry-auth-token/edge-vector\` + ~/.sentryclirc both empty)."
    return
  fi
  local slug json
  local projects=()
  while IFS= read -r slug; do
    [ -n "$slug" ] && projects+=("$slug")
  done < <(sentry_projects)
  if [ "${#projects[@]}" -eq 0 ]; then
    echo "- ⚠️ No Sentry projects found in signal-sources or fallback list."
    return
  fi
  for slug in "${projects[@]}"; do
    json=$(sentry_project_issues_json "$TOKEN" "$slug" 2>/dev/null || true)
    SENTRY_SLUG="$slug" SENTRY_JSON="$json" py - <<'PY'
import os, json, datetime
slug = os.environ["SENTRY_SLUG"]
raw  = os.environ.get("SENTRY_JSON", "")
try:
    data = json.loads(raw)
except Exception:
    print(f"- **{slug}**: ⚠️ Sentry API error / unparseable response."); raise SystemExit
if not isinstance(data, list):
    print(f"- **{slug}**: ⚠️ Sentry API: {str(data)[:120]}"); raise SystemExit
now = datetime.datetime.now(datetime.timezone.utc)
def age_h(ts):
    try:
        return (now - datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))).total_seconds()/3600
    except Exception:
        return 9e9
errs   = [i for i in data if str(i.get("level")) in ("error", "fatal")]
new24  = [i for i in data if age_h(i.get("firstSeen", "")) < 24]
fire24 = [i for i in errs if age_h(i.get("lastSeen", "")) < 24]
users  = sum(int(i.get("userCount", 0) or 0) for i in data)
hd = f"- **{slug}**: {len(data)} unresolved ({len(errs)} error/fatal) · new<24h: {len(new24)} · firing<24h: {len(fire24)} · users affected: {users}"
print(hd)
# storms / actively-firing high-volume errors first, else top by volume
storms = sorted([i for i in fire24 if int(i.get("count", 0) or 0) >= 50 or int(i.get("userCount", 0) or 0) >= 1],
                key=lambda i: int(i.get("count", 0) or 0), reverse=True)[:3]
show = storms if storms else sorted(data, key=lambda i: int(i.get("count", 0) or 0), reverse=True)[:2]
tag = "🔴 " if storms else ""
for i in show:
    title = (i.get("title", "") or "")[:72].replace("\n", " ")
    print(f"    {tag}{title} · count={i.get('count')} users={i.get('userCount')}  {i.get('permalink','')}")
PY
  done
}

# ----------------------------------------------------------------------------
# 📈 USAGE — PostHog (activates when a personal read key is stashed)
# ----------------------------------------------------------------------------
posthog_block() {
  echo "### 📈 Usage (PostHog)"
  local KEY HOST PROJ
  KEY="${POSTHOG_PERSONAL_KEY:-}"
  [ -z "$KEY" ] && KEY=$(security find-generic-password -s "posthog-personal-key" -a "edge-vector" -w 2>/dev/null)
  HOST="${POSTHOG_HOST:-https://us.posthog.com}"
  PROJ="${POSTHOG_PROJECT_ID:-}"
  if [ -z "${KEY:-}" ]; then
    echo "- ⚠️ Not configured. Stash a PostHog **personal read key** to enable:"
    echo "    \`security add-generic-password -U -s posthog-personal-key -a edge-vector -w '<phx_…>'\`"
    echo "    (optionally set POSTHOG_HOST=https://eu.posthog.com / POSTHOG_PROJECT_ID). The last personal key was revoked after a leak — mint a fresh read-scoped one in PostHog → Settings → Personal API keys."
    return
  fi
  # Auto-discover the first project if none pinned.
  if [ -z "$PROJ" ]; then
    PROJ=$(curl -s --max-time 20 -H "Authorization: Bearer $KEY" "$HOST/api/projects/" 2>/dev/null \
      | py -c 'import sys,json;
try:
 d=json.load(sys.stdin); r=d.get("results",d) if isinstance(d,dict) else d
 print(r[0]["id"])
except Exception: print("")' 2>/dev/null)
  fi
  if [ -z "$PROJ" ]; then
    echo "- ⚠️ Key present but project discovery failed (check key scope / POSTHOG_HOST region)."
    return
  fi
  # HogQL: events + distinct users over 1d / 7d, and signups (1d) if a $signup-ish event exists.
  local q='SELECT
      countIf(timestamp > now() - INTERVAL 1 DAY) AS events_1d,
      countIf(timestamp > now() - INTERVAL 7 DAY) AS events_7d,
      count(DISTINCT if(timestamp > now() - INTERVAL 1 DAY, person_id, NULL)) AS dau,
      count(DISTINCT if(timestamp > now() - INTERVAL 7 DAY, person_id, NULL)) AS wau
    FROM events'
  local resp
  resp=$(curl -s --max-time 30 -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
    -X POST "$HOST/api/projects/$PROJ/query/" \
    -d "$(py -c 'import json,sys; print(json.dumps({"query":{"kind":"HogQLQuery","query":sys.argv[1]}}))' "$q")" 2>/dev/null)
  PH_RESP="$resp" PH_HOST="$HOST" PH_PROJ="$PROJ" py - <<'PY'
import os, json
raw = os.environ.get("PH_RESP", "")
try:
    d = json.loads(raw)
    row = d["results"][0]
    e1, e7, dau, wau = row[0], row[1], row[2], row[3]
    print(f"- Project {os.environ['PH_PROJ']} · **DAU {dau}** / WAU {wau} · events 24h: {e1} / 7d: {e7}")
    print(f"    {os.environ['PH_HOST']}")
except Exception:
    msg = (raw or "")[:160].replace("\n", " ")
    print(f"- ⚠️ PostHog query failed: {msg or 'empty response'}")
PY
}

case "$WHICH" in
  sentry)  sentry_block ;;
  posthog) posthog_block ;;
  *)       sentry_block; echo; posthog_block ;;
esac
