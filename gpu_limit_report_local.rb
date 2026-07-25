#!/usr/bin/env ruby
# frozen_string_literal: true

require 'csv'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'time'

class CommandRunner
  def run!(*command)
    output, status = Open3.capture2e(*command)
    raise "Command failed: #{command.join(' ')}\n#{output}" unless status.success?
    output
  end

  def run(*command)
    Open3.capture2e(*command).first
  rescue StandardError
    ''
  end
end

class SystemProbe
  FALLBACK_PAGE_SIZE = 16 * 1024

  def initialize(command_runner:)
    @command_runner = command_runner
  end

  def current_wired_limit_mb
    Integer(@command_runner.run!('sysctl -n iogpu.wired_limit_mb').strip)
  end

  def set_wired_limit_mb(limit_mb)
    @command_runner.run!('sudo', 'sysctl', "iogpu.wired_limit_mb=#{limit_mb}")
    actual_limit_mb = current_wired_limit_mb
    return if actual_limit_mb == limit_mb

    raise "Requested iogpu.wired_limit_mb=#{limit_mb}, but read back #{actual_limit_mb}"
  end

  def total_ram_mb
    bytes = Integer(@command_runner.run!('sysctl -n hw.memsize').strip)
    bytes / 1024.0 / 1024.0
  end

  def sample(limit_mb)
    stats, page_size = vm_stats
    pressure = memory_pressure_snapshot
    swap = swap_usage

    {
      timestamp: Time.now.iso8601,
      limit_mb: limit_mb,
      wired_mb: pages_to_mb(stats['Pages wired down'] || 0, page_size),
      compressed_mb: pages_to_mb(stats['Pages occupied by compressor'] || 0, page_size),
      swap_used_mb: swap[:used_mb],
      swap_total_mb: swap[:total_mb],
      available_percent: pressure[:available_percent],
      free_mb: pages_to_mb(stats['Pages free'] || 0, page_size) + pages_to_mb(stats['Pages speculative'] || 0, page_size),
      active_mb: pages_to_mb(stats['Pages active'] || 0, page_size),
      inactive_mb: pages_to_mb(stats['Pages inactive'] || 0, page_size),
      purgeable_mb: pages_to_mb(stats['Pages purgeable'] || 0, page_size),
      throttled_mb: pages_to_mb(stats['Pages throttled'] || 0, page_size),
      swapouts: pressure[:swapouts],
      pageouts: pressure[:pageouts],
    }
  end

  private

  def vm_stats
    output = @command_runner.run!('vm_stat')
    stats = {}
    page_size = output[/page size of (\d+) bytes/i, 1]&.to_i || FALLBACK_PAGE_SIZE

    output.each_line do |line|
      next unless line.include?(':')
      key, value = line.split(':', 2)
      stats[key.strip] = value.gsub(/[^\d]/, '').to_i
    end

    [stats, page_size]
  end

  def swap_usage
    output = @command_runner.run!('sysctl vm.swapusage')
    total = output[/total = ([\d.]+)([MG])/, 1]
    total_unit = output[/total = ([\d.]+)([MG])/, 2]
    used = output[/used = ([\d.]+)([MG])/, 1]
    used_unit = output[/used = ([\d.]+)([MG])/, 2]

    {
      total_mb: total ? (total_unit == 'G' ? total.to_f * 1024.0 : total.to_f) : 0.0,
      used_mb: used ? (used_unit == 'G' ? used.to_f * 1024.0 : used.to_f) : 0.0
    }
  end

  def memory_pressure_snapshot
    output = @command_runner.run('memory_pressure')
    snapshot = { available_percent: nil, swapouts: nil, pageouts: nil }

    snapshot[:available_percent] = output[/System-wide memory free percentage:\s*(\d+)%/i, 1]&.to_i
    snapshot[:swapouts] = output[/Swapouts:\s*(\d+)/i, 1]&.to_i
    snapshot[:pageouts] = output[/Pageouts:\s*(\d+)/i, 1]&.to_i

    snapshot
  rescue StandardError
    { available_percent: nil, swapouts: nil, pageouts: nil }
  end

  def pages_to_mb(pages, page_size)
    (pages * page_size) / 1024.0 / 1024.0
  end
end

class SampleAnalyzer
  METRIC_KEYS = %i[wired_mb compressed_mb swap_used_mb available_percent free_mb active_mb inactive_mb purgeable_mb throttled_mb].freeze
  VALID_WORKLOAD_STATUSES = %w[completed duration-reached].freeze

  def summarize(limit_mb, samples)
    summary = { limit_mb: limit_mb, samples: samples.length }

    METRIC_KEYS.each do |key|
      values = samples.map { |sample| sample[key] }.compact.sort
      next if values.empty?

      summary["#{key}_min".to_sym] = values.first
      summary["#{key}_avg".to_sym] = values.sum / values.length
      summary["#{key}_p95".to_sym] = percentile(values, 0.95)
      summary["#{key}_max".to_sym] = values.last
      summary["#{key}_start".to_sym] = samples.first[key]
      summary["#{key}_end".to_sym] = samples.last[key]
    end

    %i[swapouts pageouts].each do |key|
      values = samples.map { |sample| sample[key] }.compact
      summary["#{key}_start".to_sym] = values.first
      summary["#{key}_end".to_sym] = values.last
      summary["#{key}_delta".to_sym] = counter_delta(values)
    end

    summary[:swap_used_mb_peak_delta] = positive_delta(summary[:swap_used_mb_max], summary[:swap_used_mb_start])
    summary[:compressed_mb_peak_delta] = positive_delta(summary[:compressed_mb_max], summary[:compressed_mb_start])

    assess(summary)

    summary
  end

  def assess(summary)
    apply_assessment!(summary)
    apply_stability_score!(summary)
    summary
  end

  def recommendation(summaries)
    eligible = summaries.select { |summary| valid_workload?(summary) && complete_pressure_metrics?(summary) }
    stable = eligible.select { |summary| stable?(summary) }
    candidate = stable.max_by { |summary| summary[:limit_mb] }
    return nil unless candidate

    {
      limit_mb: candidate[:limit_mb],
      rationale: 'highest pressure-stable tested limit',
      assessment: candidate[:assessment],
      stability_score: candidate[:stability_score]
    }
  end

  private

  def percentile(sorted_values, percentile_value)
    return nil if sorted_values.empty?
    sorted_values[((sorted_values.length - 1) * percentile_value).round]
  end

  def counter_delta(values)
    return nil if values.length < 2 || values.last < values.first

    values.last - values.first
  end

  def positive_delta(maximum, baseline)
    return nil if maximum.nil? || baseline.nil?

    [maximum - baseline, 0.0].max
  end

  def metric(summary, key)
    value = summary[key] || summary[key.to_s]
    return nil if value.nil? || value == ''

    Float(value)
  rescue ArgumentError, TypeError
    nil
  end

  def swap_growth_mb(summary)
    metric(summary, :swap_used_mb_peak_delta) ||
      positive_delta(metric(summary, :swap_used_mb_max), metric(summary, :swap_used_mb_start)) ||
      positive_delta(metric(summary, :swap_used_mb_max), metric(summary, :swap_used_mb_min))
  end

  def compression_growth_mb(summary)
    metric(summary, :compressed_mb_peak_delta) ||
      positive_delta(metric(summary, :compressed_mb_max), metric(summary, :compressed_mb_start)) ||
      positive_delta(metric(summary, :compressed_mb_max), metric(summary, :compressed_mb_min))
  end

  def complete_pressure_metrics?(summary)
    !metric(summary, :available_percent_min).nil? && !metric(summary, :swapouts_delta).nil?
  end

  def valid_workload?(summary)
    VALID_WORKLOAD_STATUSES.include?((summary[:workload_status] || summary['workload_status']).to_s)
  end

  def stable?(summary)
    (swap_growth_mb(summary) || Float::INFINITY) < 64 &&
      (compression_growth_mb(summary) || Float::INFINITY) < 256 &&
      (metric(summary, :available_percent_min) || -Float::INFINITY) >= 20 &&
      (metric(summary, :swapouts_delta) || Float::INFINITY) <= 0
  end

  def apply_assessment!(summary)
    swap_growth = swap_growth_mb(summary)
    compression_growth = compression_growth_mb(summary)
    available_min = metric(summary, :available_percent_min)
    swapouts_delta = metric(summary, :swapouts_delta)

    assessment = []
    assessment << 'swap-growing' if swap_growth && swap_growth >= 64
    assessment << 'compression-growing' if compression_growth && compression_growth >= 256
    assessment << 'low-available-memory' if available_min && available_min < 20
    assessment << 'swapouts-rising' if swapouts_delta && swapouts_delta > 0
    assessment << 'metrics-incomplete' unless complete_pressure_metrics?(summary)
    assessment = ['stable'] if assessment.empty?

    summary[:assessment] = assessment.join(', ')
  end

  def apply_stability_score!(summary)
    swap_growth = swap_growth_mb(summary) || 0.0
    compression_growth = compression_growth_mb(summary) || 0.0
    available_min = metric(summary, :available_percent_min)
    swapouts_delta = metric(summary, :swapouts_delta)

    score = 100.0
    score -= [swap_growth / 8.0, 35].min
    score -= [compression_growth / 16.0, 25].min
    score -= [[(20 - available_min) * 1.5, 0].max, 30].min if available_min
    score -= [10 + Math.log10(swapouts_delta + 1) * 5, 25].min if swapouts_delta&.positive?

    summary[:stability_score] = [[score, 0].max, 100].min.round(1)
  end
end

class GpuLimitReportLocal
  DEFAULT_LIMITS = [0].freeze

  def initialize(argv, command_runner: CommandRunner.new)
    @options = default_options
    parse_options!(argv)

    @command_runner = command_runner
    @probe = SystemProbe.new(command_runner: @command_runner)
    @analyzer = SampleAnalyzer.new

    @all_samples = []
    @summaries = []
    @original_limit_mb = nil
    @hog = nil
    @run_complete = false

    prepare_output_paths!
  end

  def run
    trap_signals
    @original_limit_mb = @probe.current_wired_limit_mb
    validate_limits_against_ram!
    success = true

    begin
      @hog = alloc_hog(@options[:hog_gb])

      @options[:limits_mb].each do |limit_mb|
        sample_limit(limit_mb)
      end
    rescue Interrupt
      warn 'Interrupted. Writing partial report.'
      success = false
    rescue StandardError, NoMemoryError => error
      warn "Sweep failed: #{error.message}"
      success = false
    ensure
      Signal.trap('INT', 'IGNORE')
      Signal.trap('TERM', 'IGNORE')
      success = false unless restore_original_limit!
      @run_complete = success
      begin
        write_reports!
      rescue StandardError => error
        warn "Failed to write reports: #{error.message}"
        success = false
      end
    end

    success
  end

  private

  def default_options
    {
      limits_mb: DEFAULT_LIMITS.dup,
      hog_gb: 0,
      interval: 1.0,
      duration: 60,
      warmup: 5,
      report_prefix: 'gpu_limit_report',
      output_dir: Dir.pwd,
      auto_restore: true,
      workload_command: nil
    }
  end

  def parse_options!(argv)
    OptionParser.new do |opts|
      opts.banner = <<~TXT
        Usage: ruby gpu_limit_report_local.rb [options]

        Example:
          ruby gpu_limit_report_local.rb \\
            --limits-mb 0,12288,13312 \\
            --duration 120 \\
            --interval 1 \\
            --warmup 8 \\
            --workload-command 'your-metal-workload' \\
            --report-prefix 16gb-test
      TXT

      opts.on('--limits-mb LIST', 'Comma-separated wired limits in MB') do |value|
        @options[:limits_mb] = value.split(',').map { |item| Integer(item.strip) }
      end
      opts.on('--hog-gb GB', Integer, 'Allocate this many GiB of RAM') { |value| @options[:hog_gb] = value }
      opts.on('--duration SEC', Integer, 'Seconds to sample for each limit (default: 60)') { |value| @options[:duration] = value }
      opts.on('--warmup SEC', Integer, 'Seconds to wait after changing limit before sampling (default: 5)') { |value| @options[:warmup] = value }
      opts.on('--interval SEC', Float, 'Sampling interval in seconds (default: 1.0)') { |value| @options[:interval] = value }
      opts.on('--workload-command COMMAND', 'Metal workload launched once per limit and stopped at --duration') do |value|
        @options[:workload_command] = value
      end
      opts.on('--report-prefix NAME', 'Prefix for output files') { |value| @options[:report_prefix] = value }
      opts.on('--output-dir DIR', 'Directory for output files (default: current directory)') { |value| @options[:output_dir] = File.expand_path(value) }
      opts.on('--[no-]restore', 'Restore original sysctl on exit (default: true)') { |value| @options[:auto_restore] = value }
    end.parse!(argv)

    validate_options!
  end

  def validate_options!
    raise OptionParser::InvalidArgument, '--limits-mb must contain at least one value' if @options[:limits_mb].empty?
    raise OptionParser::InvalidArgument, '--limits-mb values must be zero or positive' if @options[:limits_mb].any?(&:negative?)
    raise OptionParser::InvalidArgument, '--hog-gb must be zero or positive' if @options[:hog_gb].negative?
    raise OptionParser::InvalidArgument, '--duration must be positive' unless @options[:duration].positive?
    raise OptionParser::InvalidArgument, '--warmup must be zero or positive' if @options[:warmup].negative?
    raise OptionParser::InvalidArgument, '--interval must be positive' unless @options[:interval].positive?
    raise OptionParser::InvalidArgument, '--report-prefix must not be empty or contain a path separator' if @options[:report_prefix].empty? || @options[:report_prefix].match?(%r{[/\\]})
    raise OptionParser::InvalidArgument, '--workload-command must not be empty' if @options[:workload_command]&.strip == ''

    @options[:limits_mb] = @options[:limits_mb].uniq
  end

  def validate_limits_against_ram!
    total_ram_mb = @probe.total_ram_mb
    oversized = @options[:limits_mb].reject(&:zero?).select { |limit_mb| limit_mb > total_ram_mb }
    raise OptionParser::InvalidArgument, "wired limits exceed installed RAM: #{oversized.join(', ')} MB" if oversized.any?

    aggressive = @options[:limits_mb].reject(&:zero?).select { |limit_mb| total_ram_mb - limit_mb < 2048 }
    warn "Warning: limits #{aggressive.join(', ')} MB leave less than 2048 MB of theoretical system headroom." if aggressive.any?
  end

  def prepare_output_paths!
    FileUtils.mkdir_p(@options[:output_dir])
    slug = Time.now.strftime('%Y%m%d-%H%M%S')
    base = File.join(@options[:output_dir], "#{@options[:report_prefix]}-#{slug}")

    @raw_csv_path = "#{base}-samples.csv"
    @summary_csv_path = "#{base}-summary.csv"
    @json_path = "#{base}.json"
    @markdown_path = "#{base}.md"
  end

  def trap_signals
    interrupt_once = proc do
      Signal.trap('INT', 'IGNORE')
      Signal.trap('TERM', 'IGNORE')
      raise Interrupt
    end

    Signal.trap('INT', &interrupt_once)
    Signal.trap('TERM', &interrupt_once)
  end

  def sample_limit(limit_mb)
    warn "[#{now_str}] setting iogpu.wired_limit_mb=#{limit_mb}"
    @probe.set_wired_limit_mb(limit_mb)

    if @options[:warmup] > 0
      warn "[#{now_str}] warmup #{@options[:warmup]}s"
      sleep @options[:warmup]
    end

    samples = [@probe.sample(limit_mb)]
    @all_samples.concat(samples)
    workload = nil
    workload_result = {
      status: @options[:workload_command] ? 'failed-to-start' : 'not-configured',
      exit_status: nil
    }
    sample_window_complete = false

    begin
      workload = start_workload(limit_mb)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      next_sample_at = started_at

      loop do
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        break if now - started_at >= @options[:duration]
        break if next_sample_at - started_at >= @options[:duration]

        sleep(next_sample_at - now) if next_sample_at > now
        sample = @probe.sample(limit_mb)
        samples << sample
        @all_samples << sample
        next_sample_at += @options[:interval]
      end

      sample_window_complete = true
    ensure
      workload_result = finish_workload(workload, sample_window_complete: sample_window_complete) if workload
      summary = @analyzer.summarize(limit_mb, samples)
      summary[:workload_status] = workload_result[:status]
      summary[:workload_exit_status] = workload_result[:exit_status]
      @analyzer.assess(summary)
      @summaries << summary
    end
  end

  def start_workload(limit_mb)
    return nil unless @options[:workload_command]

    warn "[#{now_str}] starting workload for #{limit_mb} MB"
    pid = Process.spawn(
      { 'GPU_WIRED_LIMIT_MB' => limit_mb.to_s },
      @options[:workload_command],
      pgroup: true,
      out: $stderr,
      err: $stderr
    )
    { pid: pid }
  end

  def finish_workload(workload, sample_window_complete:)
    return { status: 'not-configured', exit_status: nil } unless workload

    pid = workload[:pid]
    finished = Process.waitpid2(pid, Process::WNOHANG)
    if finished
      status = finished.last
      kill_process_group('KILL', pid)
      return workload_result_for(status, sample_window_complete: sample_window_complete)
    end

    unless kill_process_group('TERM', pid)
      status = Process.waitpid2(pid, Process::WNOHANG)&.last
      return workload_result_for(status, sample_window_complete: sample_window_complete)
    end

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    status = nil

    until status || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      status = Process.waitpid2(pid, Process::WNOHANG)&.last
      sleep 0.05 unless status
    end

    unless status
      kill_process_group('KILL', pid)
      status = Process.waitpid2(pid).last
    end

    workload_result_for(status, sample_window_complete: sample_window_complete, stopped_at_duration: true)
  rescue Interrupt
    kill_process_group('KILL', pid)
    raise
  rescue Errno::ECHILD
    workload_result_for(nil, sample_window_complete: sample_window_complete)
  end

  def kill_process_group(signal, pid)
    Process.kill(signal, -pid)
    true
  rescue Errno::ESRCH
    false
  end

  def workload_result_for(status, sample_window_complete:, stopped_at_duration: false)
    result = if !sample_window_complete
               'interrupted'
             elsif stopped_at_duration
               'duration-reached'
             elsif status&.success?
               'completed'
             else
               'failed'
             end

    { status: result, exit_status: status&.exitstatus }
  end

  def restore_original_limit!
    return true unless @options[:auto_restore]
    return true if @original_limit_mb.nil?

    warn "[#{now_str}] restoring iogpu.wired_limit_mb=#{@original_limit_mb}"
    @probe.set_wired_limit_mb(@original_limit_mb)
    true
  rescue StandardError => error
    warn "Failed to restore original limit: #{error.message}"
    false
  end

  def alloc_hog(gb)
    return nil if gb.to_i <= 0

    bytes = gb * 1024 * 1024 * 1024
    buffer = ' ' * bytes
    step = 4096
    index = 0

    while index < bytes
      buffer.setbyte(index, 1)
      index += step
    end

    buffer
  end

  def write_reports!
    write_samples_csv!
    write_summary_csv!

    recommendation = @analyzer.recommendation(@summaries)
    payload = build_json_payload(recommendation)

    File.write(@json_path, JSON.pretty_generate(payload))
    File.write(@markdown_path, build_markdown(recommendation))

    puts JSON.pretty_generate(
      markdown_report: File.basename(@markdown_path),
      samples_csv: File.basename(@raw_csv_path),
      summary_csv: File.basename(@summary_csv_path),
      json_summary: File.basename(@json_path),
      recommendation: recommendation,
      output_dir: @options[:output_dir]
    )
  end

  def write_samples_csv!
    CSV.open(@raw_csv_path, 'w') do |csv|
      headers = @all_samples.first&.keys || []
      csv << headers
      @all_samples.each { |row| csv << headers.map { |header| row[header] } }
    end
  end

  def write_summary_csv!
    CSV.open(@summary_csv_path, 'w') do |csv|
      headers = @summaries.flat_map(&:keys).uniq
      csv << headers
      @summaries.each { |row| csv << headers.map { |header| row[header] } }
    end
  end

  def build_json_payload(recommendation)
    {
      generated_at: Time.now.iso8601,
      run_complete: @run_complete,
      original_limit_mb: @original_limit_mb,
      total_ram_mb: @probe.total_ram_mb.round(1),
      options: @options,
      recommendation: recommendation,
      summaries: @summaries,
      sample_count: @all_samples.length,
      files: {
        samples_csv: File.basename(@raw_csv_path),
        summary_csv: File.basename(@summary_csv_path),
        markdown: File.basename(@markdown_path)
      }
    }
  end

  def build_markdown(recommendation)
    markdown = +"# GPU wired limit report\n\n"
    markdown << "Generated: #{Time.now.iso8601}\n\n"
    markdown << "- Total RAM: #{@probe.total_ram_mb.round(1)} MB\n"
    markdown << "- Original `iogpu.wired_limit_mb`: #{@original_limit_mb} MB\n"
    markdown << "- Tested limits: #{@options[:limits_mb].join(', ')} MB\n"
    markdown << "- RAM hog: #{@options[:hog_gb]} GiB\n"
    markdown << "- Workload command: #{@options[:workload_command] || 'not configured'}\n"
    markdown << "- Duration per limit: #{@options[:duration]} s\n"
    markdown << "- Interval: #{@options[:interval]} s\n\n"

    if recommendation
      markdown << "## Recommendation\n\n"
      markdown << "Recommended candidate: **#{format_limit(recommendation[:limit_mb])}**  \n"
      markdown << "Reason: #{recommendation[:rationale]}  \n"
      markdown << "Assessment: #{recommendation[:assessment]}  \n"
      markdown << "Stability score: #{recommendation[:stability_score]}\n\n"
    else
      markdown << "## Recommendation\n\n"
      markdown << "No recommendation produced. A successful repeatable GPU workload and complete pressure metrics are required.\n\n"
    end

    markdown << "## Summary\n\n"
    markdown << "| limit_mb | score | assessment | swap_growth_mb | compression_growth_mb | available_min_pct | swapouts_delta | workload |\n"
    markdown << "|---:|---:|---|---:|---:|---:|---:|---|\n"

    @summaries.sort_by { |summary| summary[:limit_mb] }.each do |summary|
      markdown << "| #{summary[:limit_mb]} | #{summary[:stability_score]} | #{summary[:assessment]} | #{format_metric(summary[:swap_used_mb_peak_delta])} | #{format_metric(summary[:compressed_mb_peak_delta])} | #{format_metric(summary[:available_percent_min], 0)} | #{format_metric(summary[:swapouts_delta], 0)} | #{summary[:workload_status]} |\n"
    end

    markdown << "\n## Interpretation\n\n"
    markdown << "Prefer the highest limit that keeps swapouts flat, compression growth modest, and system-available memory healthy while completing the same real Metal workload. The sysctl changes a ceiling; it does not allocate GPU memory by itself.\n"

    markdown
  end

  def format_metric(value, precision = 1)
    value.nil? ? 'n/a' : value.round(precision)
  end

  def format_limit(limit_mb)
    limit_mb.zero? ? 'system default (`0`)' : "#{limit_mb} MB"
  end

  def now_str
    Time.now.strftime('%Y-%m-%d %H:%M:%S')
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    exit 1 unless GpuLimitReportLocal.new(ARGV).run
  rescue OptionParser::ParseError => error
    warn "Error: #{error.message}"
    exit 2
  end
end
