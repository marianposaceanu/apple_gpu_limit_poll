#!/usr/bin/env ruby
# frozen_string_literal: true

require 'csv'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'time'

class CommandRunner
  def run!(command)
    output, status = Open3.capture2e(command)
    raise "Command failed: #{command}\n#{output}" unless status.success?
    output
  end

  def run(command)
    Open3.capture2e(command).first
  rescue StandardError
    ''
  end
end

class SystemProbe
  PAGE_SIZE = 16 * 1024

  def initialize(command_runner:)
    @command_runner = command_runner
  end

  def current_wired_limit_mb
    Integer(@command_runner.run!('sysctl -n iogpu.wired_limit_mb').strip)
  end

  def set_wired_limit_mb(limit_mb)
    @command_runner.run!("sudo sysctl iogpu.wired_limit_mb=#{limit_mb}")
  end

  def total_ram_mb
    bytes = Integer(@command_runner.run!('sysctl -n hw.memsize').strip)
    bytes / 1024.0 / 1024.0
  end

  def sample(limit_mb)
    stats = vm_stats
    pressure = memory_pressure_snapshot
    swap = swap_usage

    {
      timestamp: Time.now.iso8601,
      limit_mb: limit_mb,
      wired_mb: pages_to_mb(stats['Pages wired down'] || 0),
      compressed_mb: pages_to_mb(stats['Pages occupied by compressor'] || 0),
      swap_used_mb: swap[:used_mb],
      swap_total_mb: swap[:total_mb],
      free_mb: pages_to_mb(stats['Pages free'] || 0) + pages_to_mb(stats['Pages speculative'] || 0),
      active_mb: pages_to_mb(stats['Pages active'] || 0),
      inactive_mb: pages_to_mb(stats['Pages inactive'] || 0),
      purgeable_mb: pages_to_mb(stats['Pages purgeable'] || 0),
      throttled_mb: pages_to_mb(stats['Pages throttled'] || 0),
      pageouts: pressure[:pageouts],
      pressure_raw: pressure[:raw]
    }
  end

  private

  def vm_stats
    output = @command_runner.run!('vm_stat')
    stats = {}

    output.each_line do |line|
      next unless line.include?(':')
      key, value = line.split(':', 2)
      stats[key.strip] = value.gsub(/[^\d]/, '').to_i
    end

    stats
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
    output = @command_runner.run('memory_pressure 2>/dev/null')
    snapshot = { raw: output.to_s.strip, pageouts: nil }

    match = output.match(/Pageouts:\s+(\d+)/i)
    snapshot[:pageouts] = match[1].to_i if match

    snapshot
  rescue StandardError
    { raw: '', pageouts: nil }
  end

  def pages_to_mb(pages)
    (pages * PAGE_SIZE) / 1024.0 / 1024.0
  end
end

class SampleAnalyzer
  METRIC_KEYS = %i[wired_mb compressed_mb swap_used_mb free_mb active_mb inactive_mb purgeable_mb throttled_mb].freeze

  def summarize(limit_mb, samples)
    summary = { limit_mb: limit_mb, samples: samples.length }

    METRIC_KEYS.each do |key|
      values = samples.map { |sample| sample[key] }.compact.sort
      next if values.empty?

      summary["#{key}_min".to_sym] = values.first
      summary["#{key}_avg".to_sym] = values.sum / values.length
      summary["#{key}_p95".to_sym] = percentile(values, 0.95)
      summary["#{key}_max".to_sym] = values.last
      summary["#{key}_end".to_sym] = samples.last[key]
    end

    pageouts = samples.map { |sample| sample[:pageouts] }.compact
    summary[:pageouts_start] = pageouts.first
    summary[:pageouts_end] = pageouts.last
    summary[:pageouts_delta] = pageouts.length >= 2 ? pageouts.last - pageouts.first : nil

    apply_assessment!(summary)
    apply_stability_score!(summary)

    summary
  end

  def recommendation(summaries)
    stable = summaries.select do |summary|
      (summary[:swap_used_mb_max] || 0) < 256 &&
        (summary[:compressed_mb_max] || 0) < 768 &&
        (summary[:free_mb_min] || Float::INFINITY) > 512 &&
        (summary[:pageouts_delta] || 0) <= 0
    end

    candidate = if stable.any?
                  stable.max_by { |summary| summary[:limit_mb] }
                else
                  summaries.max_by { |summary| [summary[:stability_score], -summary[:limit_mb]] }
                end
    return nil unless candidate

    {
      limit_mb: candidate[:limit_mb],
      rationale: stable.include?(candidate) ? 'highest stable tested limit' : 'best score among tested values',
      assessment: candidate[:assessment],
      stability_score: candidate[:stability_score]
    }
  end

  private

  def percentile(sorted_values, percentile_value)
    return nil if sorted_values.empty?
    sorted_values[((sorted_values.length - 1) * percentile_value).round]
  end

  def apply_assessment!(summary)
    compressed_max = summary[:compressed_mb_max] || 0.0
    swap_max = summary[:swap_used_mb_max] || 0.0
    free_min = summary[:free_mb_min] || 0.0

    assessment = []
    assessment << 'swap-heavy' if swap_max >= 512
    assessment << 'compression-heavy' if compressed_max >= 1024
    assessment << 'low-free-memory' if free_min <= 512
    assessment << 'pageouts-rising' if (summary[:pageouts_delta] || 0) > 0
    assessment = ['stable'] if assessment.empty?

    summary[:assessment] = assessment.join(', ')
  end

  def apply_stability_score!(summary)
    compressed_max = summary[:compressed_mb_max] || 0.0
    swap_max = summary[:swap_used_mb_max] || 0.0
    free_min = summary[:free_mb_min] || 0.0

    score = 100.0
    score -= [swap_max / 32.0, 40].min
    score -= [compressed_max / 64.0, 30].min
    score -= 15 if free_min < 512
    score -= 10 if (summary[:pageouts_delta] || 0) > 0

    summary[:stability_score] = [[score, 0].max, 100].min.round(1)
  end
end

class GpuLimitReportLocal
  DEFAULT_LIMITS = [5632, 6144, 7168, 8192].freeze

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

    prepare_output_paths!
  end

  def run
    trap_signals
    @original_limit_mb = @probe.current_wired_limit_mb

    begin
      @hog = alloc_hog(@options[:hog_gb])

      @options[:limits_mb].each do |limit_mb|
        sample_limit(limit_mb)
      end
    rescue Interrupt
      warn 'Interrupted. Writing partial report.'
    ensure
      restore_original_limit!
    end

    write_reports!
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
      auto_restore: true
    }
  end

  def parse_options!(argv)
    OptionParser.new do |opts|
      opts.banner = <<~TXT
        Usage: ruby gpu_limit_report_local.rb [options]

        Example:
          ruby gpu_limit_report_local.rb \
            --limits-mb 5632,6144,7168,8192 \
            --hog-gb 6 \
            --duration 120 \
            --interval 1 \
            --warmup 8 \
            --report-prefix 16gb-test
      TXT

      opts.on('--limits-mb LIST', 'Comma-separated wired limits in MB') do |value|
        @options[:limits_mb] = value.split(',').map { |item| Integer(item.strip) }
      end
      opts.on('--hog-gb GB', Integer, 'Allocate this many GiB of RAM') { |value| @options[:hog_gb] = value }
      opts.on('--duration SEC', Integer, 'Seconds to sample for each limit (default: 60)') { |value| @options[:duration] = value }
      opts.on('--warmup SEC', Integer, 'Seconds to wait after changing limit before sampling (default: 5)') { |value| @options[:warmup] = value }
      opts.on('--interval SEC', Float, 'Sampling interval in seconds (default: 1.0)') { |value| @options[:interval] = value }
      opts.on('--report-prefix NAME', 'Prefix for output files') { |value| @options[:report_prefix] = value }
      opts.on('--output-dir DIR', 'Directory for output files (default: current directory)') { |value| @options[:output_dir] = File.expand_path(value) }
      opts.on('--[no-]restore', 'Restore original sysctl on exit (default: true)') { |value| @options[:auto_restore] = value }
    end.parse!(argv)
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
    trap('INT') { raise Interrupt }
    trap('TERM') { raise Interrupt }
  end

  def sample_limit(limit_mb)
    warn "[#{now_str}] setting iogpu.wired_limit_mb=#{limit_mb}"
    @probe.set_wired_limit_mb(limit_mb)

    if @options[:warmup] > 0
      warn "[#{now_str}] warmup #{@options[:warmup]}s"
      sleep @options[:warmup]
    end

    samples = []
    started_at = Time.now

    while Time.now - started_at < @options[:duration]
      sample = @probe.sample(limit_mb)
      samples << sample
      @all_samples << sample
      sleep @options[:interval]
    end

    @summaries << @analyzer.summarize(limit_mb, samples)
  end

  def restore_original_limit!
    return unless @options[:auto_restore]
    return if @original_limit_mb.nil?

    warn "[#{now_str}] restoring iogpu.wired_limit_mb=#{@original_limit_mb}"
    @probe.set_wired_limit_mb(@original_limit_mb)
  rescue StandardError => error
    warn "Failed to restore original limit: #{error.message}"
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
    markdown << "- Duration per limit: #{@options[:duration]} s\n"
    markdown << "- Interval: #{@options[:interval]} s\n\n"

    if recommendation
      markdown << "## Recommendation\n\n"
      markdown << "Recommended default: **#{recommendation[:limit_mb]} MB**  \n"
      markdown << "Reason: #{recommendation[:rationale]}  \n"
      markdown << "Assessment: #{recommendation[:assessment]}  \n"
      markdown << "Stability score: #{recommendation[:stability_score]}\n\n"
    end

    markdown << "## Summary\n\n"
    markdown << "| limit_mb | score | assessment | swap_max_mb | compressed_max_mb | free_min_mb | pageouts_delta |\n"
    markdown << "|---:|---:|---|---:|---:|---:|---:|\n"

    @summaries.sort_by { |summary| summary[:limit_mb] }.each do |summary|
      markdown << "| #{summary[:limit_mb]} | #{summary[:stability_score]} | #{summary[:assessment]} | #{(summary[:swap_used_mb_max] || 0).round(1)} | #{(summary[:compressed_mb_max] || 0).round(1)} | #{(summary[:free_mb_min] || 0).round(1)} | #{summary[:pageouts_delta] || 0} |\n"
    end

    markdown << "\n## Interpretation\n\n"
    markdown << "Prefer the highest limit that keeps swap near zero, compressed memory moderate, free memory above roughly 512 MB, and pageouts flat during your normal workload.\n"

    markdown
  end

  def now_str
    Time.now.strftime('%Y-%m-%d %H:%M:%S')
  end
end

if $PROGRAM_NAME == __FILE__
  GpuLimitReportLocal.new(ARGV).run
end
