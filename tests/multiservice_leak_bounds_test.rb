# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../scripts/multiservice-leak-bounds'

class MultiServiceLeakBoundsTest < Minitest::Test
  def test_all_small_rosters_and_uniform_fixed_size_incidents
    # 対象3人・各社2人・過去3社。各社1人の漏えいの全組み合わせを直接数える。
    people = (0...3).to_a
    rosters = (0..2).flat_map { |size| people.combination(size).to_a }
    stats = Hash.new { |h, key| h[key] = [] }
    rosters.repeated_permutation(3) do |services|
      counts = services.map(&:size)
      d = people.count { |p| services.count { |roster| roster.include?(p) } >= 2 }
      # nilは新規対象外の登録者。空の名簿を補う2通りのnilも別の抽選結果として数える。
      choices = services.map { |roster| roster + [nil] * (2 - roster.size) }
      histories = choices[0].product(*choices.drop(1))
      visible = histories.map { |history| history.compact.uniq.size }
      mean = Rational(visible.sum, histories.size)
      all_correct = Rational(visible.sum { |m| MultiServiceBounds.choose(m, 2) }, histories.size * 3)
      stats[[counts, d]] << [mean, all_correct]
    end
    model = MultiServiceLeakBounds.new(population: 3, sample: 2, services: 3, leak_percent: 50)
    stats.each do |(counts, d), observed|
      covered = MultiServiceBounds::GridCell.new(3, counts).bounds(d).last
      interval = model.maximum_mean(counts.sum, d, covered)
      mean, lower, upper = model.display_endpoints(interval).map(&:to_f)
      best = observed.map(&:last).max
      assert_in_delta observed.map(&:first).max, mean, 1e-11
      assert_operator lower, :<=, best + 1e-11
      assert_operator upper, :>=, best - 1e-11
      assert_operator observed.map(&:last).min, :<=, model.low_layout_upper(counts.max)
    end
  end
end
