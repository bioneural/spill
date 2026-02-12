# lib/spill.rb — centralized structured logging
#
# Usage:
#   require '/path/to/spill/lib/spill'
#   Spill.configure(tool: 'crib')
#   Spill.info("stored entry #42", entry_id: 42)
#   Spill.error("sqlite3 error: #{msg}", command: 'sqlite3')
#
# Schema (SQLite table):
#   log(id, ts, tool, level, msg, pid, ctx)
#   Indexes on ts, tool, level, and (tool, level)
#
# Behavior:
#   - INSERTs one row per call into a SQLite database
#   - Also writes to $stderr in existing format (tool: message)
#   - Uses WAL journal mode for concurrent writer safety
#   - Creates .state/spill/ and initializes schema on demand
#   - Auto-culls oldest 50% of entries when database exceeds max_size (default 10 MB)
#   - Fail-open: if database write or culling fails, stderr still works
#
# Dependencies: ruby stdlib (json, fileutils, open3), sqlite3 CLI

require 'json'
require 'fileutils'
require 'open3'

module Spill
  INIT_SQL = <<~SQL.freeze
    PRAGMA journal_mode = WAL;
    CREATE TABLE IF NOT EXISTS log (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      ts TEXT NOT NULL,
      tool TEXT NOT NULL,
      level TEXT NOT NULL,
      msg TEXT NOT NULL,
      pid INTEGER NOT NULL,
      ctx TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_log_ts ON log(ts);
    CREATE INDEX IF NOT EXISTS idx_log_tool ON log(tool);
    CREATE INDEX IF NOT EXISTS idx_log_level ON log(level);
    CREATE INDEX IF NOT EXISTS idx_log_tool_level ON log(tool, level);
  SQL

  @tool = 'unknown'
  @db_path = nil
  @max_size = 10_485_760
  @initialized = false

  module_function

  def configure(tool:, db: nil, max_size: nil)
    @tool = tool
    @db_path = db || ENV.fetch('SPILL_DB') {
      File.join(Dir.pwd, '.state', 'spill', 'spill.db')
    }
    @max_size = max_size || ENV.fetch('SPILL_MAX_SIZE', 10_485_760).to_i
    @initialized = false
  end

  def info(msg, **ctx)  ; _log('info', msg, ctx)  end
  def warn(msg, **ctx)  ; _log('warn', msg, ctx)  end
  def error(msg, **ctx) ; _log('error', msg, ctx) end
  def debug(msg, **ctx) ; _log('debug', msg, ctx) end

  def _log(level, msg, ctx)
    $stderr.puts "#{@tool}: #{msg}"
    return unless @db_path

    _init_db unless @initialized

    ts = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%3NZ')
    ctx_sql = ctx.empty? ? 'NULL' : "'#{_esc(JSON.generate(ctx))}'"
    sql = "INSERT INTO log (ts,tool,level,msg,pid,ctx) VALUES (" \
      "'#{ts}','#{_esc(@tool)}','#{_esc(level)}'," \
      "'#{_esc(msg)}',#{Process.pid},#{ctx_sql});"

    _sql(sql)
    _maybe_cull
  rescue
    # fail-open: stderr already has the message
  end

  def _init_db
    dir = File.dirname(@db_path)
    FileUtils.mkdir_p(dir) unless File.directory?(dir)
    _sql(INIT_SQL)
    @initialized = true
  rescue
    # fail-open
  end

  def _sql(sql)
    Open3.capture2('sqlite3', @db_path,
      stdin_data: "PRAGMA busy_timeout = 5000;\n#{sql}", err: File::NULL)
  end

  def _esc(str)
    str.to_s.gsub("'", "''")
  end

  def _maybe_cull
    return unless @db_path && @max_size > 0
    return unless File.exist?(@db_path)
    return unless _db_size >= @max_size

    _sql("DELETE FROM log WHERE id IN " \
      "(SELECT id FROM log ORDER BY id ASC LIMIT " \
      "(SELECT COUNT(*) / 2 FROM log)); VACUUM;")
  rescue
    # fail-open: culling failure never breaks the tool
  end

  def _db_size
    size = File.size(@db_path) rescue 0
    wal = "#{@db_path}-wal"
    size += (File.size(wal) rescue 0)
    size
  end

  private_class_method :_log, :_init_db, :_sql, :_esc, :_maybe_cull, :_db_size
end
