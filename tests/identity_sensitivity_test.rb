# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative '../scripts/repeat-identity-sensitivity'

class IdentitySensitivityTest < Minitest::Test
  RUNNER = File.expand_path('../scripts/repeat-identity-sensitivity.rb', __dir__)

  def test_sampling_without_replacement_and_known_identity_extremes
    # 対象が登録者全員なら、乱数種にかかわらず各事故で必ず3人がちょうど1回ずつ登場する。
    12.times do |seed|
      [0, 100].each do |percent|
        row = IdentitySensitivity.trial(seed, percent, service_size: 7, past_size: 3, past_count: 1, new_size: 7)
        assert_equal [3, 3], row.values_at('seen_in_past', 'target_past_rows')
        expected = percent.zero? ? 0 : 3
        assert_equal [expected, expected], row.values_at('correct', 'target_known_past_rows')
      end
    end
    # 同じ4人全員が過去3回に登場した場合、延べ12行でも正答人数は4人となる。
    row = IdentitySensitivity.trial(1, 100, service_size: 4, past_size: 4, past_count: 3, new_size: 4)
    assert_equal [4, 12, 12, true], row.values_at('correct', 'target_past_rows', 'target_known_past_rows', 'all_correct')
  end

  def test_cli_protects_existing_results_and_reproduces_the_seed_series
    Dir.mktmpdir do |dir|
      first, second = %w[first second].map { |name| File.join(dir, name) }
      [first, second].each do |output|
        text, status = Open3.capture2e(RbConfig.ruby, RUNNER, '--output', output)
        assert status.success?, text
      end
      marker = File.join(first, '既存ファイル')
      File.write(marker, '保持')
      _, status = Open3.capture2e(RbConfig.ruby, RUNNER, '--output', first)
      refute status.success?
      assert_equal '保持', File.read(marker)
      filenames = %w[conditions.json summary.csv trials.csv]
      assert_equal filenames, Dir.children(second).sort
      filenames.each { |name| assert_equal File.binread(File.join(second, name)), File.binread(File.join(first, name)) }

      trials = CSV.read(File.join(first, 'trials.csv'), headers: true, converters: :numeric)
      groups = trials.group_by { |r| r.fetch('known_identity_percent') }
      summaries = CSV.read(File.join(first, 'summary.csv'), headers: true, converters: :numeric)
      assert_equal [90, 100], summaries.map { |r| r.fetch('known_identity_percent') }.sort
      assert_equal [90, 100], groups.keys.sort
      { 100 => 726_000, 90 => 727_000 }.each do |percent, first_seed|
        rows = groups.fetch(percent)
        assert_equal (first_seed...first_seed + 400).to_a, rows.map { |r| r.fetch('seed') }.sort
        assert(rows.all? do |r|
          correct, unresolved, seen, known, past = r.values_at('correct', 'unresolved', 'seen_in_past',
                                                               'target_known_past_rows', 'target_past_rows')
          r['targets'] == 10 && r['mask'] == 2 && r['service'] == 'A' && r['incorrect'] == 0 &&
            correct >= 0 && correct + unresolved == 10 && correct <= seen && seen <= 10 &&
            r['health_revealed'] == correct && correct <= known && known <= past && seen <= past &&
            r['all_seen'] == (seen == 10).to_s && r['all_correct'] == (correct == 10).to_s &&
            (percent != 100 || (correct == seen && known == past))
        end)
        if percent == 90
          assert rows.any? { |r| r['correct'] < r['seen_in_past'] }, '本人対応率90%が採点に反映されていません'
        end
        summary = summaries.find { |r| r.fetch('known_identity_percent') == percent }
        successes = rows.count { |r| r['correct'] == 10 }
        assert_equal [400, successes, 4000], summary.values_at('trials', 'successes', 'total_targets')
        assert_in_delta successes.fdiv(400), summary['rate'], 1e-12
        lower, upper = RepetitionResults.wilson95(successes, 400)
        assert_in_delta lower, summary['lower95'], 1e-12
        assert_in_delta upper, summary['upper95'], 1e-12
      end
    end
  end
end
