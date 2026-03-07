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
# Dependencies: ruby stdlib (json, fileutils), sqlite3 gem

require 'json'
require 'fileutils'
require 'sqlite3'

module Spill
  LEVELS = %w[debug info warn error].freeze
  LEVEL_RANK = LEVELS.each_with_index.to_h.freeze  # {"debug"=>0, "info"=>1, ...}

  @tool = 'unknown'
  @db_path = nil
  @db = nil
  @max_size = 10_485_760
  @initialized = false
  @min_level = LEVEL_RANK['info']

  module_function

  def configure(tool:, db: nil, max_size: nil, level: nil)
    @tool = tool
    @db_path = db || ENV.fetch('SPILL_DB') {
      File.join(Dir.pwd, '.state', 'spill', 'spill.db')
    }
    @max_size = max_size || ENV.fetch('SPILL_MAX_SIZE', 10_485_760).to_i
    @min_level = LEVEL_RANK.fetch(level.to_s, LEVEL_RANK['info'])
    @db&.close rescue nil
    @db = nil
    @initialized = false
  end

  def info(msg, **ctx)  ; _log('info', msg, ctx)  end
  def warn(msg, **ctx)  ; _log('warn', msg, ctx)  end
  def error(msg, **ctx) ; _log('error', msg, ctx) end
  def debug(msg, **ctx) ; _log('debug', msg, ctx) end

  def _log(level, msg, ctx)
    rank = LEVEL_RANK.fetch(level, 0)
    if rank >= @min_level
      $stderr.puts "#{@tool}: #{msg}"
    end
    return unless @db_path

    _init_db unless @initialized

    ts = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%3NZ')
    ctx_val = ctx.empty? ? nil : JSON.generate(ctx)
    @db.execute(
      'INSERT INTO log (ts, tool, level, msg, pid, ctx) VALUES (?, ?, ?, ?, ?, ?)',
      [ts, @tool, level, msg, Process.pid, ctx_val]
    )
    _maybe_cull
  rescue
    # fail-open: stderr already has the message
  end

  def _init_db
    dir = File.dirname(@db_path)
    FileUtils.mkdir_p(dir) unless File.directory?(dir)
    @db = SQLite3::Database.new(@db_path)
    @db.busy_timeout = 5000
    @db.journal_mode = 'wal'
    @db.execute_batch(<<~SQL)
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
    @initialized = true
  rescue
    # fail-open
  end

  def _maybe_cull
    return unless @db_path && @max_size > 0
    return unless File.exist?(@db_path)
    return unless _db_size >= @max_size

    @db.execute_batch(<<~SQL)
      DELETE FROM log WHERE id IN
        (SELECT id FROM log ORDER BY id ASC LIMIT
        (SELECT COUNT(*) / 2 FROM log));
      VACUUM;
    SQL
  rescue
    # fail-open: culling failure never breaks the tool
  end

  def _db_size
    size = File.size(@db_path) rescue 0
    wal = "#{@db_path}-wal"
    size += (File.size(wal) rescue 0)
    size
  end

  private_class_method :_log, :_init_db, :_maybe_cull, :_db_size
end
