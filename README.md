# codex-jobs

A small shell-facing supervisor for Codex jobs, with result receipts, a file-based live registry, and a terminal viewer. Derived from a private runner, with a narrower standalone profile. This v0.1 implementation is written for the public contract below; it has synthetic offline tests.

## Run the tests

Requirements: Linux with readable `/proc` and `/proc/PID/task/PID/children` (`CONFIG_PROC_CHILDREN`, needed by two tests), Bash 4.4+, Python 3.7+, coreutils, util-linux `setsid`, and [Rich](https://github.com/Textualize/rich). tmux is optional for ordinary runner/viewer use and required for full acceptance. Codex is needed for actual jobs; acceptance uses only `tests/fake-codex`. `rich==13.3.1` is the only declared Python dependency, pinned to the version tested.

```bash
python3 -m venv .venv
. .venv/bin/activate
python3 -m pip install -r requirements.txt
bash ACCEPTANCE
```

After dependency installation, acceptance needs no network, credentials, or Codex installation. It runs 20 runner cases, 23 Python viewer cases and 5 watcher cases on an isolated tmux server. Acceptance takes about a minute because six cases each wait the 10 s grace. Missing Rich or tmux fails clearly. Temporary storage (`TMPDIR`, default `/tmp`) must permit executing scripts. Acceptance works from `/` by absolute path and leaves the checkout unchanged. Success prints exactly:

```text
CODEX_JOBS TESTS cases=48 passed=48 failures=0 skips=0
CODEX_JOBS ACCEPTANCE PASS
```

The count comes from executed shell cases and Python's test result, checked against pinned per-suite counts. Failures, skipped cases and omitted cases prevent PASS. Lifecycle cases check child readiness/activity, then check signal outcomes, the cancellation bound and group escalation. Watcher cases run the real viewer and preserve a second marked pane in another window.

## Run a job

Put `bin` on your `PATH` and configure Codex separately. Codex itself requires `DIR` to be inside a git repository unless configured otherwise; this runner doesn't pass `--skip-git-repo-check`. The runner inherits Codex's normal configuration and authentication; it does not manage credentials.

```bash
export PATH="$PWD/bin:$PATH"
printf 'Describe the files in this directory.\n' > prompt.txt
codex-hands --cwd "$PWD" demo-model high prompt.txt answer.txt run.jsonl
codex-hands resume --cwd "$PWD" demo-session demo-model high prompt.txt follow-up.txt
codex-hands --cwd "$PWD" --sandbox workspace-write demo-model high prompt.txt answer.txt
codex-view
codex-view --log run.jsonl
codex-view --once --log run.jsonl
```

Replace `demo-model`, `high` and `demo-session` with native values. Only argument syntax is checked; Codex decides model availability and effort compatibility. `CODEX_BIN` selects one executable (default `codex` on `PATH`). There is no bypass or label option. The CLI is:

```text
codex-hands --cwd DIR [--sandbox read-only|workspace-write] MODEL EFFORT PROMPT-FILE OUT-FILE [RUNLOG]
codex-hands resume --cwd DIR [--sandbox read-only|workspace-write] SESSION MODEL EFFORT PROMPT-FILE OUT-FILE [RUNLOG]
```

Default policy is `--sandbox read-only` plus `-c approval_policy="never"`; `workspace-write` is an explicit opt-in. The native fresh arguments are `exec -C DIR --sandbox S -c approval_policy="never" -m MODEL -c model_reasoning_effort=EFFORT --json -o OUT -`. Resume inserts `resume SESSION` before `--json`; all parent options stay before `resume`. Parent-option placement was parse-checked on Codex 0.160.0; `--json`/`-o` after `resume` follow Codex's source (both are global flags) but weren't run natively. Both redirect the prompt file directly into stdin, preserving trailing newlines and keeping prompt text out of argv. Disabling approval prompts does not remove startup or network waits. Native permission and resume behaviour aren't covered by the offline tests.

## Artifacts and cancellation

`OUT-FILE` holds the final message. `RUNLOG` (default `OUT-FILE.jsonl`) captures stdout JSONL; `RUNLOG.stderr` captures separate diagnostics. A retry first removes `OUT-FILE.done` and rotates existing output/log/diagnostic files to `.prev`. A nonzero native exit moves any new output to `OUT-FILE.failed`. A successful retry leaves any earlier `OUT-FILE.failed` in place. Rotation replaces an older file at the same rotation destination. Aliases among the prompt and artifact paths, including hardlinks, are refused before mutation; artifact symlinks are also refused.

The atomic JSON receipt `OUT-FILE.done` contains `rc`, `started_at` and `ended_at`. It records process outcome, not answer correctness. A missing receipt means no finalized result, even if an output exists. The wrapper returns the native process rc; usage errors return 2, and alias refusal or a launch-handshake failure return 1, without a receipt. New artifacts use `umask 077`; existing files and rotated files retain the caller's permissions.

Run in the foreground, or background it and keep its PID. TERM and HUP are the supported background cancellation interface; INT works only when the shell's inherited disposition allows it. Internally job control is off. Launch signals are deferred until the child PID and owned PGID are captured and verified. Cancellation sends TERM to that group, always waits the full 10 s grace, then sends KILL; a TERM-resistant child is tested to return within 10+2 seconds of the first signal. Repeated signals do not interrupt cleanup. Cancellation returns 128+signal and writes no receipt.

Normal completion with lingering descendants can add up to 10 s. After the leader exits, descendants are signalled and finalization begins; late catchable signals do not tear the receipt. The promise is bounded signal escalation on the owned process group. Detached processes, zombies, SIGKILL and parent-crash recovery are outside that promise. This is not a scheduler, queue, orchestration system or security boundary. Use distinct artifact paths for concurrent jobs.

## Registry and viewer

The best-effort registry lives at `${XDG_STATE_HOME:-$HOME/.local/state}/codex-jobs/active`. Owned directories are 0700 and descriptor files 0600. Publication failures warn without failing the job; exit attempts descriptor removal and warns on failure. Schema 1 has `schema`, generated UUID `job_id`, `model`, `effort`, UTC `started_at`, wrapper `pid`, `pid_start`, `boot_id`, absolute `runlog`, and nullable `session_id`. `pid_start` is Linux `/proc/PID/stat` field 22 in clock ticks, parsed after the final `)` of the process name. `boot_id` is read from `/proc/sys/kernel/random/boot_id` for identity comparison and never displayed. Producer and viewer assume the same PID namespace; unreadable process identity is unknown, not stale. No prompt-derived label is stored.

The viewer distinguishes unavailable, empty, malformed, stale and unreadable inputs. EOF is not completion; native turn events drive turn status. `turn.failed` and `error` remain in retained detail after later success. Limits per job per refresh: 1 MiB read, 256 KiB per record, 200 detail items and 256 in-flight IDs. Oversized records produce a truncation marker, discard through newline and resume parsing. Oldest in-flight IDs are evicted and counted. Total memory scales with the number of jobs. Replacement and truncation reset the stream position. `j`/`k` or Tab changes focus; focus stays on the same job as the roster changes. Rendering crops to terminal dimensions and never resizes tmux.

Command-output bodies are omitted from detail. This is **not redaction**: command strings, reasoning, messages, raw logs and final output can still hold secrets. Protect those local artifacts accordingly.

Inside tmux, `codex-watcher start` starts or reuses one pane marked `@codex-jobs-view=1` in the caller's window, resolved by window ID from the caller's pane. `codex-watcher stop` removes marked panes only there. Unmarked panes and marked panes in other windows are preserved. A missing viewer, tmux or Rich fails clearly. Pane ownership uses the marker; reserve it for this launcher.

## Limits and alternatives

[Codex's official Claude Code plugin](https://github.com/openai/codex-plugin-cc), [Agent Orchestrator](https://github.com/Augani/agent-orchestrator), and the Rust [codex-wrapper](https://github.com/joshrotenberg/codex-wrapper) cover related delegation or supervision needs. This package offers a small shell interface and inspectable local state, without a novelty or superiority claim.

Maintenance is best effort; rerun acceptance after changes. Acceptance tests wrapper behaviour against a stub Codex, not native Codex behaviour. Built with AI coding agents; tested as described in `ACCEPTANCE`. MIT licensed; see [LICENSE](LICENSE).
