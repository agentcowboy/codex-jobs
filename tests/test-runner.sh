#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
export PATH="$root/bin:$PATH" CODEX_BIN="$root/tests/fake-codex"
work=$(mktemp -d "${TMPDIR:-/tmp}/runner-tests.XXXXXXXX")
children=()
cleanup() {
    for child in "${children[@]}"; do
        kill -KILL "$child" 2>/dev/null || :
    done
    # Test fixtures may deliberately leave a resistant group after a mutation test.
    python3 - "$work" <<'PY'
import glob, os, signal, sys
for path in glob.glob(sys.argv[1]+'/*/fake/ready') + glob.glob(sys.argv[1]+'/*/fake/descendant'):
    try:
        with open(path) as f: pid = int(f.read())
        os.killpg(pid, signal.SIGKILL) if path.endswith('/ready') else os.kill(pid, signal.SIGKILL)
    except (OSError, ValueError): pass
PY
    rm -rf -- "$work"
}
trap cleanup EXIT
cases=0
fail() { echo "ASSERTION: $*" >&2; exit 1; }
pass() { cases=$((cases + 1)); }
setup() {
    dir=$work/$1
    mkdir -p "$dir/fake" "$dir/state" "$dir/cwd"
    export FAKE_DIR=$dir/fake XDG_STATE_HOME=$dir/state
    unset FAKE_HANG FAKE_IGNORE_TERM FAKE_DESCENDANT FAKE_RC
    printf 'synthetic prompt marker\nsecond line\n' > "$dir/prompt"
}
invoke() { codex-hands --cwd "$dir/cwd" "$@" demo-model high "$dir/prompt" "$dir/out" "$dir/log"; }
wait_file() {
    local file=$1
    for ((i=0;i<500;i++)); do [[ ! -s $file ]] || return 0; sleep 0.01; done
    fail "readiness/activity check: ${file##*/}"
}
assert_rc() {
    local expected=$1; shift
    local got=0
    "$@" > "$dir/stdout" 2> "$dir/stderr" || got=$?
    [[ $got == "$expected" ]] || fail "exit code expected $expected got $got"
}
assert_args() {
    python3 - "$dir" "$1" "$2" <<'PY'
import json, os, sys
root, mode, sandbox = sys.argv[1:]
root = os.path.abspath(root)
with open(root+'/fake/argv.json') as f: actual = json.load(f)
expected = ['exec', '-C', root+'/cwd', '--sandbox', sandbox, '-c', 'approval_policy="never"',
            '-m', 'demo-model', '-c', 'model_reasoning_effort=high']
if mode == 'resume': expected += ['resume', 'demo-session']
expected += ['--json', '-o', root+'/out', '-']
with open(root+'/prompt', 'rb') as f: prompt = f.read()
with open(root+'/fake/stdin', 'rb') as f: received = f.read()
assert received == prompt and received.endswith(b'\n'), 'exact stdin bytes including trailing newline'
assert 'synthetic prompt marker' not in ' '.join(actual), 'prompt text absent from argv'
assert actual == expected, 'exact native argv: sandbox and approval defaults, parent option placement'
PY
}
assert_receipt() {
    python3 - "$dir" "$1" <<'PY'
import json, os, sys
root, rc = sys.argv[1:]
with open(root+'/out.done') as f: data = json.load(f)
assert data['rc'] == int(rc), 'receipt process rc'
assert data['started_at'] <= data['ended_at'], 'receipt timestamps'
assert not [n for n in os.listdir(root) if n.startswith('.receipt-')], 'atomic receipt temp removed'
assert not os.listdir(root+'/state/codex-jobs/active'), 'registry removed after result'
with open(root+'/log') as f:
    for line in f: json.loads(line)
with open(root+'/log.stderr') as f: assert 'synthetic diagnostic' in f.read(), 'stderr separated'
PY
}
start_job() {
    rm -f "$dir/fake/ready" "$dir/fake/activity"
    codex-hands --cwd "$dir/cwd" demo-model high "$dir/prompt" "$dir/out" "$dir/log" > "$dir/stdout" 2> "$dir/stderr" & wrapper=$!
    children+=("$wrapper")
    wait_file "$dir/fake/ready"
    wait_file "$dir/fake/activity"
    if [[ ${FAKE_DESCENDANT:-} == 1 ]]; then
        wait_file "$dir/fake/descendant"; wait_file "$dir/fake/descendant-activity"
    fi
    [[ ! -e $dir/out.done ]] || fail 'no receipt while running'
}
assert_dead() {
    python3 - "$dir/fake" <<'PY'
import os, sys, time
for name in ('ready', 'descendant'):
    path = os.path.join(sys.argv[1], name)
    if not os.path.exists(path): continue
    with open(path) as f: pid = int(f.read())
    for _ in range(100):
        try:
            with open('/proc/{}/stat'.format(pid)) as f: state = f.read().rsplit(')', 1)[1].split()[0]
        except FileNotFoundError: break
        if state == 'Z': break
        time.sleep(0.01)
    else: raise AssertionError('KILL escalation: resistant group member is still active')
PY
}
now() { python3 -c 'import time; print(time.monotonic())'; }
assert_bound() {
    python3 - "$1" "$(now)" <<'PY'
import sys
elapsed = float(sys.argv[2])-float(sys.argv[1])
assert 9.8 <= elapsed <= 12, '10 s grace / 10+2 s cancellation bound: {:.3f}'.format(elapsed)
PY
}

case_fresh() {
    setup fresh; assert_rc 0 invoke; assert_args fresh read-only; assert_receipt 0; pass
}
case_resume() {
    setup resume
    assert_rc 0 codex-hands resume --cwd "$dir/cwd" demo-session demo-model high "$dir/prompt" "$dir/out" "$dir/log"
    assert_args resume read-only; assert_receipt 0; pass
}
case_readme_resume() {
    setup readme-resume; assert_rc 0 invoke
    cp "$dir/log" "$dir/run.jsonl"
    local recipe
    recipe=$(python3 - "$root/README.md" <<'PY'
import sys
with open(sys.argv[1]) as f:
    lines = [line.rstrip('\n') for line in f if line.startswith('SESSION=$(python3 -c ')]
assert len(lines) == 1, 'one exact README session extractor'
print(lines[0])
PY
)
    SESSION=$(cd -- "$dir"; eval "$recipe" || exit $?; printf '%s\n' "$SESSION")
    [[ $SESSION == demo-session ]] || fail 'README extracts fake thread ID'
    assert_rc 0 codex-hands resume --cwd "$dir/cwd" "$SESSION" demo-model high "$dir/prompt" "$dir/out" "$dir/log"
    assert_args resume read-only; assert_receipt 0
    # A run log may exist before Codex emits its first thread event.
    for content in '' '{"type":"turn.completed"}'; do
        printf '%s' "$content" > "$dir/run.jsonl"
        local rc=0
        (cd -- "$dir"; eval "$recipe") > "$dir/extract.out" 2> "$dir/extract.err" || rc=$?
        [[ $rc == 1 && ! -s $dir/extract.out ]] || fail 'README missing thread exits nonzero without session'
        [[ $(< "$dir/extract.err") == 'no thread.started event yet in run.jsonl' ]] || fail 'README missing thread message without traceback'
    done
    pass
}
case_write_fresh() {
    setup write-fresh; assert_rc 0 invoke --sandbox workspace-write
    assert_args fresh workspace-write; pass
}
case_write_resume() {
    setup write-resume
    assert_rc 0 codex-hands resume --cwd "$dir/cwd" --sandbox workspace-write demo-session demo-model high "$dir/prompt" "$dir/out" "$dir/log"
    assert_args resume workspace-write; pass
}
case_reject_options() {
    setup reject-options
    for option in --label --dangerously-bypass-approvals-and-sandbox --unknown; do
        assert_rc 2 invoke "$option"
    done
    assert_rc 2 invoke --sandbox invalid
    [[ ! -e $dir/fake/argv.json ]] || fail 'invalid option never launches Codex'; pass
}
case_failure() {
    setup failure; export FAKE_RC=23; assert_rc 23 invoke
    [[ -f $dir/out.failed && ! -e $dir/out ]] || fail 'failed output rotation'
    assert_receipt 23; pass
}
case_retry() {
    setup retry; assert_rc 0 invoke
    cp "$dir/out" "$dir/expected"; cp "$dir/log" "$dir/expected-log"
    export FAKE_HANG=1
    start_job
    cmp "$dir/expected" "$dir/out.prev" || fail 'prior output rotated'
    cmp "$dir/expected-log" "$dir/log.prev" || fail 'prior JSONL rotated'
    [[ -f $dir/log.stderr.prev ]] || fail 'prior stderr rotated'
    : > "$dir/fake/finish"; wait "$wrapper"
    assert_receipt 0; pass
}
case_alias() {
    setup alias
    assert_rc 1 codex-hands --cwd "$dir/cwd" demo-model high "$dir/prompt" "$dir/out" "$dir/prompt"
    ln "$dir/prompt" "$dir/hardlink"
    assert_rc 1 codex-hands --cwd "$dir/cwd" demo-model high "$dir/prompt" "$dir/hardlink" "$dir/log"
    assert_rc 1 codex-hands --cwd "$dir/cwd" demo-model high "$dir/prompt" "$dir/out" "$dir/out.done"
    ln -s "$dir/prompt" "$dir/symlink"
    assert_rc 1 codex-hands --cwd "$dir/cwd" demo-model high "$dir/prompt" "$dir/symlink" "$dir/log"
    [[ ! -e $dir/fake/argv.json ]] || fail 'alias refusal before launch'
    [[ $(wc -l < "$dir/prompt") == 2 ]] || fail 'prompt not truncated'; pass
}
case_nonregular() {
    setup nonregular
    mkfifo "$dir/fifo"
    printf 'prior output\n' > "$dir/out"
    for role in prompt out log; do
        local prompt=$dir/prompt out=$dir/out log=$dir/log
        case $role in prompt) prompt=$dir/fifo;; out) out=$dir/fifo;; log) log=$dir/fifo;; esac
        assert_rc 1 codex-hands --cwd "$dir/cwd" demo-model high "$prompt" "$out" "$log"
        [[ $(< "$dir/stderr") == *'must be regular files'* ]] || fail 'nonregular refusal message'
        [[ ! -e $dir/out.done && ! -e $dir/out.prev && ! -e $dir/fake/argv.json ]] || fail 'nonregular refusal before mutation or launch'
        [[ $(< "$dir/out") == 'prior output' && -p $dir/fifo ]] || fail 'nonregular refusal preserves artifacts'
    done
    pass
}
case_missing_directory() {
    setup missing-directory
    assert_rc 2 codex-hands --cwd "$dir/cwd" demo-model high "$dir/prompt" "$dir/missing/out" "$dir/log"
    [[ $(< "$dir/stderr") == 'artifact directory is unavailable' ]] || fail 'missing directory clean error'
    [[ ! -e $dir/log && ! -e $dir/fake/argv.json ]] || fail 'missing directory before mutation or launch'
    pass
}
case_abandoned_launch() {
    setup abandoned-launch; mkdir "$dir/shim" "$dir/tmp"
    local real_python=$(command -v python3)
    export REAL_PYTHON=$real_python
    cat > "$dir/shim/python3" <<'SH'
#!/usr/bin/env bash
if [[ $# == 2 && $1 == - && $2 =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$2" > "$FAKE_DIR/ready"
    while [[ ! -e $FAKE_DIR/release ]]; do sleep 0.01; done
    exit 1
fi
exec "$REAL_PYTHON" "$@"
SH
    chmod +x "$dir/shim/python3"
    for reason in scratch parent; do
        rm -f "$dir/fake/ready" "$dir/fake/release"
        PATH="$dir/shim:$PATH" TMPDIR="$dir/tmp" codex-hands --cwd "$dir/cwd" demo-model high "$dir/prompt" "$dir/out" "$dir/log" > "$dir/stdout" 2> "$dir/stderr" & wrapper=$!
        children+=("$wrapper"); wait_file "$dir/fake/ready"
        if [[ $reason == parent ]]; then kill -KILL "$wrapper"; fi
        : > "$dir/fake/release"
        got=0; wait "$wrapper" 2>/dev/null || got=$?
        [[ $got != 0 ]] || fail 'abandoned wrapper exits unsuccessfully'
        assert_dead
        [[ ! -e $dir/fake/argv.json && ! -e $dir/out.done ]] || fail 'abandoned launch never starts Codex or writes receipt'
        if [[ $reason == scratch ]]; then
            [[ -z $(find "$dir/tmp" -mindepth 1 -print -quit) ]] || fail 'failed launch removes scratch'
        else
            [[ -n $(find "$dir/tmp" -name pid -print -quit) ]] || fail 'killed wrapper leaves scratch for parent-loss check'
        fi
    done
    pass
}
case_permissions() {
    setup permissions; (umask 022; invoke)
    python3 - "$dir" <<'PY'
import os, stat, sys
for name in ('out', 'log', 'log.stderr', 'out.done'):
    assert stat.S_IMODE(os.stat(sys.argv[1]+'/'+name).st_mode) == 0o600, 'new artifact mode 0600: '+name
PY
    chmod 0644 "$dir/out"; invoke
    [[ $(stat -c %a "$dir/out.prev") == 644 ]] || fail 'existing output permissions preserved'
    pass
}
case_registry() {
    setup registry; export FAKE_HANG=1; start_job; first=$wrapper; first_dir=$dir
    # Second job shares the registry but has independent artifacts and activity.
    setup registry-second; export XDG_STATE_HOME=$first_dir/state FAKE_HANG=1; start_job; second=$wrapper
    python3 - "$first_dir/state" "$first" "$second" <<'PY'
import glob, json, os, stat, sys
base = sys.argv[1]+'/codex-jobs'
files = glob.glob(base+'/active/*.json')
assert len(files) == 2, 'two concurrent descriptors'
ids = set()
for path in files:
    assert stat.S_IMODE(os.stat(path).st_mode) == 0o600, 'descriptor mode 0600'
    with open(path) as f: data = json.load(f)
    assert set(data) == set(('schema','job_id','model','effort','started_at','pid','pid_start','boot_id','runlog','session_id')), 'registry fields'
    ids.add(data['job_id'])
    assert data['schema'] == 1 and data['session_id'] is None, 'schema and nullable session'
    with open('/proc/{}/stat'.format(data['pid'])) as f:
        assert data['pid_start'] == int(f.read().rsplit(')', 1)[1].split()[19]), 'process start identity'
    with open('/proc/sys/kernel/random/boot_id') as f:
        assert data['boot_id'] == f.read().strip(), 'boot identity matches'
    assert os.path.isabs(data['runlog']), 'absolute runlog'
assert len(ids) == 2, 'distinct generated job IDs'
assert {json.load(open(p))['pid'] for p in files} == {int(sys.argv[2]),int(sys.argv[3])}, 'wrapper identities'
for p in (base, base+'/active'):
    assert stat.S_IMODE(os.stat(p).st_mode) == 0o700, 'registry directory mode 0700'
PY
    : > "$first_dir/fake/finish"; : > "$dir/fake/finish"
    wait "$first"; wait "$second"
    [[ -z $(find "$first_dir/state/codex-jobs/active" -name '*.json' -print -quit) ]] || fail 'concurrent cleanup'
    pass
}
case_registry_failure() {
    setup registry-failure; : > "$dir/not-dir"; export XDG_STATE_HOME=$dir/not-dir
    assert_rc 0 invoke
    [[ -f $dir/out.done ]] || fail 'registry failure does not fail result'
    [[ $(< "$dir/stderr") == *'warning: registry publication failed'* ]] || fail 'publication failure warning'
    pass
}
case_term() {
    setup term; export FAKE_HANG=1 FAKE_IGNORE_TERM=1 FAKE_DESCENDANT=1; start_job
    began=$(now); kill -TERM "$wrapper"; sleep 0.2; kill -HUP "$wrapper"; kill -TERM "$wrapper"
    # Assert escalation independently of wait: removing KILL must fail behaviorally.
    sleep 10.1; assert_dead
    got=0; wait "$wrapper" || got=$?
    [[ $got == 143 && ! -e $dir/out.done ]] || fail 'TERM rc and no cancellation receipt'
    assert_bound "$began"; assert_dead
    [[ -z $(find "$dir/state/codex-jobs/active" -name '*.json' -print -quit) ]] || fail 'cancel registry cleanup'
    pass
}
case_hup() {
    setup hup; export FAKE_HANG=1 FAKE_IGNORE_TERM=1; start_job
    began=$(now); kill -HUP "$wrapper"; got=0; wait "$wrapper" || got=$?
    [[ $got == 129 && ! -e $dir/out.done ]] || fail 'HUP rc and no cancellation receipt'
    assert_bound "$began"; assert_dead; pass
}
case_int() {
    setup int; export FAKE_HANG=1 FAKE_IGNORE_TERM=1
    # Set INT explicitly, independent of the test driver's inherited disposition.
    python3 - "$dir" <<'PY'
import os, signal, subprocess, sys, time
root = sys.argv[1]
p = subprocess.Popen(['codex-hands','--cwd',root+'/cwd','demo-model','high',root+'/prompt',root+'/out',root+'/log'], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_DFL))
try:
    deadline = time.monotonic()+5
    while not (os.path.exists(root+'/fake/ready') and os.path.exists(root+'/fake/activity') and os.path.getsize(root+'/fake/activity')):
        assert time.monotonic() < deadline, 'INT readiness/activity check'
        time.sleep(.01)
    began = time.monotonic(); p.send_signal(signal.SIGINT)
    assert p.wait(timeout=12) == 130, 'qualified INT rc'
    assert 9.8 <= time.monotonic()-began <= 12, 'qualified INT cancellation bound'
    assert not os.path.exists(root+'/out.done'), 'INT no receipt'
finally:
    if p.poll() is None: p.kill(); p.wait()
PY
    assert_dead; pass
}
case_launch_cancel() {
    setup launch-cancel; mkdir "$dir/shim"
    real_setsid=$(command -v setsid); export REAL_SETSID=$real_setsid
    cat > "$dir/shim/setsid" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FAKE_DIR/launcher-ready"
printf '.' > "$FAKE_DIR/launcher-activity"
sleep 0.3
exec "$REAL_SETSID" "$@"
SH
    chmod +x "$dir/shim/setsid"
    PATH="$dir/shim:$PATH" codex-hands --cwd "$dir/cwd" demo-model high "$dir/prompt" "$dir/out" "$dir/log" > "$dir/stdout" 2> "$dir/stderr" & wrapper=$!; children+=("$wrapper")
    wait_file "$dir/fake/launcher-ready"; wait_file "$dir/fake/launcher-activity"
    began=$(now); kill -TERM "$wrapper"; got=0; wait "$wrapper" || got=$?
    [[ $got == 143 && ! -e $dir/out.done && ! -e $dir/fake/argv.json ]] || fail 'launch signal deferred to verified group before native exec'
    assert_bound "$began"; pass
}
case_descendants() {
    setup descendants; export FAKE_HANG=1 FAKE_DESCENDANT=1; start_job
    : > "$dir/fake/finish"; wait "$wrapper"
    assert_dead; assert_receipt 0; pass
}
case_late_signal() {
    setup late-signal; export FAKE_HANG=1 FAKE_DESCENDANT=1; start_job
    : > "$dir/fake/finish"
    # A sleep child after the leader exits provides evidence of the finalization grace.
    python3 - "$wrapper" "$dir/fake/ready" <<'PY'
import os, sys, time
with open(sys.argv[2]) as f: leader = int(f.read())
for _ in range(500):
    if not os.path.exists('/proc/{}/stat'.format(leader)):
        with open('/proc/{}/task/{}/children'.format(sys.argv[1],sys.argv[1])) as f: children = f.read().split()
        if any(open('/proc/{}/comm'.format(pid)).read().strip() == 'sleep' for pid in children): break
    time.sleep(.01)
else: raise AssertionError('leader exit and finalization readiness check')
PY
    kill -TERM "$wrapper"; kill -HUP "$wrapper"; wait "$wrapper"
    assert_dead; assert_receipt 0; pass
}

case_resume_registry() {
    setup resume-registry; export FAKE_HANG=1
    codex-hands resume --cwd "$dir/cwd" demo-session demo-model high "$dir/prompt" "$dir/out" "$dir/log" > "$dir/stdout" 2> "$dir/stderr" & wrapper=$!
    children+=("$wrapper"); wait_file "$dir/fake/ready"; wait_file "$dir/fake/activity"
    assert_args resume read-only
    python3 - "$dir/state" <<'PYTEST'
import glob,json,sys
files=glob.glob(sys.argv[1]+'/codex-jobs/active/*.json')
assert len(files)==1, 'active resume descriptor'
with open(files[0]) as f: data=json.load(f)
assert data['session_id']=='demo-session', 'resume registry session ID'
PYTEST
    : > "$dir/fake/finish"; wait "$wrapper"; assert_receipt 0; pass
}
case_registry_cleanup_warning() {
    setup registry-cleanup-warning; mkdir "$dir/shim"
    cat > "$dir/shim/rm" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
    case $arg in */codex-jobs/active/*.json) exit 1;; esac
done
exec /bin/rm "$@"
SH
    chmod +x "$dir/shim/rm"
    assert_rc 0 env PATH="$dir/shim:$PATH" codex-hands --cwd "$dir/cwd" demo-model high "$dir/prompt" "$dir/out" "$dir/log"
    [[ $(< "$dir/stderr") == *'warning: registry removal failed'* ]] || fail 'registry removal failure warning'
    [[ -f $dir/out.done ]] || fail 'removal failure does not fail finalized result'
    files=("$dir/state/codex-jobs/active/"*.json)
    [[ -f ${files[0]} ]] || fail 'failed-removal check'
    /bin/rm "${files[@]}"; assert_receipt 0; pass
}

case_forked_setsid() {
    setup forked-setsid; mkdir "$dir/shim"; export FAKE_HANG=1
    real_setsid=$(command -v setsid); export REAL_SETSID=$real_setsid
    cat > "$dir/shim/setsid" <<'SH'
#!/usr/bin/env bash
exec "$REAL_SETSID" --fork "$@"
SH
    chmod +x "$dir/shim/setsid"
    PATH="$dir/shim:$PATH" start_job
    python3 - "$wrapper" "$dir/fake/ready" <<'PYTEST'
import sys
with open(sys.argv[2]) as f: child=int(f.read())
with open('/proc/{}/task/{}/children'.format(sys.argv[1],sys.argv[1])) as f: launcher=int(f.read().strip())
assert launcher != child, 'setsid fork check: launcher differs from group owner'
with open('/proc/{}/stat'.format(child)) as f: fields=f.read().rsplit(')',1)[1].split()
assert int(fields[2]) == child, 'forked child owns verified PGID'
PYTEST
    : > "$dir/fake/finish"; wait "$wrapper"; assert_receipt 0; pass
}

case_fresh
case_resume
case_readme_resume
case_write_fresh
case_write_resume
case_reject_options
case_failure
case_retry
case_alias
case_nonregular
case_missing_directory
case_abandoned_launch
case_permissions
case_registry
case_registry_failure
case_resume_registry
case_registry_cleanup_warning
case_term
case_hup
case_int
case_launch_cancel
case_forked_setsid
case_descendants
case_late_signal
[[ $cases == 24 ]] || fail "runner executed case count: expected 24 got $cases"
printf 'RUNNER cases=%s passed=%s failures=0 skips=0\n' "$cases" "$cases"
