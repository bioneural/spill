# lib/spill.rb — centralized structured logging
#
# Usage:
#   require '/path/to/spill/lib/spill'
#   Spill.configure(tool: 'crib')
#   Spill.info("stored entry #42", entry_id: 42)
#   Spill.error("sqlite3 error: #{msg}", command: 'sqlite3')
#
# Schema (JSON Lines, one object per line):
#   { "ts": "ISO8601Z", "tool": "name", "level": "info|warn|error|debug",
#     "msg": "text", "pid": 12345, "ctx": {} }
#
# Behavior:
#   - Writes one JSON line per call to the configured log file
#   - Also writes to $stderr in existing format (tool: message)
#   - Opens file O_APPEND per write — no held fd, safe for concurrent processes
#   - POSIX atomic append: lines under PIPE_BUF (4096) don't interleave
#   - Creates .state/spill/ on demand
#   - Auto-rotates when log exceeds max_size (default 1 MB)
#   - Culls old rotated files beyond keep count (default 5)
#   - Fail-open: if log write or rotation fails, stderr still works
#
# Dependencies: ruby stdlib (json, fileutils)

require 'json'
require 'fileutils'

module Spill
  @tool = 'unknown'
  @log_path = nil
  @max_size = 1_048_576
  @keep = 5

  module_function

  def configure(tool:, log: nil, max_size: nil, keep: nil)
    @tool = tool
    @log_path = log || ENV.fetch('SPILL_LOG') {
      File.join(Dir.pwd, '.state', 'spill', 'spill.jsonl')
    }
    @max_size = max_size || ENV.fetch('SPILL_MAX_SIZE', 1_048_576).to_i
    @keep = keep || ENV.fetch('SPILL_KEEP', 5).to_i
  end

  def info(msg, **ctx)  ; _log('info', msg, ctx)  end
  def warn(msg, **ctx)  ; _log('warn', msg, ctx)  end
  def error(msg, **ctx) ; _log('error', msg, ctx) end
  def debug(msg, **ctx) ; _log('debug', msg, ctx) end

  def _log(level, msg, ctx)
    $stderr.puts "#{@tool}: #{msg}"
    return unless @log_path

    entry = {
      ts: Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%3NZ'),
      tool: @tool, level: level, msg: msg, pid: Process.pid
    }
    entry[:ctx] = ctx unless ctx.empty?

    line = JSON.generate(entry) + "\n"
    begin
      dir = File.dirname(@log_path)
      FileUtils.mkdir_p(dir) unless File.directory?(dir)
      File.open(@log_path, 'a') { |f| f.write(line) }
    rescue
      # fail-open: stderr already has the message
    end

    _maybe_rotate
  end

  def _maybe_rotate
    return unless @log_path && @max_size > 0
    return unless File.exist?(@log_path)
    return unless File.size(@log_path) >= @max_size

    dir = File.dirname(@log_path)
    base = File.basename(@log_path, '.jsonl')
    ts = Time.now.utc.strftime('%Y%m%d-%H%M%S')
    rotated = File.join(dir, "#{base}-#{ts}.jsonl")

    File.rename(@log_path, rotated)

    # Cull old rotated files
    old = Dir.glob(File.join(dir, "#{base}-*.jsonl")).sort
    if old.length > @keep
      old[0...(old.length - @keep)].each { |f| File.delete(f) }
    end
  rescue
    # fail-open: rotation failure never breaks the tool
    # Race condition (two processes rotating simultaneously) lands here safely
  end

  private_class_method :_log, :_maybe_rotate
end
