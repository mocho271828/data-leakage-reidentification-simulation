# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../scripts/service-size-bounds'

class ServiceSizeBoundsTest < Minitest::Test
  def test_at_278_services_all_three_allocations_miss_under_a_common_24_percent_leak
    population = 10_000
    services = 278
    model = MultiServiceLeakBounds.new(population: population, sample: 10, services: services, leak_percent: 24)
    # 各配分とも139,000枠。登録回数を13・14回に均すと登場実人数の期待値が最大になる。
    slots = services / 2 * 1000
    mean = model.maximum_mean(slots, population, population)
    assert_equal 'below_for_all', model.classify(mean)
    miss = Rational(76, 100)
    all_correct_upper = (1 - (9 * miss**14 + miss**13) / 10)**10
    assert_in_delta 0.799523598798615, all_correct_upper.to_f, 1e-14
  end

  def test_partial_identification_with_two_roster_sizes
    # 3人の対象者、各社2人・4人・2人、共通人数は1人・2人・1人。全配置と全半数抽選を数える。
    population = [0, 1, 2]
    sizes = [2, 4, 2]
    counts = [1, 2, 1]
    pools = counts.map { |c| population.combination(c).to_a }
    stats = Hash.new { |h, key| h[key] = [] }
    pools.first.product(*pools.drop(1)) do |rosters|
      d = population.count { |p| rosters.count { |r| r.include?(p) } >= 2 }
      choices = rosters.zip(sizes).map do |roster, size|
        (roster + [nil] * (size - roster.size)).combination(size / 2).to_a
      end
      seen = choices.first.product(*choices.drop(1)).map { |rows| rows.flatten.compact.uniq.size }
      p_all = Rational(seen.sum { |m| MultiServiceBounds.choose(m, 2) }, 3 * seen.size)
      stats[d] << [Rational(seen.sum, seen.size), p_all]
    end
    cell = MultiServiceBounds::GridCell.new(population.size, counts)
    model = MultiServiceLeakBounds.new(population: population.size, sample: 2, services: 3, leak_percent: 50)
    stats.each do |d, observed|
      mean_interval = model.maximum_mean(counts.sum, d, cell.bounds(d).last)
      mean, lower, upper = model.display_endpoints(mean_interval).map(&:to_f)
      assert_in_delta observed.map(&:first).max, mean, 1e-11
      best = observed.map(&:last).max
      assert_operator lower, :<=, best + 1e-11
      assert_operator upper, :>=, best - 1e-11
      assert_operator observed.map(&:last).min, :<=, model.low_layout_upper(counts.max)
    end
  end
end
