# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../scripts/service-size-random'

class ServiceSizeRandomTest < Minitest::Test
  # 登録する新規対象者の集合と、名簿のどの枠が漏えいしたかの組をすべて数える。
  def incidents(population, roster, common, leaked)
    counts = Hash.new(0)
    (0...population).to_a.combination(common) do |people|
      (people + Array.new(roster - common)).combination(leaked) do |rows|
        mask = rows.compact.reduce(0) { |seen, i| seen | (1 << i) }
        counts[mask] += 1
      end
    end
    counts
  end

  def test_bounds_cover_full_enumeration_over_two_and_four_services
    population = 5
    rosters = [2, 4]
    [[1, 2], [2, 4], [0, 2]].each do |leaked|
      (0..2).each do |a|
        (0..4).each do |b|
          outcomes = [a, b].each_with_index.map { |c, i| incidents(population, rosters[i], c, leaked[i]) }
          counts = { 0 => 1 }
          (1..2).each do |pairs|
            outcomes.each do |service|
              merged = Hash.new(0)
              counts.each { |seen, n| service.each { |add, m| merged[seen | add] += n * m } }
              counts = merged
            end
            [1, 2, 3].each do |sample|
              model = RandomServiceRosters.new(population: population, sample: sample, rosters: rosters,
                                               leaked: leaked, pairs: pairs)
              target = (1 << sample) - 1
              exact = Rational(counts.select { |mask, _| mask & target == target }.values.sum, counts.values.sum)
              low, high = model.probability_bounds(a, b)
              assert_operator low, :<=, exact
              assert_operator high, :>=, exact
              assert_operator high - low, :<, Rational(1, 10**24)
            end
          end
        end
      end
    end
  end
end
