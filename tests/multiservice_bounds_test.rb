# frozen_string_literal: true

require 'minitest/autorun'
require 'set'
require_relative '../scripts/multiservice-bounds'

class MultiServiceBoundsTest < Minitest::Test
  def test_every_small_assignment_and_unattainable_duplicate_count
    # 各社の名簿を任意の部分集合として全列挙し、式が端点だけでなく中間の全整数も表すことを確認する。
    n = 4
    rosters = (0...(1 << n)).to_a
    people = (0...n).to_a
    sizes = rosters.map { |r| people.count { |i| r[i] == 1 } }
    (1..4).each do |k|
      observed = Hash.new { |h, key| h[key] = Set.new }
      rosters.repeated_permutation(k) do |services|
        counts = services.map { |r| sizes[r] }
        degrees = people.map { |i| services.sum { |r| r[i] } }
        observed[[counts, degrees.count { |v| v >= 2 }]] << degrees.count(&:positive?)
      end
      (0..n).to_a.repeated_permutation(k) do |counts|
        cell = MultiServiceBounds::GridCell.new(n, counts)
        (0..n).each do |d|
          bounds = cell.bounds(d)
          assert_equal observed[[counts, d]].sort, bounds ? (bounds[0]..bounds[1]).to_a : []
        end
      end
    end
  end

  def test_probability_and_discrete_threshold
    population = (1..7).to_a
    (1..7).each do |sample|
      draws = population.combination(sample).to_a
      probabilities = (0..7).map do |covered|
        measured = draws.count { |draw| draw.max <= covered }.fdiv(draws.size)
        assert_in_delta measured, MultiServiceBounds.probability(7, sample, covered), 1e-15
        measured
      end
      assert_equal probabilities.index { |p| p >= 0.8 }, MultiServiceBounds.cutoff(7, sample)
    end
    assert_equal 9780, MultiServiceBounds.cutoff(10_000, 10)
    cell = MultiServiceBounds::GridCell.new(10_000, [100] * 100)
    assert_equal [['reached', 0, 2], ['depends', 3, 220], ['below', 221, 5000]],
                 MultiServiceBounds.runs(cell, 9780)
  end
end
