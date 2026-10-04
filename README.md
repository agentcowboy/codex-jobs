# codex-jobs

A small shell supervisor for Codex jobs, with saved results and a terminal viewer. Compared with running `codex exec` directly, it adds a saved receipt, whole-group cancellation and a live viewer. [Codex](https://learn.chatgpt.com/docs/codex/cli) is OpenAI's coding agent for the terminal: it can read your code, make changes and run commands. Install and sign in to Codex separately before running a real job.

## Install

Requirements: Linux, Bash 4.4+, Python 3.7+, git, coreutils, util-linux `setsid`, and [Rich](https://github.com/Textualize/rich). The optional tmux watcher requires tmux 3.0a or newer. On Debian/Ubuntu, install `python3-venv` if creating a venv reports that it is unavailable.

```bash
git clone https://github.com/agentcowboy/codex-jobs.git && cd codex-jobs
python3 -m venv .venv
. .venv/bin/activate
python3 -m pip install -r requirements.txt
export PATH="$PWD/bin:$PATH"
```

Activate this venv before using `codex-view` or `codex-watcher`. You can also run `.venv/bin/python3 bin/codex-view`; for the watcher, put `.venv/bin` on `PATH`.

## Quick start

Choose a `MODEL` using `/model` in interactive Codex. For `EFFORT`, see the [`model_reasoning_effort` configuration setting](https://learn.chatgpt.com/docs/config-file/config-reference) (supported levels depend on the model and client), then run this in the first terminal:

```bash
MODEL='replace-with-your-model'
EFFORT='replace-with-supported-effort'
JOB_DIR=$(mktemp -d)
git -C "$JOB_DIR" init -q
cd "$JOB_DIR"
printf 'Describe this repository in one sentence.\n' > prompt.txt
codex-hands --cwd "$PWD" "$MODEL" "$EFFORT" prompt.txt answer.txt run.jsonl
cat answer.txt answer.txt.done
```

In a second terminal, from the cloned `codex-jobs` directory:

```bash
. .venv/bin/activate
export PATH="$PWD/bin:$PATH"
codex-view
```

The viewer lists active jobs while they run. Press `q` to quit. A finished job leaves the live list; inspect its answer and receipt in the first terminal, or use `codex-view --log /path/to/run.jsonl` to view its saved events. If Codex fails, check `answer.txt.failed`, `run.jsonl.stderr` and `codex-view --log run.jsonl`.

## Run and resume

```text
codex-hands --cwd DIR [--sandbox read-only|workspace-write] MODEL EFFORT PROMPT-FILE OUT-FILE [RUNLOG]
codex-hands resume --cwd DIR [--sandbox read-only|workspace-write] SESSION MODEL EFFORT PROMPT-FILE OUT-FILE [RUNLOG]
```

`DIR` must be inside a git repository. Jobs use `read-only` by default and never request approval. Use `--sandbox workspace-write` to allow changes in the repository. Codex decides model availability and effort compatibility. `CODEX_BIN` selects one executable, defaulting to `codex` on `PATH`. Codex configuration and authentication apply normally.

`SESSION` is the Codex thread id recorded in the run log, distinct from the viewer's local `job_id`. From the quick-start scratch directory, extract it and resume:

```bash
SESSION=$(python3 -I -c 'import json,sys; session=next((e["thread_id"] for e in map(json.loads, open(sys.argv[1])) if e.get("type")=="thread.started"), None); sys.exit("no thread.started event yet in "+sys.argv[1]) if session is None else print(session)' run.jsonl)
printf 'Suggest one useful first file for this repository.\n' > follow-up-prompt.txt
codex-hands resume --cwd "$PWD" "$SESSION" "$MODEL" "$EFFORT" follow-up-prompt.txt follow-up.txt
```

## Artifacts and cancellation

`OUT-FILE` holds the final message; `RUNLOG` defaults to `OUT-FILE.jsonl` and holds the JSON events. `RUNLOG.stderr` holds diagnostics. Relative prompt and artifact paths refer to the caller's directory. Use distinct artifact paths for concurrent jobs.

Use a readable regular prompt, distinct regular artifact paths with existing parents, no control characters in paths, and no artifact symlinks.

A retry removes the prior receipt and moves existing output, log and diagnostics to `.prev`, replacing earlier `.prev` files. A nonzero exit moves the new output to `OUT-FILE.failed`, replacing an earlier `.failed` file. A successful retry can leave an earlier `.failed` file in place.

`OUT-FILE.done` contains `rc`, `started_at` and `ended_at`. It records process success or failure; it does not judge answer quality. A missing receipt means no finalized result. The wrapper returns Codex's exit status, or 2 for usage errors, missing Codex, python3 or setsid, or unavailable prompts or artifact directories; path refusals (aliases, symlinks, non-regular files or control characters) and launch-handshake or group-ownership failures return 1; other setup failures return the failing command's status. New artifacts and receipts are private (0600); files Codex creates in the repository follow the caller's umask unless a directory default ACL overrides it. Existing and rotated files retain their permissions.

Cancel a foreground job with Ctrl-C or Ctrl-\, or send TERM to the saved wrapper PID. HUP also cancels unless ignored; `nohup` ignores HUP. INT only works when the calling shell has not made the background process ignore it. Cancellation sends TERM to the job group, waits 10 seconds, then sends KILL; it returns 128+signal without a receipt. After Codex exits, remaining group processes get TERM and, if still present, KILL after 10 seconds. Detached processes, SIGKILL and parent crashes are outside the cancellation guarantee.

```bash
nohup codex-hands --cwd "$PWD" "$MODEL" "$EFFORT" prompt.txt answer.txt run.jsonl > supervisor.log 2>&1 &
job_pid=$!
# Cancel if needed: kill -TERM "$job_pid"
```

## Viewer and tmux watcher

The default registry is `${XDG_STATE_HOME:-$HOME/.local/state}/codex-jobs/active`. A registry failure warns without failing the job. SIGKILL can leave a stale entry; remove it manually once it is marked stale.

```bash
codex-view --registry /path/to/registry
codex-view --log /path/to/run.jsonl
codex-view --once --log /path/to/run.jsonl
```

`--registry` selects another registry directory. `--log` follows one saved log; it cannot be combined with `--registry`. Reaching the end of a log does not mean the turn completed. `j`/`k` or Tab changes focus; `q` quits.

Rows show job identity, turn status and input status:

| State | Meaning |
| --- | --- |
| `active` | The registered job is still present. |
| `stale` | The registered job is gone or its identity changed. |
| `unknown` | Job identity cannot be checked, or a standalone log is selected. |
| `waiting` | No thread or turn has started yet. |
| `running` | Codex has started a thread or turn. |
| `failed` | A turn failure or error was reported. |
| `completed` | The latest turn completed. |
| `completed (earlier error)` | A later turn completed after an earlier error; error detail remains visible. |
| `available` / `empty` | Input is present with data / without data. |
| `unavailable` | The registry or log is absent. |
| `unreadable` | Input cannot be read as a regular file. |
| `malformed` | This refresh read invalid input; earlier malformed log records can remain in detail. |

Command-output bodies are omitted from detail. Command strings, reasoning, messages, logs and final answers may contain sensitive content; protect these local files.

Inside tmux:

```bash
codex-watcher start
# Later, close the viewer pane:
codex-watcher stop
```

`start` creates or reuses a viewer pane in the caller's window, replacing a dead viewer pane. `stop` removes marked viewer panes in that window and preserves the caller, unmarked panes and other windows. Reserve `@codex-jobs-view=1` for watcher panes. A new viewer uses the caller's Python and registry; a reused viewer keeps its original settings. Missing tmux, viewer or Rich is reported as an error.

`start` does not check that the viewer started. A failed viewer stays visible in its pane without changing other panes' exit behavior. For debugging, run `codex-view` directly.

Quitting the viewer leaves its pane open; `codex-watcher stop` closes it.

## Run the tests

Acceptance requires tmux, the dependencies above, and Linux `/proc` with readable process-child listings (`CONFIG_PROC_CHILDREN`). From the cloned directory:

```bash
python3 -m venv .venv
. .venv/bin/activate
python3 -m pip install -r requirements.txt
bash ACCEPTANCE
```

After installation, tests need no network, credentials or Codex installation. They run 34 runner cases, 30 viewer cases and 6 watcher cases on an isolated tmux server. Acceptance takes about a minute. Temporary storage (`TMPDIR`, default `/tmp`) must permit executing scripts. Acceptance works from another directory by absolute path. Success prints exactly:

```text
CODEX_JOBS TESTS cases=70 passed=70 failures=0 skips=0
CODEX_JOBS ACCEPTANCE PASS
```

Acceptance tests wrapper behavior against a synthetic Codex, not real Codex permission or resume behavior. Maintenance is best effort; rerun acceptance after changes. MIT licensed; see [LICENSE](LICENSE).

- v0.1.3: Correct the quick-start model and reasoning-effort pointers.
