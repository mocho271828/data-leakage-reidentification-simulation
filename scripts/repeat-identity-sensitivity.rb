#!/usr/bin/env ruby
# frozen_string_literal: true

require 'csv'
require 'json'
require 'optparse'
require 'tempfile'
require_relative 'repetition_results'

# サービスA内でメールが一意かつ不変のとき、既知の過去行が1つあれば本人が決まる。
module IdentitySensitivity
  POPULATION = 73_322_000
  SERVICE_SIZE = 18_330_500
  PAST_SIZE = 4_399_320
  PAST_COUNT = 15
  NEW_SIZE = 10
  MASK = 2
  REPETITIONS = 400
  FIRST_SEEDS = { 100 => 726_000, 90 => 727_000 }.freeze

  module_function

  def trial(seed, known_percent, service_size: SERVICE_SIZE, past_size: PAST_SIZE, past_count: PAST_COUNT, new_size: NEW_SIZE)
    rng = Random.new(seed)
    seen = Array.new(new_size, false)
    known = Array.new(new_size, false)
    target_past_rows = 0
    target_known_rows = 0
    past_count.times do
      remaining = past_size
      new_size.times do |i|
        # 対象10人は交換可能。i人調べた時点の残り枠数／未確認の登録者数で、次の人の登場を引く。
        next unless rng.rand(service_size - i) < remaining

        remaining -= 1
        seen[i] = true
        target_past_rows += 1
        next unless rng.rand(100) < known_percent

        known[i] = true
        target_known_rows += 1
      end
    end
    correct = known.count(true)
    {
      'known_identity_percent' => known_percent, 'seed' => seed, 'mask' => MASK, 'service' => 'A',
      'targets' => new_size, 'correct' => correct, 'incorrect' => 0, 'unresolved' => new_size - correct,
      'all_correct' => correct == new_size, 'health_revealed' => correct, 'seen_in_past' => seen.count(true),
      'all_seen' => seen.all?, 'target_past_rows' => target_past_rows, 'target_known_past_rows' => target_known_rows
    }
  end

  def summary(rows)
    n = rows.size
    totals = (RepetitionResults::COUNTS + ['seen_in_past']).to_h { |name| [name, rows.sum { |r| r.fetch(name) }] }
    targets, correct, incorrect, unresolved, health = totals.values_at(*RepetitionResults::COUNTS)
    successes = RepetitionResults.true_count(rows, 'all_correct')
    lower, upper = RepetitionResults.wilson95(successes, n)
    decision = if lower >= 0.8
                 'reached'
               elsif upper < 0.8
                 'below'
               else
                 'uncertain'
               end
    # 登録者全体の延べ人数・実人数はこの抽選の対象外。新規対象10人について観測した指標を返す。
    {
      'known_identity_percent' => rows.first.fetch('known_identity_percent'), 'mask' => MASK, 'service' => 'A',
      'trials' => n, 'successes' => successes, 'rate' => successes.fdiv(n),
      'lower95' => lower, 'upper95' => upper, 'decision' => decision, 'total_targets' => targets,
      'mean_correct' => correct.fdiv(n), 'mean_incorrect' => incorrect.fdiv(n), 'mean_unresolved' => unresolved.fdiv(n),
      'correct_rate' => correct.fdiv(targets), 'incorrect_rate' => incorrect.fdiv(targets),
      'unresolved_rate' => unresolved.fdiv(targets), 'mean_health' => health.fdiv(n),
      'mean_seen' => totals['seen_in_past'].fdiv(n), 'all_seen_rate' => RepetitionResults.true_count(rows, 'all_seen').fdiv(n),
      'seen_rate' => totals['seen_in_past'].fdiv(targets)
    }
  end

  def conditions
    {
      'method' => '新規対象に限定した厳密抽出。各過去事故の非復元抽出での登場と、登場した行ごとの独立な本人対応を抽選する。',
      'population_size' => POPULATION, 'reference_population_seed' => 2026, 'service' => 'A', 'service_size' => SERVICE_SIZE,
      'past_incidents' => PAST_COUNT, 'past_size' => PAST_SIZE, 'new_size' => NEW_SIZE, 'mask' => MASK,
      'matching' => 'サービスA内の一意で不変なメールが完全一致し、過去行の本人対応が1回以上判明したら正答。',
      'health_recorded_percent' => 100, 'interval' => 'two-sided Wilson 95%', 'threshold' => 0.8,
      'rng' => 'Ruby Random.new(seed)', 'ruby_version' => RUBY_VERSION,
      'conditions' => FIRST_SEEDS.map do |percent, first|
        { 'known_identity_percent' => percent, 'first_seed' => first,
          'last_seed' => first + REPETITIONS - 1, 'repetitions' => REPETITIONS }
      end
    }
  end

  def publish(output, filename)
    Tempfile.create('partial-', output) do |file|
      yield file
      file.flush
      File.link(file.path, File.join(output, filename))
    end
  end

  def write_csv(output, filename, rows)
    publish(output, filename) do |file|
      csv = CSV.new(file)
      columns = rows.first.keys
      csv << columns
      rows.each { |row| csv << columns.map { |c| row.fetch(c) } }
    end
  end

  def run(output)
    Dir.mkdir(output, 0o700)
    publish(output, 'conditions.json') { |file| file.puts(JSON.pretty_generate(conditions)) }
    trials = FIRST_SEEDS.flat_map do |percent, first|
      REPETITIONS.times.map { |i| trial(first + i, percent) }
    end
    write_csv(output, 'trials.csv', trials)
    summaries = trials.group_by { |row| row.fetch('known_identity_percent') }.values.map { |rows| summary(rows) }
    write_csv(output, 'summary.csv', summaries)
    puts File.join(output, 'summary.csv')
  end
end

if $PROGRAM_NAME == __FILE__
  output = nil
  parser = OptionParser.new do |o|
    o.banner = '使用方法: ruby scripts/repeat-identity-sensitivity.rb --output NEW_DIR'
    o.on('--output DIR', '新しく作る出力ディレクトリ。親は既存のディレクトリを指定') { |v| output = v }
    o.on('-h', '--help', 'この説明を表示') { puts o; exit }
  end
  begin
    parser.parse!
    abort parser.to_s unless ARGV.empty? && output && !output.empty?
    IdentitySensitivity.run(File.expand_path(output))
  rescue OptionParser::ParseError, SystemCallError => e
    abort "反復実験を中止しました: #{e.message}"
  end
end
