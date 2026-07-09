#!/usr/bin/env bash
# run-round.sh — one round of cross-device P2P send scenarios with fg/bg permutations.
# Drives every ordered device pair, verifies receipt + end-to-end ack, measures latency,
# snapshots per-device node state, and emits one JSON line per scenario to results/<round>.jsonl.
#
# Usage: run-round.sh <round-id> <results-dir> [profile] [pairs]
#   profile : fgfg(default)|fgbg|bgfg|bgbg|cycle   -> sender_state/receiver_state
#             "cycle" rotates through all four perms across the pair list.
#   pairs   : optional "from:to from:to ..." override; default = all ordered pairs of core ids.
#
# Honest reporting: a scenario is delivered=true ONLY when the receiver shows the marker OR the
# sender holds an end-to-end delivery ack. Timeouts are recorded as delivered=false with elapsed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"

ROUND="${1:?round-id}"; RESULTS="${2:?results-dir}"; PROFILE="${3:-fgfg}"; PAIRS_IN="${4:-}"
mkdir -p "$RESULTS"
OUT="$RESULTS/$ROUND.jsonl"; : > "$OUT"
MAXWAIT="${TK_MAXWAIT:-60}"     # seconds to wait for delivery before recording a timeout
POLL="${TK_POLL:-2}"

CORE_IDS=(pixel tab xr jpad)
# Build the ordered-pair list unless overridden.
PAIRS=()
if [ -n "$PAIRS_IN" ]; then
  for p in $PAIRS_IN; do PAIRS+=("$p"); done
else
  for a in "${CORE_IDS[@]}"; do for b in "${CORE_IDS[@]}"; do
    [ "$a" != "$b" ] && PAIRS+=("$a:$b")
  done; done
fi

# fg/bg state selection
perm_for() {  # perm_for <index> -> "fromState toState"
  case "$PROFILE" in
    fgfg) echo "fg fg";; fgbg) echo "fg bg";; bgfg) echo "bg fg";; bgbg) echo "bg bg";;
    cycle) case $(( $1 % 4 )) in 0) echo "fg fg";; 1) echo "fg bg";; 2) echo "bg fg";; 3) echo "bg bg";; esac;;
    *) echo "fg fg";;
  esac
}

now_s() { date +%s; }
i=0
for pair in "${PAIRS[@]}"; do
  from="${pair%%:*}"; to="${pair##*:}"
  eval "toaddr=\"\${ADDR_$to:-}\""
  read fs ts <<< "$(perm_for $i)"; i=$((i+1))
  if [ -z "$toaddr" ]; then
    printf '{"round":"%s","from":"%s","to":"%s","skip":"no-addr"}\n' "$ROUND" "$from" "$to" >> "$OUT"
    continue
  fi
  mark="r${ROUND}_${from}2${to}_${fs}${ts}_$(now_s)"
  # set receiver state first (so it's in the target state when the message arrives), then sender fg to send
  if [ "$ts" = bg ]; then tk_bg "$to"; else tk_fg "$to"; fi
  sleep 1
  tk_fg "$from"   # sender must be foreground to issue the send (Android am / iOS launch)
  sleep 1
  t0=$(now_s)
  tk_send "$from" "$toaddr" "$mark"
  # If the SENDER is meant to be backgrounded, push it down right after issuing the send.
  if [ "$fs" = bg ]; then sleep 2; tk_bg "$from"; fi
  # Poll for delivery.
  delivered=false; received=0; elapsed=0
  while [ $elapsed -lt $MAXWAIT ]; do
    sleep "$POLL"; elapsed=$(( $(now_s) - t0 ))
    received=$(tk_verify "$to" "$mark" 2>/dev/null || echo 0)
    ack=$(tk_delivered "$from" "$mark" 2>/dev/null || echo false)
    if [ "${received:-0}" -gt 0 ] 2>/dev/null || [ "$ack" = true ]; then delivered=true; break; fi
  done
  fns=$(tk_nodestate "$from" 2>/dev/null | sed -E 's/.*NODESTATE //; s/"//g' | tr -s ' ')
  tns=$(tk_nodestate "$to" 2>/dev/null | sed -E 's/.*NODESTATE //; s/"//g' | tr -s ' ')
  printf '{"round":"%s","from":"%s","to":"%s","fromState":"%s","toState":"%s","marker":"%s","delivered":%s,"received":%s,"ackOnSender":"%s","latencyS":%s,"fromNode":"%s","toNode":"%s"}\n' \
    "$ROUND" "$from" "$to" "$fs" "$ts" "$mark" "$delivered" "${received:-0}" "$ack" "$elapsed" "$fns" "$tns" >> "$OUT"
  echo "[$ROUND] $from->$to ($fs/$ts): delivered=$delivered in ${elapsed}s (rx=$received ack=$ack)"
done

# Per-device log snapshot for this round's bug hunt — only the devices actually under test this
# round (derived from PAIRS, not the full CORE_IDS). A disconnected fleet member (e.g. an offline
# tab still half-known to adb) makes `adb -s <serial> logcat` BLOCK forever, so touching it here
# would hang the whole round; scoping to PAIRS keeps the snapshot to reachable devices.
declare -A _snap_ids
for pair in "${PAIRS[@]}"; do _snap_ids["${pair%%:*}"]=1; _snap_ids["${pair##*:}"]=1; done
for id in "${!_snap_ids[@]}"; do
  tk_logcap "$id" "$RESULTS/$ROUND.$id.log" 2>/dev/null
done
echo "round $ROUND done -> $OUT"
