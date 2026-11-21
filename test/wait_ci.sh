#!/bin/bash
# wait_ci.sh — poll GitHub Actions until a run finishes, then report jobs.
# Usage: wait_ci.sh <repo> [max_seconds]
T="$1"; MAX="${2:-3000}"
: "${GH_TOKEN_RT:?}"
START=$(date +%s)
LAST=""
while :; do
    NOW=$(date +%s); EL=$((NOW-START))
    [ "$EL" -ge "$MAX" ] && { echo "TIMEOUT after ${EL}s"; exit 4; }
    RID=$(curl -s -H "Authorization: token $GH_TOKEN_RT" \
        "https://api.github.com/repos/$T/actions/runs?per_page=1" \
        | python3 -c "import sys,json;print(json.load(sys.stdin)['workflow_runs'][0]['id'])" 2>/dev/null)
    [ -z "$RID" ] && { sleep 15; continue; }
    OUT=$(curl -s -H "Authorization: token $GH_TOKEN_RT" \
        "https://api.github.com/repos/$T/actions/runs/$RID/jobs" \
        | python3 -c "
import sys,json
d=json.load(sys.stdin)
for j in d['jobs']:
    print('JOB|%s|%s|%s|%s' % (j['id'], j['name'], j['status'], j['conclusion']))
    for s in j['steps']:
        if s['status']!='completed' or s['conclusion'] not in ('success',None):
            print('STEP|%s|%s|%s|%s' % (j['id'], s['number'], s['name'], s['conclusion']))
" 2>/dev/null)
    CUR=$(echo "$OUT" | md5sum | cut -d' ' -f1)
    [ "$CUR" != "$LAST" ] && { echo "--- ${EL}s ---"; echo "$OUT"; LAST="$CUR"; }
    if ! echo "$OUT" | grep -q '|in_progress|' && ! echo "$OUT" | grep -q '|queued|' \
       && ! echo "$OUT" | grep -q '|pending|'; then
        echo "=== FINISHED after ${EL}s ==="
        echo "$OUT"
        exit 0
    fi
    sleep 25
done
