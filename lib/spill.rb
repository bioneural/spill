# lib/spill.rb — structured logging for autonomous agent tooling
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
#   - Fail-open: if log write fails, stderr still works
#
# Dependencies: ruby stdlib (json, fileutils)

require 'json'
require 'fileutils'

module Spill
  @tool = 'unknown'
  @log_path = nil

  module_function

  def configure(tool:, log: nil)
    @tool = tool
    @log_path = log || ENV.fetch('SPILL_LOG') {
      File.join(Dir.pwd, '.state', 'spill', 'spill.jsonl')
    }
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
  end

  private_class_method :_log
end
