#!/usr/bin/env bash
# morning-digest data gatherer.
# Deterministic, read-only collection of everything a status digest needs:
#   1. git commits per active repo over a window
#   2. open PRs per repo (state / mergeable / auto-merge / review)
#   3. scheduled-routine runs over the window (count + each run's last words)
#
# Usage: gather.sh [HOURS]   (default 24)
# Read-only. No writes, no network mutations. Safe to run anytime, any agent.
# Every external call is guarded with `|| true` so one failure never aborts the rest.

set -u
HOURS="${1:-24}"
WS="/Users/tomtang/code/edgevector"
PROJ="/Users/tomtang/.claude/projects/-Users-tomtang-code-edgevector"
REPOS=(fold schema-infra exemem-infra fold_dev_node fkanban)

echo "################################################################"
echo "# MORNING DIGEST — raw data (window: last ${HOURS}h)"
echo "# generated: $(date '+%Y-%m-%d %H:%M %Z')"
echo "################################################################"

echo
echo "==================== 1. COMMITS (last ${HOURS}h) ===================="
for d in "${REPOS[@]}"; do
  [ -d "$WS/$d/.git" ] || continue
  n=$(git -C "$WS/$d" log --since="${HOURS} hours ago" --oneline 2>/dev/null | wc -l | tr -d ' ')
  [ "${n:-0}" = "0" ] && continue
  echo "--- $d ($n commits) ---"
  git -C "$WS/$d" log --since="${HOURS} hours ago" --pretty=format:"%h %s" 2>/dev/null || true
  echo
done

echo
echo "==================== 2. OPEN PRs ===================="
for d in "${REPOS[@]}"; do
  slug=$(git -C "$WS/$d" remote get-url origin 2>/dev/null | sed -E 's#.*[:/]([^/]+/[^/]+)$#\1#' | sed 's/\.git$//')
  [ -z "${slug:-}" ] && continue
  echo "--- $slug ---"
  gh pr list --repo "$slug" --state open --limit 50 \
     --json number,title,isDraft,mergeable,autoMergeRequest,reviewDecision,updatedAt 2>/dev/null \
   | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except: d=[]
if not d: print('  (none open)')
for p in d:
    am='auto' if p.get('autoMergeRequest') else 'NO-AUTO'
    rv=p.get('reviewDecision') or '-'
    dr='DRAFT ' if p.get('isDraft') else ''
    print(f\"  #{p['number']:>4} {dr}{p.get('mergeable','?'):<11} {am:<7} {rv:<16} {p['title'][:72]}\")
" 2>/dev/null || echo "  (gh unavailable)"
done

echo
echo "==================== 3. ROUTINE RUNS (last ${HOURS}h) ===================="
echo "# Each scheduled-task session in the window, with its FINAL assistant words"
echo "# (a crude 'what did this run conclude'). Grouped by routine name."
python3 - "$PROJ" "$HOURS" <<'PYEOF' || true
import sys, os, json, time, glob, re
proj, hours = sys.argv[1], float(sys.argv[2])
cutoff = time.time() - hours*3600
runs = {}  # name -> list of (age_h, last_text)
for f in glob.glob(os.path.join(proj, "*.jsonl")):
    try:
        if os.path.getmtime(f) < cutoff: continue
    except OSError: continue
    name=None; last_assistant=""
    try:
        with open(f, errors="ignore") as fh:
            for line in fh:
                if 'scheduled-task name=' in line and name is None:
                    m=re.search(r'scheduled-task name=\\?"([^"\\]+)', line)
                    if m: name=m.group(1)
                if '"role":"assistant"' in line or '"type":"assistant"' in line:
                    try:
                        d=json.loads(line)
                        c=d.get('message',{}).get('content', d.get('content',''))
                        if isinstance(c,list):
                            txt=' '.join(x.get('text','') for x in c if isinstance(x,dict) and x.get('type')=='text')
                        else:
                            txt=c if isinstance(c,str) else ''
                        if txt.strip(): last_assistant=txt.strip()
                    except Exception: pass
    except Exception: continue
    if name is None: continue
    age=(time.time()-os.path.getmtime(f))/3600
    runs.setdefault(name, []).append((age, last_assistant))
if not runs:
    print("  (no routine runs in window)")
for name in sorted(runs):
    lst=sorted(runs[name])
    print(f"--- {name}  ({len(lst)} run(s)) ---")
    for age, txt in lst:
        snip=re.sub(r'\s+',' ',txt)[:280]
        print(f"  [{age:4.1f}h ago] {snip if snip else '(no final text)'}")
PYEOF

echo
echo "==================== 4. HUMAN-PRESENT SESSIONS (last ${HOURS}h) ===================="
echo "# Non-routine sessions = things Tom asked for by hand (recurring-request signal)."
python3 - "$PROJ" "$HOURS" <<'PYEOF' || true
import sys, os, json, time, glob, re
proj, hours = sys.argv[1], float(sys.argv[2])
cutoff = time.time() - hours*3600
rows=[]
for f in glob.glob(os.path.join(proj, "*.jsonl")):
    try:
        if os.path.getmtime(f) < cutoff: continue
    except OSError: continue
    first=""
    try:
        with open(f, errors="ignore") as fh:
            for line in fh:
                if '"role":"user"' in line:
                    try:
                        d=json.loads(line)
                        c=d.get('message',{}).get('content','')
                        first=c if isinstance(c,str) else ' '.join(x.get('text','') for x in c if isinstance(x,dict))
                    except Exception: pass
                    break
    except Exception: continue
    if not first or 'scheduled-task name=' in first: continue
    age=(time.time()-os.path.getmtime(f))/3600
    rows.append((age, re.sub(r'\s+',' ',first)[:160]))
for age, t in sorted(rows):
    print(f"  [{age:4.1f}h ago] {t}")
if not rows: print("  (none)")
PYEOF

echo
echo "################################ END RAW DATA ################################"
