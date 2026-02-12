<h1 align="center">
  s p i l l
  <br>
  <sub>structured logging for the prophet ecosystem</sub>
</h1>

Scattered stderr. Free-form text. No timestamps, no levels, no queryable structure. When an agent needs to understand what happened across seven repos, grep is not a strategy.

Spill centralizes diagnostic output into one structured log. Every tool in the ecosystem writes JSON Lines to a single file. Stderr output is preserved unchanged. The structured log is additive.

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

---

## Schema

| Field | Type | Required | Purpose |
|-------|------|----------|---------|
| `ts` | string | yes | ISO 8601 UTC with milliseconds |
| `tool` | string | yes | Source tool name |
| `level` | string | yes | `debug`, `info`, `warn`, `error` |
| `msg` | string | yes | Human-readable text |
| `pid` | integer | yes | Process ID |
| `ctx` | object | no | Structured context |

---

## CLI

```sh
bin/spill tail                          # last 20 entries, formatted
bin/spill tail --lines 50              # last 50
bin/spill search --tool hooker         # filter by tool
bin/spill search --level error         # filter by level
bin/spill search --since 2026-02-11T00:00:00Z
bin/spill search --msg "sqlite3"       # grep message field
bin/spill read                         # raw JSONL to stdout
bin/spill rotate                       # rotate log, keep 5 old files
bin/spill rotate --keep 3
```

---

## Integration

Tools that can require external files:

```ruby
SPILL_HOME = ENV['SPILL_HOME'] || File.expand_path('../../spill', __dir__)
require File.join(SPILL_HOME, 'lib', 'spill') if File.directory?(SPILL_HOME)
Spill.configure(tool: 'crib') if defined?(Spill)
```

If spill is absent, tools work exactly as before.

---

## Design

**Stderr preserved.** `Spill.error("msg")` writes `tool: msg` to stderr. Claude Code hooks still capture it. The structured log is additive.

**Open-per-write.** No held file descriptor. Safe after rotation. Safe for concurrent processes.

**POSIX atomic append.** `File.open(path, 'a')` uses `O_APPEND`. Lines under 4096 bytes don't interleave.

**Fail-open.** Log write failure does not break the tool. Stderr always works.

---

## Prerequisites

- Ruby 3.x

## License

MIT
