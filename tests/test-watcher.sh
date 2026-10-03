#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
command -v tmux >/dev/null || { echo 'tmux is required; watcher suite cannot run' >&2; exit 1; }
python3 -c 'import rich' 2>/dev/null || { echo 'Rich is required; watcher suite cannot run' >&2; exit 1; }
export PATH="$root/bin:$PATH"
work=$(mktemp -d "${TMPDIR:-/tmp}/watcher-tests.XXXXXXXX")
sockdir=
socket=
unset TMUX TMUX_PANE
cleanup() { tmux -S "$socket" kill-server 2>/dev/null || :; rm -rf -- "$work" "$sockdir"; }
trap cleanup EXIT
# Keep the private socket path short regardless of TMPDIR length.
sockdir=$(mktemp -d /tmp/cjw.XXXXXX)
socket=$sockdir/s
fail() { echo "ASSERTION: $*" >&2; exit 1; }
cases=0
pass() { cases=$((cases+1)); }
# No personal tmux configuration or shared server is used.
caller=$(tmux -S "$socket" -f /dev/null new-session -d -s tests -x 100 -y 32 -P -F '#{pane_id}' 'sleep 600')
window=$(tmux -S "$socket" display-message -p -t "$caller" '#{window_id}')
control=$(tmux -S "$socket" split-window -d -h -t "$window" -P -F '#{pane_id}' 'sleep 600')
other=$(tmux -S "$socket" new-window -d -t tests -P -F '#{pane_id}' 'sleep 600')
tmux -S "$socket" set-option -p -t "$other" @codex-jobs-view 1
other_window=$(tmux -S "$socket" display-message -p -t "$other" '#{window_id}')
# Deliberately select the other window; ownership follows the caller's pane.
tmux -S "$socket" select-window -t "$other_window"
export TMUX=$(tmux -S "$socket" display-message -p -t "$caller" '#{socket_path},#{pid},0') TMUX_PANE=$caller
export XDG_STATE_HOME=$work/state
pane_exists() { tmux -S "$socket" display-message -p -t "$1" '#{pane_id}' 2>/dev/null | python3 -c 'import sys; sys.exit(0 if sys.stdin.read().strip()==sys.argv[1] else 1)' "$1"; }
assert_other() {
    pane_exists "$other" || fail 'marked pane in other window survives'
    [[ $(tmux -S "$socket" display-message -p -t "$other" '#{@codex-jobs-view}') == 1 ]] || fail 'other window marker preserved'
    pane_exists "$control" || fail 'unmarked control pane survives'
    pane_exists "$caller" || fail 'caller pane survives'
}
assert_viewer() {
    local pane=$1 expected_python=${2:-$(command -v python3)}
    python3 - "$socket" "$pane" "$root/bin/codex-view" "$expected_python" <<'PY'
import os, subprocess, sys, time
socket, pane, viewer, interpreter = sys.argv[1:]
viewer, interpreter = map(os.path.abspath, (viewer, interpreter))
deadline = time.monotonic()+5
while True:
    state = subprocess.check_output(['tmux','-S',socket,'display-message','-p','-t',pane,
                                     '#{pane_dead} #{pane_pid}'],stderr=subprocess.DEVNULL).decode().split()
    assert state[0] == '0', 'real viewer alive after start'
    try:
        with open('/proc/{}/cmdline'.format(state[1]),'rb') as f: args=f.read().split(b'\0')
        if viewer.encode() in args and args[0] == interpreter.encode():
            assert b'--registry' in args, 'explicit registry argument'
            expected = os.path.abspath(os.path.join(os.environ['XDG_STATE_HOME'], 'codex-jobs', 'active')).encode()
            assert args[args.index(b'--registry')+1] == expected, 'caller registry reaches viewer pane'
            break
    except FileNotFoundError: pass
    assert time.monotonic() < deadline, 'pane runs real shipped viewer with caller interpreter'
    time.sleep(.02)
PY
    [[ $(tmux -S "$socket" display-message -p -t "$pane" '#{window_id}') == "$window" ]] || fail 'viewer belongs to caller window ID'
}

case_start() {
    python3 -m venv --without-pip --system-site-packages "$work/venv"
    local rich_dir venv_site
    rich_dir=$(python3 -I -c 'import os,rich; print(os.path.dirname(os.path.dirname(rich.__file__)))')
    venv_site=$("$work/venv/bin/python3" -I -c 'import sysconfig; print(sysconfig.get_path("purelib"))')
    printf '%s\n' "$rich_dir" > "$venv_site/outer-rich.pth"
    pane=$(PATH="$work/venv/bin:$PATH" codex-watcher start)
    [[ $(tmux -S "$socket" display-message -p -t "$pane" '#{@codex-jobs-view}') == 1 ]] || fail 'viewer marked'
    assert_viewer "$pane" "$work/venv/bin/python3"; assert_other; pass
}
case_reuse() {
    again=$(codex-watcher start)
    [[ $again == "$pane" ]] || fail 'start reuses same marked viewer'
    count=$(tmux -S "$socket" list-panes -t "$window" -F '#{@codex-jobs-view}' | awk '$1 == "1" {n++} END {print n+0}')
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
    dead=$(codex-watcher start)
    assert_viewer "$dead"
    kill -TERM "$(tmux -S "$socket" display-message -p -t "$dead" '#{pane_pid}')"
    sleep 0.2
    [[ $(tmux -S "$socket" display-message -p -t "$dead" '#{pane_dead}') == 1 ]] || fail 'dead-pane fixture'
    pane=$(codex-watcher start)
    [[ $pane != "$dead" ]] || fail 'dead marked pane replaced'
    if pane_exists "$dead"; then fail 'dead marked pane removed'; fi
    assert_viewer "$pane"; assert_other
    codex-watcher stop; assert_other; pass
}
case_pane_safety() {
    local copy=$work/$'viewer\tcopy' height
    mkdir -p "$copy"; cp "$root/bin/codex-watcher" "$root/bin/codex-view" "$copy/"
    tmux -S "$socket" set-option -g default-shell /bin/sh
    height=$(tmux -S "$socket" display-message -p -t "$control" '#{pane_height}')
    pane=$(cd -- "$work"; PATH="venv/bin:$PATH" "$copy/codex-watcher" start)
    python3 - "$socket" "$pane" "$copy/codex-view" "$work/venv/bin/python3" <<'PY'
import os, subprocess, sys, time
socket, pane, viewer, interpreter = sys.argv[1:]
viewer, interpreter = map(os.path.abspath, (viewer, interpreter))
for _ in range(250):
    pid = subprocess.check_output(['tmux', '-S', socket, 'display-message', '-p', '-t', pane, '#{pane_pid}']).decode().strip()
    try:
        with open('/proc/'+pid+'/cmdline', 'rb') as f: args = f.read().split(b'\0')
        if args[:2] == [interpreter.encode(), viewer.encode()]: break
    except FileNotFoundError: pass
    time.sleep(.02)
else: raise AssertionError('viewer starts under /bin/sh with literal path and absolute Python')
PY
    [[ $(tmux -S "$socket" display-message -p -t "$control" '#{pane_height}') == "$height" ]] || fail 'split belongs to caller pane'
    [[ $(tmux -S "$socket" show-options -p -v -t "$pane" remain-on-exit) == on ]] || fail 'viewer exit stays visible'
    [[ -z $(tmux -S "$socket" show-options -p -v -t "$caller" remain-on-exit) ]] || fail 'caller exit policy unchanged'
    tmux -S "$socket" set-option -w -t "$window" @codex-jobs-view 1
    tmux -S "$socket" set-option -p -t "$caller" @codex-jobs-view 1
    codex-watcher stop
    if pane_exists "$pane"; then fail 'marked viewer removed'; fi
    assert_other
    tmux -S "$socket" set-option -p -u -t "$caller" @codex-jobs-view
    tmux -S "$socket" set-option -w -u -t "$window" @codex-jobs-view
    pass
}
case_start
case_reuse
case_stop
case_dependencies
case_pane_safety
case_restart_dead
[[ $cases == 6 ]] || fail "watcher executed case count: expected 6 got $cases"
printf 'WATCHER cases=%s passed=%s failures=0 skips=0\n' "$cases" "$cases"
