<h1 align="center">
  s p i l l
  <br>
  <sub>centralized structured logging</sub>
</h1>

Seven tools write diagnostic output to stderr. Free-form text. No timestamps, no levels, no queryable structure. When something breaks at 3 AM, the only option is grep across scattered streams and hope the right line surfaces.

Spill replaces hope with structure. Every diagnostic message becomes a row in a SQLite database — timestamped, leveled, tagged by source tool, indexed for queries — while the original stderr output is preserved unchanged. One database. One place to look.

A single module. No gems. No external dependencies. Ruby stdlib and sqlite3 only.

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
2. INSERTs a row into `.state/spill/spill.db`

If spill is not installed, tools fall back to plain stderr output. Nothing breaks.

---

## Schema

A single table with indexes for the most common query patterns.

```sql
CREATE TABLE log (
  id    INTEGER PRIMARY KEY AUTOINCREMENT,
  ts    TEXT NOT NULL,       -- ISO 8601 UTC with milliseconds
  tool  TEXT NOT NULL,       -- source tool name
  level TEXT NOT NULL,       -- debug, info, warn, error
  msg   TEXT NOT NULL,       -- human-readable diagnostic text
  pid   INTEGER NOT NULL,    -- process ID
  ctx   TEXT                 -- JSON context, NULL when empty
);

CREATE INDEX idx_log_ts    ON log(ts);
CREATE INDEX idx_log_tool  ON log(tool);
CREATE INDEX idx_log_level ON log(level);
CREATE INDEX idx_log_tool_level ON log(tool, level);
```

| Column | Type | Purpose |
|--------|------|---------|
| `ts` | TEXT | `2026-02-11T14:32:07.123Z` |
| `tool` | TEXT | `lay`, `crib`, `hooker`, `book`, `trick`, `classify`, `heartbeat`, `init` |
| `level` | TEXT | `debug`, `info`, `warn`, `error` |
| `msg` | TEXT | Diagnostic text |
| `pid` | INTEGER | Disambiguates concurrent writers |
| `ctx` | TEXT | JSON object or NULL: `{"exit_code": 1}`, `{"entry_id": 42}` |

### Levels

| Level | When to use | Examples |
|-------|-------------|---------|
| `error` | Something broke | `sqlite3 error: table not found`, `ollama failed` |
| `warn` | Degraded operation | `ollama not found`, `context file not found` |
| `info` | Operational status | `stored entry #42`, `processing 5 turns` |
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

# Delete oldest 50% of entries and vacuum
bin/spill cull
```

Tail and search output is colorized by level: red for error, yellow for warn, green for info, cyan for debug. Each line shows timestamp, level, tool name, message, and any context fields.

The `read` command outputs one JSON object per line (JSONL format) for piping to external tools.

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

Hooker cannot require external files, so a spill function is defined inline. It writes directly to the SQLite database via the sqlite3 CLI:

```ruby
SPILL_DB = ENV['SPILL_DB'] || File.join(Dir.pwd, '.state', 'spill', 'spill.db')
@spill_db_ready = false

def spill(level, msg, **ctx)
  $stderr.puts "hooker: #{msg}"
  unless @spill_db_ready
    # Create table on first call
    Open3.capture2('sqlite3', SPILL_DB, stdin_data: <<~SQL, err: File::NULL)
      PRAGMA busy_timeout = 5000;
      PRAGMA journal_mode = WAL;
      CREATE TABLE IF NOT EXISTS log (
        id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT NOT NULL,
        tool TEXT NOT NULL, level TEXT NOT NULL, msg TEXT NOT NULL,
        pid INTEGER NOT NULL, ctx TEXT
      );
    SQL
    @spill_db_ready = true
  end
  ts = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%3NZ')
  escaped = msg.gsub("'", "''")
  ctx_sql = ctx.empty? ? 'NULL' : "'#{JSON.generate(ctx).gsub("'", "''")}'"
  Open3.capture2('sqlite3', SPILL_DB, stdin_data:
    "PRAGMA busy_timeout = 5000; INSERT INTO log (ts,tool,level,msg,pid,ctx) " \
    "VALUES ('#{ts}','hooker','#{level}','#{escaped}',#{Process.pid},#{ctx_sql});",
    err: File::NULL)
rescue
  nil
end
```

### heartbeat (bash)

A bash function writes directly to the SQLite database:

```bash
SPILL_DB="${SPILL_DB:-.state/spill/spill.db}"

spill() {
  local level="$1" msg="$2"
  echo "heartbeat: $msg" >&2
  mkdir -p "$(dirname "$SPILL_DB")" 2>/dev/null
  if [[ ! -f "$SPILL_DB" ]]; then
    sqlite3 "$SPILL_DB" "PRAGMA busy_timeout=5000; PRAGMA journal_mode=WAL; \
      CREATE TABLE IF NOT EXISTS log (id INTEGER PRIMARY KEY AUTOINCREMENT, \
      ts TEXT NOT NULL, tool TEXT NOT NULL, level TEXT NOT NULL, \
      msg TEXT NOT NULL, pid INTEGER NOT NULL, ctx TEXT);" 2>/dev/null || true
  fi
  local ts escaped_msg
  ts="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  escaped_msg="${msg//\'/\'\'}"
  sqlite3 "$SPILL_DB" "PRAGMA busy_timeout=5000; INSERT INTO log \
    (ts,tool,level,msg,pid,ctx) VALUES \
    ('$ts','heartbeat','$level','$escaped_msg',$$,NULL);" 2>/dev/null || true
}
```

---

## Design

**Stderr preserved.** Every `Spill.error("msg")` call writes `tool: msg` to stderr before touching the database. Claude Code hooks that read stderr continue to work. The structured log is additive — it never replaces the existing output path.

**SQLite storage.** Entries are rows in a WAL-mode SQLite database, not lines in a flat file. This enables indexed queries by tool, level, timestamp, and message content without reading the entire log. The database handles concurrent writes natively — WAL mode with a 5-second busy timeout ensures multiple processes can log simultaneously without data loss.

**Fail-open.** If the database can't be written (permissions, full disk, missing sqlite3), the tool continues. Stderr already has the message. A logging failure never becomes a tool failure.

**Auto-culling.** When a database exceeds `max_size` (default 10 MB), the next write deletes the oldest 50% of entries and runs VACUUM to reclaim space. Total disk usage stays bounded. With defaults, the database holds roughly 50,000–100,000 entries — months of diagnostic history. Set `max_size` to `0` to disable auto-culling entirely.

**Single destination.** All tools write to the same database: `.state/spill/spill.db` in the working directory. One file to query, cull, and eventually feed to an agent for health monitoring.

### Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `SPILL_DB` | `.state/spill/spill.db` | Path to the database file |
| `SPILL_HOME` | `../../spill` (sibling directory) | Path to the spill repo (for `require`) |
| `SPILL_MAX_SIZE` | `10485760` (10 MB) | Cull when database exceeds this size in bytes. Set to `0` to disable. |

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
  ✓ Database has 4 entries (one per level)
  ✓ Schema has all expected columns
  ✓ All indexes present (found 4)
  ✓ All entries have required fields populated
  ✓ ctx field present when kwargs given, absent when not
  ✓ Timestamp is ISO 8601 UTC with milliseconds
  ✓ Database uses WAL journal mode

Fail-open
  ✓ Fail-open: stderr works when database path is unreachable
  ✓ Unconfigured tool defaults to 'unknown'

Concurrent writes
  ✓ Concurrent writes: 50 entries from 5 workers
  ✓ Concurrent writes: all entries have valid data

CLI — bin/spill
  ✓ bin/spill tail --lines 2 shows 2 entries
  ✓ bin/spill search --tool --level filters correctly
  ✓ bin/spill search --msg filters by message content
  ✓ bin/spill read outputs 4 JSONL lines
  ✓ bin/spill read outputs valid JSON per line
  ✓ bin/spill cull removes oldest 50% of entries

Auto-culling
  ✓ Auto-culling reduced entries
  ✓ Auto-culling disabled when max_size is 0

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
23 passed
```

Tests run against a temporary directory that is created and destroyed on each run. No artifacts are left behind.

---

## Prerequisites

- Ruby 3.x
- sqlite3 CLI

---

## License

MIT
