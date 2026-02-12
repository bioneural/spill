<h1 align="center">
  s p i l l
  <br>
  <sub>centralized structured logging</sub>
</h1>

Seven tools write diagnostic output to stderr. Free-form text. No timestamps, no levels, no queryable structure. When something breaks at 3 AM, the only option is grep across scattered streams and hope the right line surfaces.

Spill replaces hope with structure. Every diagnostic message becomes a JSON line — timestamped, leveled, tagged by source tool — while the original stderr output is preserved unchanged. One log file. One place to look.

A single module. No gems. No external dependencies. Ruby stdlib only.

---

## How it works

```ruby
require '/path/to/spill/lib/spill'
Spill.configure(tool: 'crib')
Spill.info("stored entry #42", entry_id: 42)
Spill.error("sqlite3 error: #{msg}", command: 'sqlite3')
```

Each call does two things:
1. Writes `crib: stored entry #42` to stderr (unchanged from before)
2. Appends one JSON line to `.state/spill/spill.jsonl`

```json
{"ts":"2026-02-11T14:32:07.123Z","tool":"crib","level":"info","msg":"stored entry #42","pid":48291,"ctx":{"entry_id":42}}
```

If spill is not installed, tools fall back to plain stderr output. Nothing breaks.

---

## Schema

Every log entry is a single JSON object on one line (JSON Lines format).

| Field | Type | Required | Purpose |
|-------|------|----------|---------|
| `ts` | string | yes | ISO 8601 UTC with milliseconds (`2026-02-11T14:32:07.123Z`) |
| `tool` | string | yes | Source tool: `lay`, `crib`, `hooker`, `book`, `trick`, `classify`, `heartbeat`, `init` |
| `level` | string | yes | `debug`, `info`, `warn`, `error` |
| `msg` | string | yes | Human-readable diagnostic text |
| `pid` | integer | yes | Process ID — disambiguates concurrent writers |
| `ctx` | object | no | Structured context: `{"exit_code": 1}`, `{"entry_id": 42}`, etc. |

### Levels

| Level | When to use | Examples |
|-------|-------------|---------|
| `error` | Something broke | `sqlite3 error: table not found`, `ollama failed`, `classification failed` |
| `warn` | Degraded operation | `ollama not found`, `classify not found`, `context file not found` |
| `info` | Operational status | `stored entry #42`, `processing 5 turns`, `initialized crib.db` |
| `debug` | Tracing detail | Reserved for future use |

---

## CLI

```sh
# Last 20 entries, formatted with color
bin/spill tail

# Last 50 entries
bin/spill tail --lines 50

# Filter by tool
bin/spill search --tool hooker

# Filter by level
bin/spill search --level error

# Entries after a timestamp
bin/spill search --since 2026-02-11T00:00:00Z

# Grep the message field
bin/spill search --msg "sqlite3"

# Combine filters
bin/spill search --tool crib --level error --msg "sqlite3"

# Raw JSONL to stdout (pipe to jq, etc.)
bin/spill read

# Rotate the log file, keep 5 old copies (default)
bin/spill rotate

# Rotate, keep 3
bin/spill rotate --keep 3
```

Tail and search output is colorized by level: red for error, yellow for warn, green for info, cyan for debug. Each line shows timestamp, level, tool name, message, and any context fields.

Rotate moves the current log to a timestamped file (`spill-20260211-143207.jsonl`) and removes old rotated files beyond the keep count.

---

## Integration

### Ruby tools (lay, crib, book, trick, classify)

Each tool discovers spill as a sibling directory and loads it if present:

```ruby
SPILL_HOME = ENV['SPILL_HOME'] || File.expand_path('../../spill', __dir__)
if File.directory?(SPILL_HOME)
  require File.join(SPILL_HOME, 'lib', 'spill')
  Spill.configure(tool: 'crib')
end
```

Then replace stderr calls with level-appropriate methods:

```ruby
# Before
$stderr.puts "crib: sqlite3 error: #{stderr.strip}"

# After
defined?(Spill) ? Spill.error("sqlite3 error: #{stderr.strip}", command: 'sqlite3') : $stderr.puts("crib: sqlite3 error: #{stderr.strip}")
```

The guard pattern (`defined?(Spill) ? ... : ...`) ensures tools work identically whether spill is installed or not.

### hooker (inline)

Hooker cannot require external files, so a spill function is defined inline with the same schema and atomic append behavior:

```ruby
SPILL_LOG = ENV['SPILL_LOG'] || File.join(Dir.pwd, '.state', 'spill', 'spill.jsonl')

def spill(level, msg, **ctx)
  $stderr.puts "hooker: #{msg}"
  entry = { ts: Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%3NZ'),
            tool: 'hooker', level: level, msg: msg, pid: Process.pid }
  entry[:ctx] = ctx unless ctx.empty?
  FileUtils.mkdir_p(File.dirname(SPILL_LOG)) unless File.directory?(File.dirname(SPILL_LOG))
  File.open(SPILL_LOG, 'a') { |f| f.write(JSON.generate(entry) + "\n") }
rescue
  nil
end
```

### heartbeat (bash)

A bash function implements the same protocol:

```bash
spill() {
  local level="$1" msg="$2"
  echo "heartbeat: $msg" >&2
  local log="${SPILL_LOG:-.state/spill/spill.jsonl}"
  mkdir -p "$(dirname "$log")" 2>/dev/null
  printf '{"ts":"%s","tool":"heartbeat","level":"%s","msg":"%s","pid":%d}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" "$level" "$msg" "$$" >> "$log" 2>/dev/null || true
}
```

---

## Design

**Stderr preserved.** Every `Spill.error("msg")` call writes `tool: msg` to stderr before touching the log file. Claude Code hooks that read stderr continue to work. The structured log is additive — it never replaces the existing output path.

**Open-per-write.** Each log call opens the file, appends, and closes. No held file descriptor. Safe after log rotation. Safe for concurrent processes that share the same log path.

**POSIX atomic append.** `File.open(path, 'a')` uses `O_APPEND`. Single writes under PIPE_BUF (4096 bytes) are atomic — concurrent writers don't interleave partial lines. A JSON log entry is well under this limit.

**Fail-open.** If the log file can't be written (permissions, full disk, missing directory after manual deletion), the tool continues. Stderr already has the message. A logging failure never becomes a tool failure.

**Single destination.** All tools write to the same file: `.state/spill/spill.jsonl` in the working directory. One file to tail, search, rotate, and eventually feed to an agent for health monitoring.

**Auto-rotation.** When a log file exceeds `max_size` (default 1 MB), the next write renames it to a timestamped file (`spill-20260211-143207.jsonl`) and starts fresh. Old rotated files beyond the `keep` count (default 5) are deleted. Total disk usage stays bounded at roughly `(keep + 1) * max_size` — 6 MB with defaults. Rotation is size-based, not date-based. A log that never hits 1 MB never rotates.

Rotation is fail-open and race-safe. If two processes detect the threshold simultaneously, one rename succeeds and the other is silently rescued. The next write from either process creates a fresh log file.

### Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `SPILL_LOG` | `.state/spill/spill.jsonl` | Path to the log file |
| `SPILL_HOME` | `../../spill` (sibling directory) | Path to the spill repo (for `require`) |
| `SPILL_MAX_SIZE` | `1048576` (1 MB) | Rotate when log exceeds this size in bytes. Set to `0` to disable auto-rotation. |
| `SPILL_KEEP` | `5` | Number of rotated files to keep. Older files are deleted. |

---

## Smoke tests

```
$ test/smoke-test

Structure
  ✓ All expected paths exist
  ✓ All scripts are executable

Syntax
  ✓ Ruby scripts pass syntax check

Logging
  ✓ stderr output preserves tool: msg format
  ✓ Log file has 4 entries (one per level)
  ✓ All log entries are valid JSON
  ✓ All entries have required fields (ts, tool, level, msg, pid)
  ✓ ctx field present when kwargs given, absent when not
  ✓ Timestamp is ISO 8601 UTC with milliseconds

Fail-open
  ✓ Fail-open: stderr works when log path is unreachable
  ✓ Unconfigured tool defaults to 'unknown'

Concurrent writes
  ✓ Concurrent writes: 50 entries from 5 workers
  ✓ Concurrent writes: all entries are valid JSON

CLI — bin/spill
  ✓ bin/spill tail --lines 2 shows 2 entries
  ✓ bin/spill search --tool --level filters correctly
  ✓ bin/spill search --msg filters by message content
  ✓ bin/spill read outputs raw JSONL
  ✓ bin/spill rotate moves log to timestamped file

Auto-rotation
  ✓ Auto-rotation triggers when log exceeds max_size
  ✓ Current log is under max_size after rotation
  ✓ Culling keeps at most 2 rotated files
  ✓ Auto-rotation disabled when max_size is 0

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
22 passed
```

Tests run against a temporary directory that is created and destroyed on each run. No artifacts are left behind.

---

## Prerequisites

- Ruby 3.x

---

## License

MIT
