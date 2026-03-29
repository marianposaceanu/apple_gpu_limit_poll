#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
require 'csv'
require 'json'
require 'pathname'

options = {
  input: nil,
  write_md: true,
  markdown_name: nil
}

OptionParser.new do |opts|
  opts.banner = <<~TXT
    Usage: ruby interpret_gpu_limit_report.rb --input REPORT.json

    Accepts either the JSON report or the summary CSV produced by gpu_limit_report_local.rb.
  TXT

  opts.on('--input PATH', 'Path to .json report or -summary.csv') { |v| options[:input] = v }
  opts.on('--markdown-name NAME', 'Optional output markdown filename') { |v| options[:markdown_name] = v }
  opts.on('--[no-]write-md', 'Write markdown interpretation file (default: true)') { |v| options[:write_md] = v }
end.parse!

abort('Missing --input') unless options[:input]
input = Pathname.new(options[:input]).expand_path
abort("File not found: #{input}") unless input.exist?

def num(v)
  return nil if v.nil? || v == ''
  Float(v)
rescue ArgumentError
  nil
end

def load_from_json(path)
  payload = JSON.parse(path.read)
  [payload['summaries'] || [], payload]
end

def load_from_summary_csv(path)
  rows = CSV.read(path, headers: true).map(&:to_h)
  [rows, nil]
end

def assessment_for(row)
  out = []
  swap = num(row['swap_used_mb_max'] || row[:swap_used_mb_max]) || 0
  comp = num(row['compressed_mb_max'] || row[:compressed_mb_max]) || 0
  free = num(row['free_mb_min'] || row[:free_mb_min]) || 0
  pageouts = num(row['pageouts_delta'] || row[:pageouts_delta]) || 0

  out << 'swap-heavy' if swap >= 512
  out << 'compression-heavy' if comp >= 1024
  out << 'low-free-memory' if free <= 512
  out << 'pageouts-rising' if pageouts > 0
  out = ['stable'] if out.empty?
  out.join(', ')
end

def score_for(row)
  swap = num(row['swap_used_mb_max'] || row[:swap_used_mb_max]) || 0
  comp = num(row['compressed_mb_max'] || row[:compressed_mb_max]) || 0
  free = num(row['free_mb_min'] || row[:free_mb_min]) || 0
  pageouts = num(row['pageouts_delta'] || row[:pageouts_delta]) || 0

  score = 100.0
  score -= [swap / 32.0, 40].min
  score -= [comp / 64.0, 30].min
  score -= 15 if free < 512
  score -= 10 if pageouts > 0
  [[score, 0].max, 100].min.round(1)
end

def recommended(rows)
  stable = rows.select do |r|
    (num(r['swap_used_mb_max'] || r[:swap_used_mb_max]) || 0) < 256 &&
      (num(r['compressed_mb_max'] || r[:compressed_mb_max]) || 0) < 768 &&
      (num(r['free_mb_min'] || r[:free_mb_min]) || Float::INFINITY) > 512 &&
      (num(r['pageouts_delta'] || r[:pageouts_delta]) || 0) <= 0
  end

  chosen = if stable.any?
             stable.max_by { |r| num(r['limit_mb'] || r[:limit_mb]) || 0 }
           else
             rows.max_by { |r| [score_for(r), -(num(r['limit_mb'] || r[:limit_mb]) || 0)] }
           end

  return nil unless chosen

  {
    'limit_mb' => (num(chosen['limit_mb'] || chosen[:limit_mb]) || 0).to_i,
    'assessment' => assessment_for(chosen),
    'stability_score' => score_for(chosen),
    'rationale' => stable.include?(chosen) ? 'highest stable tested limit' : 'best score among tested values'
  }
end

rows, payload = if input.extname == '.json'
                  load_from_json(input)
                else
                  load_from_summary_csv(input)
                end

abort('No summary rows found') if rows.empty?

normalized = rows.map do |r|
  {
    'limit_mb' => (num(r['limit_mb'] || r[:limit_mb]) || 0).to_i,
    'swap_used_mb_max' => num(r['swap_used_mb_max'] || r[:swap_used_mb_max]) || 0,
    'compressed_mb_max' => num(r['compressed_mb_max'] || r[:compressed_mb_max]) || 0,
    'free_mb_min' => num(r['free_mb_min'] || r[:free_mb_min]) || 0,
    'pageouts_delta' => num(r['pageouts_delta'] || r[:pageouts_delta]) || 0,
    'stability_score' => score_for(r),
    'assessment' => assessment_for(r)
  }
end.sort_by { |r| r['limit_mb'] }

rec = recommended(normalized)

text = +"# Interpreted GPU wired limit report\n\n"
text << "Source: `#{input.basename}`\n\n"
if rec
  text << "## Recommendation\n\n"
  text << "Recommended default: **#{rec['limit_mb']} MB**  \n"
  text << "Reason: #{rec['rationale']}  \n"
  text << "Assessment: #{rec['assessment']}  \n"
  text << "Stability score: #{rec['stability_score']}\n\n"
end

text << "## Limits ranked\n\n"
text << "| limit_mb | score | assessment | swap_max_mb | compressed_max_mb | free_min_mb | pageouts_delta |\n"
text << "|---:|---:|---|---:|---:|---:|---:|\n"
normalized.each do |r|
  text << "| #{r['limit_mb']} | #{r['stability_score']} | #{r['assessment']} | #{r['swap_used_mb_max'].round(1)} | #{r['compressed_mb_max'].round(1)} | #{r['free_mb_min'].round(1)} | #{r['pageouts_delta'].round} |\n"
end

text << "\n## Reading the result\n\n"
text << "Use the highest value that stays boring: low swap, moderate compression, no pageout growth, and enough free memory that the machine still feels responsive. For your workload, this is more useful than maximizing GPU headroom.\n"

if options[:write_md]
  md_name = options[:markdown_name] || "#{input.basename.sub_ext('')}-interpreted.md"
  md_path = input.dirname.join(md_name)
  md_path.write(text)
end

puts text
