#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'optparse'
require 'pathname'
require_relative 'repetition_budget'
require_relative 'repetition_results'

def unsigned(text, range)
  number = text.to_i
  return number if /\A[0-9]+\z/.match?(text) && range.cover?(number)

  raise OptionParser::InvalidArgument, "#{text.inspect} は #{range} の整数で指定してください"
end

def options(argv)
  u64_max = (1 << 64) - 1
  incident = { 'known_identity_percent' => 100, 'past_mask' => 31, 'new_mask' => 31 }
  config = { 'incidents' => incident, 'keep_details' => false, 'birth_year' => false }
  parser = OptionParser.new do |o|
    o.banner = '使用方法: repeat-experiment.rb --population DIR --output NEW --first-seed N --repetitions N [オプション]'
    o.on('--population DIR', 'populationで生成済みの架空人口') { |v| config['population'] = v }
    o.on('--output DIR', '新規に確保する実験ディレクトリ') { |v| config['output'] = v }
    o.on('--first-seed N', '最初の事故シード。反復ごとに1増やす') { |v| config['first_seed'] = unsigned(v, 0..u64_max) }
    o.on('--repetitions N', '事前に決めた反復数') { |v| config['repetitions'] = unsigned(v, 1..(u64_max + 1)) }
    o.on('--masks LIST', '照合マスクのカンマ区切り。既定は過去・新規の共通列で可能な全組合せ') do |v|
      config['masks'] = v.split(',', -1).map { |m| unsigned(m, 0..31) }
    end
    o.on('--birth-year', '生年月日で照合する条件で生年だけを使う') { config['birth_year'] = true }
    o.on('--keep-details', '事故表、行別予測とプロファイルも保存') { config['keep_details'] = true }
    o.on('--max-bytes N', '実行先の合計バイト数を監視。超過時は停止し、未検証のファイルを残す') do |v|
      config['max_bytes'] = unsigned(v, 1..u64_max)
    end
    o.separator '事故条件（指定しない値はincidentsの既定。過去の本人対応率は100%）'
    %w[service-size past-incidents past-size new-size overlap-percent mail-reuse-percent
       known-identity-percent health-recorded-percent past-mask new-mask].each do |flag|
      range = if flag.end_with?('-percent')
                0..100
              elsif flag.end_with?('-mask')
                0..31
              else
                0..((1 << 32) - 1)
              end
      o.on("--#{flag} N") { |v| incident[flag.tr('-', '_')] = unsigned(v, range) }
    end
    o.on('--name-mode MODE', %w[full shared service], 'full / shared / service') { |v| incident['name_mode'] = v }
    o.on('-h', '--help', 'この説明を表示') { puts o; exit }
  end
  parser.parse!(argv)
  raise OptionParser::InvalidArgument, argv.join(' ') unless argv.empty?
  %w[population output first_seed repetitions].each do |key|
    raise OptionParser::MissingArgument, "--#{key.tr('_', '-')}" unless config[key]
  end
  raise ArgumentError, '事故シードがu64の上限を超えます' if config['first_seed'] + config['repetitions'] - 1 > u64_max

  shared = incident['past_mask'] & incident['new_mask']
  allowed = (0..31).select { |m| (m & shared) == m }
  masks = config['masks'] ||= allowed
  unless !masks.empty? && masks.uniq == masks && (masks - allowed).empty?
    raise ArgumentError, '照合マスクは過去・新規の両方にある列の組合せを重複なく指定してください'
  end
  config
end

def executable(name)
  candidates = name.include?(File::SEPARATOR) ? [name] : ENV.fetch('PATH').split(File::PATH_SEPARATOR).map { |d| File.join(d, name) }
  found = candidates.find { |path| File.file?(path) && File.executable?(path) }
  raise ArgumentError, "実行ファイルが見つかりません: #{name}" unless found

  File.realpath(found)
end

# 完成品の名前は全バイトを書き終えた後に排他的に公開する。
def publish(path, content, budget)
  budget.check!(content.bytesize)
  partial = path + '.partial'
  File.open(partial, 'wbx', 0o600) { |f| f.write(content) }
  File.link(partial, path)
  File.unlink(partial)
end

def csv_text(rows)
  columns = rows.first.keys
  CSV.generate do |csv|
    csv << columns
    rows.each { |row| csv << columns.map { |key| row.fetch(key) } }
  end
end

def run_trial(config, generator, budget, number)
  dir = File.join(config.fetch('output'), "trial-#{number}")
  Dir.mkdir(dir, 0o700)
  seed = config.fetch('first_seed') + number - 1
  incidents = File.join(dir, 'incidents')
  flags = config.fetch('incidents').flat_map { |k, v| ["--#{k.tr('_', '-')}", v.to_s] }
  budget.run!(generator, 'incidents', '--population', config.fetch('population'),
              '--seed', seed.to_s, *flags, '--output', incidents)
  manifest = JSON.parse(File.read(File.join(incidents, 'scoring/manifest.json')))
  unless FileUtils.compare_file(File.join(incidents, 'scoring/population-manifest.json'),
                                File.join(config.fetch('output'), 'population-manifest.json')) &&
         manifest.fetch('population').fetch('population_seed') == config.fetch('population_seed') &&
         manifest.fetch('history_seed') == seed
    raise ArgumentError, "trial-#{number} の人口生成記録または事故シードが実験条件と異なります"
  end
  manifest['population_manifest_copy'] = '../population-manifest.json'
  publish(File.join(dir, 'incident-manifest.json'), JSON.pretty_generate(manifest) + "\n", budget)

  intermediates = [incidents]
  rows = config.fetch('masks').flat_map do |mask|
    score = File.join(dir, format('score-%02d', mask))
    intermediates << score
    extra = config.fetch('birth_year') ? ['--birth-year'] : []
    budget.run!(generator, 'score', '--incidents', incidents, '--mask', mask.to_s, *extra, '--output', score)
    RepetitionResults.trial_rows(File.join(score, 'summary.csv'), manifest, seed, mask)
  end
  publish(File.join(dir, 'summary.csv'), csv_text(rows), budget)
  # 全条件のA/Bの採点を検証して保存できた反復だけを整理する。
  unless config.fetch('keep_details')
    intermediates.each { |path| FileUtils.remove_entry_secure(path) }
  end
  budget.seal!(dir)
  rows
end

def experiment(config)
  generator = executable(ENV.fetch('GENERATOR_BIN', File.expand_path('../target/release/seminar-synthetic-data', __dir__)))
  ENV['DUCKDB_BIN'] = executable(ENV.fetch('DUCKDB_BIN', 'duckdb'))
  population = config['population'] = File.realpath(config.fetch('population'))
  population_record = File.binread(File.join(population, 'manifest.json'))
  config['population_seed'] = JSON.parse(population_record).fetch('population_seed')

  # 既存の親を解決してからmkdirする。空ディレクトリ・リンク・並行実行も同様に拒否する。
  requested = File.expand_path(config.fetch('output'))
  parent = File.realpath(File.dirname(requested))
  output = config['output'] = File.join(parent, File.basename(requested))
  if Pathname.new(parent).ascend.any? { |ancestor| File.identical?(ancestor, population) }
    raise ArgumentError, '出力先は入力人口の外に指定してください'
  end
  Dir.mkdir(output, 0o700)
  budget = RepetitionBudget.new(output, config['max_bytes'])
  publish(File.join(output, 'conditions.json'), JSON.pretty_generate(config.merge(
    'interval' => 'two-sided Wilson 95%', 'threshold' => 0.8
  )) + "\n", budget)
  publish(File.join(output, 'population-manifest.json'), population_record, budget)

  trials = (1..config.fetch('repetitions')).flat_map do |number|
    run_trial(config, generator, budget, number)
  end
  report = RepetitionResults.aggregate(trials)
  publish(File.join(output, 'summary.csv'), csv_text(report), budget)
  puts File.join(output, 'summary.csv')
end

begin
  experiment(options(ARGV))
rescue OptionParser::ParseError, ArgumentError, KeyError, SystemCallError, RuntimeError, JSON::ParserError, CSV::MalformedCSVError => e
  abort "反復実験を中止しました: #{e.message}"
end
