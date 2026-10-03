#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
command -v tmux >/dev/null || { echo 'tmux is required; watcher suite cannot run' >&2; exit 1; }
python3 -c 'import rich' 2>/dev/null || { echo 'Rich is required; watcher suite cannot run' >&2; exit 1; }
export PATH="$root/bin:$PATH"
work=$(mktemp -d "${TMPDIR:-/tmp}/watcher-tests.XXXXXXXX")
socket=jobs-$$-$RANDOM
unset TMUX TMUX_PANE
cleanup() { tmux -L "$socket" kill-server 2>/dev/null || :; rm -rf -- "$work"; }
trap cleanup EXIT
fail() { echo "ASSERTION: $*" >&2; exit 1; }
cases=0
pass() { cases=$((cases+1)); }
# No personal tmux configuration or shared server is used.
caller=$(tmux -L "$socket" -f /dev/null new-session -d -s tests -x 100 -y 32 -P -F '#{pane_id}' 'sleep 600')
window=$(tmux -L "$socket" display-message -p -t "$caller" '#{window_id}')
control=$(tmux -L "$socket" split-window -d -h -t "$window" -P -F '#{pane_id}' 'sleep 600')
other=$(tmux -L "$socket" new-window -d -t tests -P -F '#{pane_id}' 'sleep 600')
tmux -L "$socket" set-option -p -t "$other" @codex-jobs-view 1
other_window=$(tmux -L "$socket" display-message -p -t "$other" '#{window_id}')
# Deliberately select the other window; ownership follows the caller's pane.
tmux -L "$socket" select-window -t "$other_window"
export TMUX=$(tmux -L "$socket" display-message -p -t "$caller" '#{socket_path},#{pid},0') TMUX_PANE=$caller
export XDG_STATE_HOME=$work/state
pane_exists() { tmux -L "$socket" display-message -p -t "$1" '#{pane_id}' 2>/dev/null | python3 -c 'import sys; sys.exit(0 if sys.stdin.read().strip()==sys.argv[1] else 1)' "$1"; }
assert_other() {
    pane_exists "$other" || fail 'marked pane in other window survives'
    [[ $(tmux -L "$socket" display-message -p -t "$other" '#{@codex-jobs-view}') == 1 ]] || fail 'other window marker preserved'
    pane_exists "$control" || fail 'unmarked control pane survives'
    pane_exists "$caller" || fail 'caller pane survives'
}
assert_viewer() {
    local pane=$1 expected_python=${2:-$(command -v python3)}
    python3 - "$socket" "$pane" "$root/bin/codex-view" "$expected_python" <<'PY'
import subprocess, sys, time
socket, pane, viewer, interpreter = sys.argv[1:]
deadline = time.monotonic()+5
while True:
    state = subprocess.check_output(['tmux','-L',socket,'display-message','-p','-t',pane,
                                     '#{pane_dead} #{pane_pid}'],stderr=subprocess.DEVNULL).decode().split()
    assert state[0] == '0', 'real viewer alive after start'
    try:
        with open('/proc/{}/cmdline'.format(state[1]),'rb') as f: args=f.read().split(b'\0')
        if viewer.encode() in args and args[0] == interpreter.encode(): break
    except FileNotFoundError: pass
    assert time.monotonic() < deadline, 'pane runs real shipped viewer with caller interpreter'
    time.sleep(.02)
PY
    [[ $(tmux -L "$socket" display-message -p -t "$pane" '#{window_id}') == "$window" ]] || fail 'viewer belongs to caller window ID'
}

case_start() {
    python3 -m venv --without-pip --system-site-packages "$work/venv"
    pane=$(PATH="$work/venv/bin:$PATH" codex-watcher start)
    [[ $(tmux -L "$socket" display-message -p -t "$pane" '#{@codex-jobs-view}') == 1 ]] || fail 'viewer marked'
    assert_viewer "$pane" "$work/venv/bin/python3"; assert_other; pass
}
case_reuse() {
    again=$(codex-watcher start)
    [[ $again == "$pane" ]] || fail 'start reuses same marked viewer'
    count=$(tmux -L "$socket" list-panes -t "$window" -F '#{@codex-jobs-view}' | awk '$1 == "1" {n++} END {print n+0}')
    [[ $count == 1 ]] || fail 'one marked pane in caller window'
    assert_viewer "$pane" "$work/venv/bin/python3"; assert_other; pass
}
case_stop() {
    codex-watcher stop
    if pane_exists "$pane"; then fail 'stop removes marked caller pane'; fi
    assert_other; codex-watcher stop; assert_other; pass
}
case_dependencies() {
    mkdir -p "$work/no-tools" "$work/bin" "$work/shim"
    rc=0; PATH="$work/no-tools" /bin/bash "$root/bin/codex-watcher" start > "$work/out" 2> "$work/err" || rc=$?
    [[ $rc == 2 && $(< "$work/err") == *'tmux is required'* ]] || fail 'missing tmux fails clearly'
    cp "$root/bin/codex-watcher" "$work/bin/"
    rc=0; "$work/bin/codex-watcher" start > "$work/out" 2> "$work/err" || rc=$?
    [[ $rc == 2 && $(< "$work/err") == *'viewer is unavailable'* ]] || fail 'missing viewer fails clearly'
    printf '#!/bin/sh\nexit 1\n' > "$work/shim/python3"; chmod +x "$work/shim/python3"
    rc=0; PATH="$work/shim:$PATH" codex-watcher start > "$work/out" 2> "$work/err" || rc=$?
    [[ $rc == 2 && $(< "$work/err") == *'Rich is required'* ]] || fail 'missing Rich fails clearly'
    assert_other; pass
}
case_restart_dead() {
    tmux -L "$socket" set-option -w -t "$window" remain-on-exit on
    dead=$(tmux -L "$socket" split-window -d -v -t "$window" -P -F '#{pane_id}' 'exit 0')
    tmux -L "$socket" set-option -p -t "$dead" @codex-jobs-view 1
    sleep 0.2
    [[ $(tmux -L "$socket" display-message -p -t "$dead" '#{pane_dead}') == 1 ]] || fail 'dead-pane fixture'
    pane=$(codex-watcher start)
    [[ $pane != "$dead" ]] || fail 'dead marked pane replaced'
    if pane_exists "$dead"; then fail 'dead marked pane removed'; fi
    assert_viewer "$pane"; assert_other
    codex-watcher stop; assert_other; pass
}
case_start
case_reuse
case_stop
case_dependencies
case_restart_dead
[[ $cases == 5 ]] || fail "watcher executed case count: expected 5 got $cases"
printf 'WATCHER cases=%s passed=%s failures=0 skips=0\n' "$cases" "$cases"
