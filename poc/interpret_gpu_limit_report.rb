#!/usr/bin/env ruby
# frozen_string_literal: true

require 'csv'
require 'json'
require 'optparse'
require 'pathname'
require_relative '../gpu_limit_report_local'

options = {
  input: nil,
  write_md: true,
  markdown_name: nil
}

OptionParser.new do |opts|
  opts.banner = <<~TXT
    Usage: ruby interpret_gpu_limit_report.rb --input REPORT.json

    Accepts the JSON report, summary CSV, or raw samples CSV produced by gpu_limit_report_local.rb.
  TXT

  opts.on('--input PATH', 'Path to .json report or -summary.csv') { |v| options[:input] = v }
  opts.on('--markdown-name NAME', 'Optional output markdown filename') { |v| options[:markdown_name] = v }
  opts.on('--[no-]write-md', 'Write markdown interpretation file (default: true)') { |v| options[:write_md] = v }
end.parse!

abort('Missing --input') unless options[:input]
input = Pathname.new(options[:input]).expand_path
abort("File not found: #{input}") unless input.exist?

def scalar(value)
  return nil if value.nil? || value == ''
  return value unless value.is_a?(String)

  Integer(value)
rescue ArgumentError
  begin
    Float(value)
  rescue ArgumentError
    value
  end
end

def load_from_json(path)
  payload = JSON.parse(path.read)
  raise ArgumentError, 'JSON report does not contain a summaries array' unless payload['summaries'].is_a?(Array)

  payload['summaries']
end

def symbolize_row(row)
  row.to_h.to_h { |key, value| [key.to_sym, scalar(value)] }
end

def load_from_csv(path, analyzer)
  table = CSV.read(path, headers: true)
  headers = table.headers.compact
  raise ArgumentError, 'CSV has no headers' if headers.empty?

  rows = table.map { |row| symbolize_row(row) }
  if headers.include?('timestamp')
    raise ArgumentError, 'Samples CSV is missing limit_mb' unless headers.include?('limit_mb')

    rows.group_by { |row| row[:limit_mb] }
        .map { |limit_mb, samples| analyzer.summarize(Integer(limit_mb), samples) }
  else
    required = %w[limit_mb samples compressed_mb_max swap_used_mb_max]
    missing = required - headers
    raise ArgumentError, "Summary CSV is missing columns: #{missing.join(', ')}" if missing.any?

    rows
  end
end

def positive_growth(row, prefix)
  recorded = row["#{prefix}_peak_delta".to_sym]
  return recorded.to_f unless recorded.nil?

  maximum = row["#{prefix}_max".to_sym]
  baseline = row["#{prefix}_start".to_sym] || row["#{prefix}_min".to_sym]
  return nil if maximum.nil? || baseline.nil?

  [maximum.to_f - baseline.to_f, 0.0].max
end

def format_metric(value, precision = 1)
  value.nil? ? 'n/a' : value.to_f.round(precision)
end

def format_limit(limit_mb)
  limit_mb.zero? ? 'system default (`0`)' : "#{limit_mb} MB"
end

analyzer = SampleAnalyzer.new

begin
  rows = case input.extname.downcase
         when '.json'
           load_from_json(input).map { |row| symbolize_row(row) }
         when '.csv'
           load_from_csv(input, analyzer)
         else
           raise ArgumentError, "unsupported input type #{input.extname.inspect}; expected .json or .csv"
         end
rescue CSV::MalformedCSVError, JSON::ParserError, ArgumentError => error
  abort("Cannot interpret #{input}: #{error.message}")
end

abort('No summary rows found') if rows.empty?

normalized = rows.map { |row| analyzer.assess(row) }.sort_by { |row| row[:limit_mb] }

rec = analyzer.recommendation(normalized)

text = +"# Interpreted GPU wired limit report\n\n"
text << "Source: `#{input.basename}`\n\n"
text << "## Recommendation\n\n"
if rec
  text << "Recommended candidate: **#{format_limit(rec[:limit_mb])}**  \n"
  text << "Reason: #{rec[:rationale]}  \n"
  text << "Assessment: #{rec[:assessment]}  \n"
  text << "Stability score: #{rec[:stability_score]}\n\n"
else
  text << "No recommendation produced. The report must contain complete pressure metrics from a successful repeatable GPU workload.\n\n"
end

text << "## Limits ranked\n\n"
text << "| limit_mb | score | assessment | swap_growth_mb | compression_growth_mb | available_min_pct | swapouts_delta | workload |\n"
text << "|---:|---:|---|---:|---:|---:|---:|---|\n"
normalized.each do |row|
  text << "| #{row[:limit_mb]} | #{row[:stability_score]} | #{row[:assessment]} | #{format_metric(positive_growth(row, 'swap_used_mb'))} | #{format_metric(positive_growth(row, 'compressed_mb'))} | #{format_metric(row[:available_percent_min], 0)} | #{format_metric(row[:swapouts_delta], 0)} | #{row[:workload_status] || 'not-recorded'} |\n"
end

text << "\n## Reading the result\n\n"
text << "Use the highest value that stays boring: no new swapouts, modest compression growth, and healthy available memory while completing the same Metal workload. `iogpu.wired_limit_mb` only moves a GPU working-set ceiling; changing it does not allocate memory or create load.\n"

if options[:write_md]
  md_name = options[:markdown_name] || "#{input.basename.sub_ext('')}-interpreted.md"
  md_path = input.dirname.join(md_name)
  md_path.write(text)
end

puts text
