#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'rbconfig'
require 'tmpdir'
require_relative 'gpu_limit_report_local'

class FakeCommandRunner
  def run!(*command)
    case command.join(' ')
    when 'vm_stat'
      <<~OUTPUT
        Mach Virtual Memory Statistics: (page size of 4096 bytes)
        Pages free:                               256.
        Pages active:                             512.
        Pages inactive:                           128.
        Pages speculative:                         64.
        Pages wired down:                         256.
        Pages occupied by compressor:             128.
      OUTPUT
    when 'sysctl vm.swapusage'
      'vm.swapusage: total = 1.00G  used = 512.00M  free = 512.00M'
    else
      raise "Unexpected command: #{command.join(' ')}"
    end
  end

  def run(*command)
    raise "Unexpected command: #{command.join(' ')}" unless command == ['memory_pressure']

    <<~OUTPUT
      Swapouts: 8
      Pageouts: 9
      System-wide memory free percentage: 42%
    OUTPUT
  end
end

class SystemProbeTest < Minitest::Test
  def test_sample_uses_reported_page_size_and_pressure_metrics
    sample = SystemProbe.new(command_runner: FakeCommandRunner.new).sample(12_288)

    assert_equal 1.0, sample[:wired_mb]
    assert_equal 0.5, sample[:compressed_mb]
    assert_equal 1.25, sample[:free_mb]
    assert_equal 512.0, sample[:swap_used_mb]
    assert_equal 42, sample[:available_percent]
    assert_equal 8, sample[:swapouts]
    assert_equal 9, sample[:pageouts]
  end
end

class SampleAnalyzerTest < Minitest::Test
  def setup
    @analyzer = SampleAnalyzer.new
  end

  def test_summary_measures_growth_from_the_pre_workload_baseline
    summary = @analyzer.summarize(12_288, [
      sample(compressed_mb: 100, swap_used_mb: 10, available_percent: 55, swapouts: 20),
      sample(compressed_mb: 180, swap_used_mb: 26, available_percent: 48, swapouts: 20),
      sample(compressed_mb: 140, swap_used_mb: 18, available_percent: 50, swapouts: 20)
    ])

    assert_equal 80.0, summary[:compressed_mb_peak_delta]
    assert_equal 16.0, summary[:swap_used_mb_peak_delta]
    assert_equal 48, summary[:available_percent_min]
    assert_equal 0, summary[:swapouts_delta]
  end

  def test_recommendation_uses_highest_stable_limit_with_a_valid_workload
    summaries = [stable_summary(0), stable_summary(12_288), stable_summary(13_312)]
    failed = stable_summary(14_336).merge(workload_status: 'failed')

    recommendation = @analyzer.recommendation(summaries + [failed])

    assert_equal 13_312, recommendation[:limit_mb]
    assert_equal 'highest pressure-stable tested limit', recommendation[:rationale]
  end

  def test_recommendation_is_withheld_for_pressure_or_incomplete_metrics
    pressured = stable_summary(13_312).merge(swapouts_delta: 4)
    @analyzer.assess(pressured)
    incomplete = stable_summary(12_288).merge(available_percent_min: nil)
    @analyzer.assess(incomplete)

    assert_nil @analyzer.recommendation([pressured, incomplete])
    assert_includes pressured[:assessment], 'swapouts-rising'
    assert_includes incomplete[:assessment], 'metrics-incomplete'
  end

  private

  def sample(compressed_mb:, swap_used_mb:, available_percent:, swapouts:)
    {
      compressed_mb: compressed_mb,
      swap_used_mb: swap_used_mb,
      available_percent: available_percent,
      swapouts: swapouts,
      pageouts: 0
    }
  end

  def stable_summary(limit_mb)
    summary = {
      limit_mb: limit_mb,
      compressed_mb_peak_delta: 32,
      swap_used_mb_peak_delta: 0,
      available_percent_min: 40,
      swapouts_delta: 0,
      workload_status: 'completed'
    }
    @analyzer.assess(summary)
  end
end

class InterpreterTest < Minitest::Test
  def test_raw_samples_are_grouped_into_one_row_per_limit
    Dir.mktmpdir do |directory|
      input = File.join(directory, 'test-samples.csv')
      CSV.open(input, 'w') do |csv|
        csv << %w[timestamp limit_mb compressed_mb swap_used_mb available_percent swapouts pageouts]
        csv << ['2026-01-01T00:00:00Z', 0, 100, 0, 80, 0, 0]
        csv << ['2026-01-01T00:00:01Z', 0, 110, 0, 79, 0, 0]
        csv << ['2026-01-01T00:00:02Z', 12_288, 100, 0, 78, 0, 0]
        csv << ['2026-01-01T00:00:03Z', 12_288, 120, 0, 77, 0, 0]
      end

      interpreter = File.expand_path('poc/interpret_gpu_limit_report.rb', __dir__)
      output, status = Open3.capture2e(RbConfig.ruby, interpreter, '--input', input, '--no-write-md')

      assert status.success?, output
      assert_equal 2, output.scan(/^\| (?:0|12288) /).length
      assert_includes output, 'No recommendation produced.'
    end
  end
end
