# frozen_string_literal: true

require 'csv'
require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'tmpdir'

class RepeatExperimentTest < Minitest::Test
  PROJECT = File.expand_path('..', __dir__)
  RUNNER = File.join(PROJECT, 'scripts/repeat-experiment.rb')
  FIRST_SEED = (1 << 53) + 1

  def setup
    @tmp = Dir.mktmpdir
    @population = File.join(@tmp, 'fixed population')
    @output = File.join(@tmp, 'new output')
    @generator = ENV.fetch('GENERATOR_BIN', File.join(PROJECT, 'target/release/seminar-synthetic-data'))
    assert system(@generator, 'population', '--people', '100', '--seed', '2026',
                  '--output', @population, err: File::NULL), '先に cargo build --release --locked を実行してください'
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def run_experiment(*options, repetitions: 1, masks: '2', past_size: 20, new_size: 4, generator: @generator)
    env = { 'GENERATOR_BIN' => generator, 'REAL_GENERATOR' => @generator }
    local_duckdb = File.join(PROJECT, 'target/duckdb-cli/duckdb')
    env['DUCKDB_BIN'] = local_duckdb if !ENV['DUCKDB_BIN'] && File.executable?(local_duckdb)
    text, status = Open3.capture2e(env, RbConfig.ruby, RUNNER, '--population', @population,
                                   '--output', @output, '--first-seed', FIRST_SEED.to_s,
                                   '--repetitions', repetitions.to_s, '--masks', masks,
                                   '--service-size', '20', '--overlap-percent', '0',
                                   '--past-incidents', '1', '--past-size', past_size.to_s, '--new-size', new_size.to_s,
                                   '--known-identity-percent', '100', '--health-recorded-percent', '0', *options)
    [status.success?, text]
  end

  def test_fixed_population_independent_seeds_and_pointwise_intervals
    ok, log = run_experiment('--max-bytes', '8000000', repetitions: 2, masks: '0,2')
    assert ok, log
    assert File.file?(File.join(@output, 'conditions.json'))
    assert_equal JSON.parse(File.read(File.join(@population, 'manifest.json'))),
                 JSON.parse(File.read(File.join(@output, 'population-manifest.json')))

    (1..2).each do |trial|
      dir = File.join(@output, "trial-#{trial}")
      manifest = JSON.parse(File.read(File.join(dir, 'incident-manifest.json')))
      seed = FIRST_SEED + trial - 1
      assert_equal seed, manifest.fetch('history_seed')
      rows = CSV.read(File.join(dir, 'summary.csv'), headers: true)
      assert_equal [seed.to_s], rows['seed'].uniq
      assert_equal [%w[0 A], %w[0 B], %w[2 A], %w[2 B]], rows.map { |r| r.values_at('mask', 'service') }.sort
      assert_equal ['4'], rows['targets'].uniq
      assert_empty Dir.glob(File.join(dir, '**', '*.parquet'))
      assert_empty Dir.glob(File.join(dir, '**', '*-profile.json'))
    end

    rows = CSV.read(File.join(@output, 'summary.csv'), headers: true)
    assert_equal 4, rows.size
    rows.each do |row|
      # 過去の事故はAの登録者全員を含み、Bとの重なりは0人。健診結果は全員空欄。
      success = row['service'] == 'A' && row['mask'] == '2'
      assert_equal 2, Integer(row['trials'])
      assert_equal(success ? 2 : 0, Integer(row['successes']))
      assert_equal(success ? 1.0 : 0.0, Float(row['rate']))
      assert_in_delta(success ? 0.3423802275 : 0.0, Float(row['lower95']), 1e-8)
      assert_in_delta(success ? 1.0 : 0.6576197725, Float(row['upper95']), 1e-8)
      assert_equal(success ? 'uncertain' : 'below', row['decision'])
      assert_equal(success ? 1.0 : 0.0, Float(row['correct_rate']))
      assert_equal(success ? 0.0 : 1.0, Float(row['unresolved_rate']))
      assert_equal 0.0, Float(row['incorrect_rate'])
      assert_equal 0.0, Float(row['mean_health'])
      assert_equal(row['service'] == 'A' ? 1.0 : 0.0, Float(row['all_seen_rate']))
    end
  end

  def test_keep_details_preserves_replay_inputs_and_predictions
    ok, log = run_experiment('--keep-details', past_size: 10, new_size: 20)
    assert ok, log
    trial = File.join(@output, 'trial-1')
    assert File.file?(File.join(trial, 'incidents/matching/new-A.parquet'))
    assert File.file?(File.join(trial, 'score-02/predictions.parquet'))
    assert File.file?(File.join(trial, 'score-02/summary.csv'))
    assert File.file?(File.join(trial, 'summary.csv'))
    row = CSV.read(File.join(@output, 'summary.csv'), headers: true).find { |r| r['service'] == 'A' }
    assert_equal 0.5, Float(row['correct_rate'])
    assert_equal 0.5, Float(row['unresolved_rate'])
    assert_equal 0.0, Float(row['rate'])
  end

  def test_existing_directory_and_symlink_are_rejected
    Dir.mkdir(@output)
    marker = File.join(@output, 'keep')
    File.write(marker, 'unchanged')
    refute run_experiment.first
    assert_equal ['keep'], Dir.children(@output)
    assert_equal 'unchanged', File.read(marker)
    @output = File.join(@tmp, 'link')
    File.symlink(File.dirname(marker), @output)
    refute run_experiment.first
    assert_equal ['keep'], Dir.children(@output)
  end

  def test_input_population_cannot_become_the_output_parent_through_an_alias
    linked = File.join(@tmp, 'alias')
    File.symlink(@population, linked)
    parents = [linked]
    upper = File.join(@tmp, File.basename(@population).upcase)
    parents << upper if File.identical?(upper, @population)
    parents.each do |parent|
      @output = File.join(parent, 'trial-data')
      refute run_experiment.first
      refute File.exist?(File.join(@population, 'trial-data'))
    end
  end

  def test_budget_failure_never_publishes_a_complete_aggregate
    refute run_experiment('--max-bytes', '1').first
    refute File.exist?(File.join(@output, 'summary.csv'))
    assert File.exist?(File.join(@population, 'scoring/population/part-00000.parquet'))
  end

  def test_budget_is_monitored_while_the_generator_runs
    wrapper = File.join(@tmp, 'large-incident')
    File.write(wrapper, <<~'RUBY')
      #!/usr/bin/env ruby
      if ARGV.first == 'incidents'
        dir = ARGV.fetch(ARGV.index('--output') + 1)
        Dir.mkdir(dir)
        File.write(File.join(dir, 'oversized'), 'x' * 2_000_000)
        sleep 3
        File.write(File.join(dir, 'continued'), '1')
      end
    RUBY
    File.chmod(0o755, wrapper)
    ok, log = run_experiment('--max-bytes', '1000000', generator: wrapper)
    refute ok, log
    assert_match(/上限/, log)
    incident = File.join(@output, 'trial-1/incidents')
    assert File.exist?(File.join(incident, 'oversized'))
    refute File.exist?(File.join(incident, 'continued'))
    refute File.exist?(File.join(@output, 'summary.csv'))
    assert File.exist?(File.join(@population, 'scoring/population/part-00000.parquet'))
  end

  def test_invalid_second_summary_does_not_publish_or_discard_its_evidence
    wrapper = File.join(@tmp, 'corrupt-second-summary')
    File.write(wrapper, <<~'RUBY')
      #!/usr/bin/env ruby
      require 'json'
      exit 1 unless system(ENV.fetch('REAL_GENERATOR'), *ARGV)
      if ARGV.first == 'score'
        incident_dir = ARGV.fetch(ARGV.index('--incidents') + 1)
        manifest = JSON.parse(File.read(File.join(incident_dir, 'scoring/manifest.json')))
        if manifest.fetch('history_seed').even?
          output_dir = ARGV.fetch(ARGV.index('--output') + 1)
          summary = File.join(output_dir, 'summary.csv')
          File.write(summary, File.readlines(summary).first(2).join)
        end
      end
    RUBY
    File.chmod(0o755, wrapper)
    ok, log = run_experiment(repetitions: 2, generator: wrapper)
    refute ok, log
    refute File.exist?(File.join(@output, 'summary.csv'))
    assert File.file?(File.join(@output, 'trial-1/summary.csv'))
    assert File.file?(File.join(@output, 'trial-2/score-02/predictions.parquet'))
    assert File.file?(File.join(@output, 'trial-2/incidents/matching/new-A.parquet'))
  end
end
