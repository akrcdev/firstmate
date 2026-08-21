#!/usr/bin/env bash
# Opt-in credentialed Pi continuity regressions in isolated project/home state.
# FM_PI_HEADLESS_REARM_E2E covers the empty-recovery notification boundary on
# any host with Pi and auth. FM_PI_LIVE_E2E additionally covers the interactive
# private-tmux lifecycle. Neither copies credentials.
set -u

if [ "${FM_PI_LIVE_E2E:-0}" != 1 ] && [ "${FM_PI_HEADLESS_REARM_E2E:-0}" != 1 ]; then
  echo "skip: set FM_PI_HEADLESS_REARM_E2E=1 for the headless Pi re-arm regression or FM_PI_LIVE_E2E=1 for the full interactive regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unset NO_MISTAKES_GATE

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v pi >/dev/null 2>&1 || fail "pi not found"
PI_VERSION=$(pi --version)

run_headless_empty_rearm() {
  local lab home fakebin project out err rc agent_starts tool_calls assistant_ends failure='' i pid
  lab="$ROOT/.pi-headless-rearm-e2e.$$"
  home="$lab/home"
  fakebin="$lab/fakebin"
  project="$lab/project"
  out="$lab/out.jsonl"
  err="$lab/err"
  mkdir -p "$home/state" "$home/config" "$fakebin" "$project/.pi"
  printf '%s\n' '{"transport":"sse"}' > "$project/.pi/settings.json"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf 'pending:downtime:live-empty-proof\n' > "$home/state/.watcher-down"
  chmod 600 "$home/state/.watcher-down"

  (
    cd "$project" || exit 1
    printf '%s\n' "$$" > "$home/state/.lock"
    exec env PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      FM_STATE_OVERRIDE="$home/state" FM_POLL=1 FM_SIGNAL_GRACE=0 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 PI_SKIP_VERSION_CHECK=1 \
      pi --mode json --approve --no-session --no-context-files --no-extensions \
        -e "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" \
        --no-builtin-tools --tools fm_watch_arm_pi \
        --model openai-codex/gpt-5.6-sol --thinking low \
        'Call fm_watch_arm_pi exactly once. After the tool returns, reply exactly EMPTY_ARM_COMPLETE. Do not call any other tool.'
  ) > "$out" 2> "$err"
  rc=$?
  agent_starts=$(grep -c '"type":"agent_start"' "$out" || true)
  tool_calls=$(grep -c '"type":"tool_execution_start".*"toolName":"fm_watch_arm_pi"' "$out" || true)
  assistant_ends=$(grep -c '"type":"message_end","message":{"role":"assistant","content":\[{"type":"text","text":"EMPTY_ARM_COMPLETE"' "$out" || true)
  [ "$rc" -eq 0 ] || failure="Pi exited $rc: $(cat "$err")"
  [ "$agent_starts" -eq 1 ] || failure="empty recovery triggered $agent_starts agent runs"
  [ "$tool_calls" -eq 1 ] || failure="headless model made $tool_calls watcher tool calls"
  [ "$assistant_ends" -eq 1 ] || failure="headless model produced $assistant_ends exact completion messages"
  grep -Fq 'rearm-resurface' "$out" && failure="empty recovery emitted rearm-resurface"
  i=0
  while [ "$i" -lt 50 ] && [ -e "$home/state/.watch.lock" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if [ -e "$home/state/.watch.lock" ]; then
    pid=$(cat "$home/state/.watch.lock/pid" 2>/dev/null || true)
    case "$pid" in ''|*[!0-9]*) ;; *) kill -TERM "$pid" 2>/dev/null || true ;; esac
    failure="headless Pi exit left its watcher child alive"
  fi
  rm -rf "$lab"
  [ -z "$failure" ] || fail "$failure"
  printf 'ok - Pi %s headless empty recovery: agent_starts=%s tool_calls=%s rearm_followups=0\n' \
    "$PI_VERSION" "$agent_starts" "$tool_calls"
}

run_headless_empty_rearm
[ "${FM_PI_LIVE_E2E:-0}" = 1 ] || exit 0
command -v tmux >/dev/null 2>&1 || fail "tmux not found for the full interactive Pi regression"

TMUX=$(command -v tmux)
SOCKET="fm-pi-live-e2e-$$"
SESSION=pi-live-e2e
LAB="$ROOT/.pi-live-e2e.$$"
PROJECT="$LAB/project"
AHOY_PROJECT="$LAB/ahoy-project"
HOME_DIR="$LAB/fmhome"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-operational-input.sh"
# shellcheck disable=SC2016 # Backticks are literal prompt markup.
LEGACY_START='Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.'
LEGACY_AWAY=$'\xE2\x81\xA3Supervisor escalate (1 event(s)): done: legacy rollout'
MARKER_NEAR_MISS=$'\xE2\x81\xA3Captain note: this invisible separator is intentional.'
# shellcheck disable=SC2016 # Backticks are literal prompt markup.
START_NEAR_MISS='Captain quote: Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.'
fm_operational_input_encode watcher "CURRENT_AHOY_WATCHER_BODY" CURRENT_WATCHER \
  || fail "could not construct current Ahoy watcher fixture"
QUOTED_CURRENT="Captain quote: $CURRENT_WATCHER"
ASCII_ONLY='FIRSTMATE_OP: v1 watcher: captain-authored text'

capture() {
  "$TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION" -S -600 2>/dev/null || true
}

wait_for_text() {
  local expected=$1 attempts=${2:-120} i=0
  while [ "$i" -lt "$attempts" ]; do
    if capture | grep -Fq "$expected"; then
      return 0
    fi
    sleep 0.5
    i=$((i + 1))
  done
  capture >&2
  return 1
}

wait_for_exact_line() {
  local expected=$1 attempts=${2:-120} i=0
  while [ "$i" -lt "$attempts" ]; do
    if capture | grep -Fxq " $expected"; then
      return 0
    fi
    sleep 0.5
    i=$((i + 1))
  done
  capture >&2
  return 1
}

lab_pid_is_safe() {
  local pid=$1 command
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$command" in
    *"$LAB"*) return 0 ;;
    *) return 1 ;;
  esac
}

cleanup() {
  local pid_file watcher_pid arm_pid
  pid_file=$(find "$HOME_DIR/state" -maxdepth 3 -type f -name pid 2>/dev/null | head -1 || true)
  watcher_pid=
  arm_pid=
  if [ -n "$pid_file" ]; then
    watcher_pid=$(sed -n '1p' "$pid_file" 2>/dev/null || true)
    arm_pid=$(ps -p "$watcher_pid" -o ppid= 2>/dev/null | tr -d ' ' || true)
  fi
  "$TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  sleep 0.1
  if [ -n "$watcher_pid" ] && lab_pid_is_safe "$watcher_pid"; then
    kill -TERM "$watcher_pid" 2>/dev/null || true
  fi
  if [ -n "$arm_pid" ] && lab_pid_is_safe "$arm_pid"; then
    kill -TERM "$arm_pid" 2>/dev/null || true
  fi
  rm -rf "$LAB"
}
trap cleanup EXIT

send_prompt() {
  local prompt=$1
  "$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l "$prompt"
  "$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
}

wait_pid_dead() {
  local pid=$1 i=0
  while [ "$i" -lt 50 ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

run_ahoy_case() {
  local label=$1 preceding=$2 expected=$3 out status=0
  out=$(
    cd "$PROJECT" &&
      pi --print --approve --no-session --no-context-files --no-extensions \
        --no-skills --skill .agents/skills --tools read \
        --model openai-codex/gpt-5.6-sol --thinking low \
        "$preceding" "/ahoy"
  ) || status=$?
  [ "$status" -eq 0 ] || fail "Pi Ahoy $label case exited $status: $out"
  case "$expected" in
    bearings)
      printf '%s\n' "$out" | grep -Fq "AHOY_BEARINGS_BRANCH" \
        || fail "Pi Ahoy $label case did not take Bearings: $out"
      ;;
    boundary)
      printf '%s\n' "$out" | grep -Fq "AHOY_BEARINGS_BRANCH" \
        && fail "Pi Ahoy $label near miss was treated as operational: $out"
      ;;
  esac
}

run_ahoy_transcript_regressions() {
  mkdir -p "$PROJECT/.agents/skills/ahoy" "$PROJECT/.agents/skills/bearings"
  cp "$ROOT/.agents/skills/ahoy/SKILL.md" "$PROJECT/.agents/skills/ahoy/SKILL.md"
  # shellcheck disable=SC2016 # Backticks are literal prompt markup.
  printf '%s\n' \
    '---' \
    'name: bearings' \
    'description: Test-only Bearings branch sentinel.' \
    '---' \
    '' \
    '# bearings' \
    '' \
    'Respond exactly `AHOY_BEARINGS_BRANCH`.' \
    > "$PROJECT/.agents/skills/bearings/SKILL.md"

  run_ahoy_case legacy-start "$LEGACY_START" bearings
  run_ahoy_case legacy-away "$LEGACY_AWAY" bearings
  run_ahoy_case marker-near-miss "$MARKER_NEAR_MISS" boundary
  run_ahoy_case startup-near-miss "$START_NEAR_MISS" boundary
  run_ahoy_case quoted-current "$QUOTED_CURRENT" boundary
  run_ahoy_case ascii-only "$ASCII_ONLY" boundary
}

run_native_ahoy_regressions() {
  local first_home="$LAB/pi-ahoy-first-home"
  local later_home="$LAB/pi-ahoy-later-home"
  local first_out later_out

  mkdir -p \
    "$AHOY_PROJECT/.pi/extensions/lib" \
    "$AHOY_PROJECT/.agents/skills/ahoy" \
    "$AHOY_PROJECT/.agents/skills/bearings" \
    "$AHOY_PROJECT/bin" \
    "$first_home/state" "$first_home/config" \
    "$later_home/state" "$later_home/config"
  git init -q "$AHOY_PROJECT"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$AHOY_PROJECT/.pi/extensions/"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$AHOY_PROJECT/.pi/extensions/lib/"
  cp \
    "$ROOT/bin/fm-sessionstart-nudge.sh" \
    "$ROOT/bin/fm-primary-scope-lib.sh" \
    "$ROOT/bin/fm-gate-refuse-lib.sh" \
    "$ROOT/bin/fm-operational-input.sh" \
    "$AHOY_PROJECT/bin/"
  cp "$ROOT/.agents/skills/ahoy/SKILL.md" "$AHOY_PROJECT/.agents/skills/ahoy/SKILL.md"
  chmod +x "$AHOY_PROJECT/bin/fm-sessionstart-nudge.sh"
  # shellcheck disable=SC2016 # Variables expand in the generated script, not this test shell.
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'file="${FM_HOME:?}/state/session-start-count"' \
    'count=0' \
    '[ ! -f "$file" ] || count=$(sed -n "1p" "$file")' \
    'count=$((count + 1))' \
    'printf "%s\n" "$count" > "$file"' \
    'printf "SESSION_START_DONE count=%s\n" "$count"' \
    > "$AHOY_PROJECT/bin/fm-session-start.sh"
  chmod +x "$AHOY_PROJECT/bin/fm-session-start.sh"
  # shellcheck disable=SC2016 # Backticks are literal prompt markup.
  printf '%s\n' \
    '---' \
    'name: bearings' \
    'description: Test-only Bearings branch sentinel.' \
    '---' \
    '' \
    '# bearings' \
    '' \
    'Respond exactly `AHOY_BEARINGS_BRANCH`.' \
    > "$AHOY_PROJECT/.agents/skills/bearings/SKILL.md"
  # shellcheck disable=SC2016 # Backticks are literal prompt markup.
  printf '%s\n' \
    '# Native Pi Ahoy regression fixture' \
    '' \
    'Run `bin/fm-session-start.sh` exactly once at session start.' \
    > "$AHOY_PROJECT/AGENTS.md"

  first_out=$(
    cd "$AHOY_PROJECT" &&
      FM_HOME="$first_home" pi --print --approve --no-session --no-context-files --no-extensions \
        -e .pi/extensions/fm-primary-turnend-guard.ts \
        --no-skills --skill .agents/skills \
        --model openai-codex/gpt-5.6-sol --thinking low \
        "/ahoy"
  )
  printf '%s\n' "$first_out" | grep -Fq "AHOY_BEARINGS_BRANCH" \
    || fail "Pi native first-message Ahoy did not take Bearings: $first_out"
  [ "$(sed -n '1p' "$first_home/state/session-start-count")" = 1 ] \
    || fail "Pi native first-message Ahoy did not preserve one session-start execution"

  later_out=$(
    cd "$AHOY_PROJECT" &&
      FM_HOME="$later_home" pi --print --approve --no-session --no-context-files --no-extensions \
        -e .pi/extensions/fm-primary-turnend-guard.ts \
        --no-skills --skill .agents/skills \
        --model openai-codex/gpt-5.6-sol --thinking low \
        "Respond exactly PRIOR_BOUNDARY_ACK." "/ahoy"
  )
  printf '%s\n' "$later_out" | grep -Fq "PRIOR_BOUNDARY_ACK" \
    || fail "Pi native later-message setup did not preserve the genuine captain boundary: $later_out"
  printf '%s\n' "$later_out" | grep -Fq "AHOY_BEARINGS_BRANCH" \
    && fail "Pi native later-message Ahoy gathered Bearings: $later_out"
  [ "$(sed -n '1p' "$later_home/state/session-start-count")" = 1 ] \
    || fail "Pi native later-message Ahoy reran session start"
}

mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT"
run_ahoy_transcript_regressions
run_native_ahoy_regressions
mkdir -p "$PROJECT/.pi/extensions/lib"
cp "$ROOT/.pi/extensions/fm-calm.ts" "$PROJECT/.pi/extensions/fm-calm.ts"
cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$PROJECT/.pi/extensions/fm-primary-pi-watch.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-assistant-layout.ts" "$PROJECT/.pi/extensions/lib/fm-calm-assistant-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-operational-user-layout.ts" "$PROJECT/.pi/extensions/lib/fm-calm-operational-user-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$PROJECT/.pi/extensions/lib/fm-calm-visibility.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-working-ship.ts" "$PROJECT/.pi/extensions/lib/fm-calm-working-ship.ts"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$PROJECT/.pi/extensions/lib/fm-operational-input.ts"
cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$PROJECT/.pi/extensions/fm-primary-turnend-guard.ts"
cp "$ROOT/bin/fm-watch-arm.sh" "$PROJECT/bin/fm-watch-arm.sh"
cp "$ROOT/bin/fm-operational-input.sh" "$PROJECT/bin/fm-operational-input.sh"
cp "$ROOT/bin/fm-supervision-instructions.sh" "$PROJECT/bin/fm-supervision-instructions.sh"
chmod +x "$PROJECT/bin/fm-operational-input.sh"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"

"$TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -c "$PROJECT" \
  "env FM_HOME='$HOME_DIR' FM_ROOT_OVERRIDE='$PROJECT' FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 bash -lc 'printf \"%s\\n\" \"\$\$\" > \"\$FM_HOME/state/.lock\"; pi --approve --no-session --no-context-files --no-extensions -e .pi/extensions/fm-calm.ts -e .pi/extensions/fm-primary-turnend-guard.ts -e .pi/extensions/fm-primary-pi-watch.ts --model openai-codex/gpt-5.6-sol --thinking low; rc=\$?; printf \"PI_EXIT=%s\\n\" \"\$rc\"; sleep 300'"

i=0
while [ "$i" -lt 120 ]; do
  [ -f "$HOME_DIR/state/.pi-turnend-extension-loaded" ] && [ -f "$HOME_DIR/state/.pi-watch-extension-loaded" ] && break
  sleep 0.5
  i=$((i + 1))
done
[ -f "$HOME_DIR/state/.pi-turnend-extension-loaded" ] || fail "Pi turn-end extension did not load"
[ -f "$HOME_DIR/state/.pi-watch-extension-loaded" ] || fail "Pi watcher extension did not load"
wait_for_text "(openai-codex)" 120 || fail "Pi did not reach its ready composer"
sleep 1

send_prompt "/calm"
sleep 0.2
send_prompt "Reply exactly CALM_LIVE_WORKING_VISIBLE"
i=0
while [ "$i" -lt 240 ]; do
  pane=$(capture)
  if printf '%s\n' "$pane" | grep -Fq '\__/'; then
    break
  fi
  sleep 0.05
  i=$((i + 1))
done
printf '%s\n' "$pane" | grep -Fq '\__/' \
  || fail "Calm did not show the working ship on the credentialed provider path"
printf '%s\n' "$pane" | grep -Fq "Working..." \
  && fail "Calm left Pi's stock working row visible on the credentialed provider path"
wait_for_exact_line "CALM_LIVE_WORKING_VISIBLE" 120 \
  || fail "Pi did not settle the Calm working-ship provider probe"
pane=$(capture)
printf '%s\n' "$pane" | grep -Fq '\__/' \
  && fail "Calm left the working ship on screen after the run settled"
printf '%s\n' "$pane" | grep -Fq "calm transcript" \
  && fail "Calm added a persistent Calm status row on the credentialed provider path"
send_prompt "/calm"
sleep 0.2

: > "$HOME_DIR/state/pi-e2e.meta"
send_prompt "Start supervision with fm_watch_arm_pi and never use bash to arm supervision. After the watcher wake arrives, run bin/fm-wake-drain.sh, handle it, run the exact WAKE_ACK_REQUIRED command, and reply exactly HANDLED."
wait_for_text "watcher: started Pi extension arm child 1" || fail "Pi did not render the initial watcher tool result"

printf 'done: pi live e2e watcher fire\n' > "$HOME_DIR/state/pi-e2e.status"
i=0
while [ "$i" -lt 240 ]; do
  grep -Eq 'reason=actionable-signal.*successor=started:[0-9]+' "$HOME_DIR/state/.watch-cycle-exits.log" 2>/dev/null && break
  sleep 0.5
  i=$((i + 1))
done
grep -Eq 'reason=actionable-signal.*successor=started:[0-9]+' "$HOME_DIR/state/.watch-cycle-exits.log" 2>/dev/null \
  || fail "Pi extension did not start and ledger-link a successor after the actionable close"
wait_for_exact_line "HANDLED" 120 || fail "Pi did not drain and settle after its extension-owned successor started"

pane=$(capture)
guard_count=$(printf '%s\n' "$pane" | grep -Fc "TURN WOULD END BLIND - supervision is off." || true)
[ "$guard_count" -eq 0 ] || fail "successor was not protecting Pi before its next turn end (guard count $guard_count)"
foreground_arm='$ bin/fm-watch-arm.sh'
if printf '%s\n' "$pane" | grep -Fq "$foreground_arm"; then
  fail "Pi used a foreground bash watcher arm"
fi
arm_tool_result_count=$(printf '%s\n' "$pane" | grep -Ec 'watcher: (started|unchanged|not armed|read-only)' || true)
[ "$arm_tool_result_count" -eq 1 ] || fail "Pi model re-armed from memory instead of the extension (tool-result count $arm_tool_result_count)"

i=0
while [ "$i" -lt 120 ]; do
  marker=$(cat "$HOME_DIR/state/.watcher-down" 2>/dev/null || true)
  if [ ! -s "$HOME_DIR/state/.wake-queue" ] && [[ "$marker" == acked:* ]]; then
    break
  fi
  sleep 0.5
  i=$((i + 1))
done
[ ! -s "$HOME_DIR/state/.wake-queue" ] || fail "Pi did not acknowledge the first actionable queue row"
[[ "$(cat "$HOME_DIR/state/.watcher-down" 2>/dev/null || true)" == acked:* ]] \
  || fail "Pi did not retire the first actionable recovery episode"
previous_watcher=$(sed -n '1p' "$(find "$HOME_DIR/state" -maxdepth 3 -type f -path '*/.watch.lock*/pid' | head -1)")

# A real same-process /new retires the prior generation and leaves only downtime
# evidence. The replacement slash command exercises the installed Pi extension
# without asking the model to remember a re-arm step.
send_prompt "/new"
wait_pid_dead "$previous_watcher" || fail "Pi /new did not retire the prior watcher generation"
send_prompt "/fm-watch-arm-pi"
wait_for_text "watcher: started Pi extension arm child 1" 120 \
  || fail "Pi replacement generation did not start its first watcher cycle"
i=0
replacement_watcher=
while [ "$i" -lt 120 ]; do
  replacement_pid_file=$(find "$HOME_DIR/state" -maxdepth 3 -type f -path '*/.watch.lock*/pid' | head -1 || true)
  replacement_watcher=$([ -n "$replacement_pid_file" ] && sed -n '1p' "$replacement_pid_file" || true)
  if [ -n "$replacement_watcher" ] && [ "$replacement_watcher" != "$previous_watcher" ] \
    && kill -0 "$replacement_watcher" 2>/dev/null; then
    break
  fi
  sleep 0.5
  i=$((i + 1))
done
if [ -z "$replacement_watcher" ] || ! kill -0 "$replacement_watcher" 2>/dev/null; then
  fail "Pi replacement generation left no live watcher"
fi
sleep 3
pane=$(capture)
printf '%s\n' "$pane" | grep -Fq "rearm-resurface" \
  && fail "empty Pi replacement injected a rearm-resurface follow-up"
[ ! -s "$HOME_DIR/state/.wake-queue" ] || fail "empty Pi replacement created a durable queue row"

# The silent replacement must still deliver the next real event exactly once.
printf 'done: pi replacement actionable wake\n' > "$HOME_DIR/state/pi-replacement-e2e.status"
wait_for_text "pi-replacement-e2e.status" 120 \
  || fail "Pi replacement did not deliver the next real actionable wake"
i=0
while [ "$i" -lt 120 ]; do
  if [ ! -s "$HOME_DIR/state/.wake-queue" ] \
    && [[ "$(cat "$HOME_DIR/state/.watcher-down" 2>/dev/null || true)" == acked:* ]]; then
    break
  fi
  sleep 0.5
  i=$((i + 1))
done
[ ! -s "$HOME_DIR/state/.wake-queue" ] || fail "Pi did not acknowledge the replacement's real wake"
sleep 3
pane=$(capture)
printf '%s\n' "$pane" | grep -Fq "rearm-resurface" \
  && fail "one Pi actionable event started an empty follow-up chain"
delivery_count=$(grep -Fc "pi-replacement-e2e.status" "$HOME_DIR/state/.watch-deliveries.log" 2>/dev/null || true)
[ "$delivery_count" -eq 1 ] || fail "Pi replacement delivered one real event $delivery_count times"

pid_file=$(find "$HOME_DIR/state" -maxdepth 3 -type f -name pid | head -1)
[ -n "$pid_file" ] || fail "re-armed watcher pid was not recorded"
watcher_pid=$(sed -n '1p' "$pid_file")
arm_pid=$(ps -p "$watcher_pid" -o ppid= | tr -d ' ')
[ -n "$arm_pid" ] || fail "re-armed watcher parent was not live"

"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l '/quit'
sleep 1
"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
wait_for_text "PI_EXIT=0" 60 || fail "Pi did not exit cleanly"
wait_pid_dead "$watcher_pid" || fail "watcher child survived clean Pi exit"
wait_pid_dead "$arm_pid" || fail "arm child survived clean Pi exit"

printf 'ok - Pi %s live E2E covered Calm, Ahoy boundaries, quiet empty replacement, single real-wake delivery, and watcher continuity\n' "$PI_VERSION"
