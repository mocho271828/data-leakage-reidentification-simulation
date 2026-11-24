# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../scripts/multiservice-balanced'

class ServiceSizeCyclesTest < Minitest::Test
  def test_unequal_cohorts_and_outside_registrants_match_all_incidents_and_targets
    # 0〜5が新規登録者。6〜9は過去の名簿にだけ含まれ、抽選には参加する。
    rosters = [[0, 6], [1, 2, 7], [3, 8], [4, 5, 9]]
    draws = rosters.each_with_index.map { |ids, i| ids.combination(i.even? ? 1 : 2).to_a }
    targets = (0...6).to_a.combination(2).to_a
    a = FixedServiceCohort.new(roster: 2, common: 1, leaked: 1, sample: 2)
    b = FixedServiceCohort.new(roster: 3, common: 2, leaked: 2, sample: 2)
    model = CyclicServiceLeaks.new(cohorts: [a, b] * 2, sample: 2)
    histories = [[]]
    probabilities = (0..8).map do |k|
      hits = histories.sum { |seen| targets.count { |target| (target - seen).empty? } }
      expected = Rational(hits, targets.size * histories.size)
      assert_equal expected, model.probability(k)
      assert_equal [0, 0, 0, 0, 0, 1, 3, 4, 6][k], model.multiple_registrants(k)
      histories = histories.product(draws[k % 4]).map { |seen, incident| seen | incident } if k < 8
      expected
    end
    target = Rational(1, 2)
    k = probabilities.index { |p| p >= target }
    assert_equal [k, probabilities[k - 1], probabilities[k]], model.first_crossing(target, 8)
    assert_nil model.first_crossing(1, 8)
  end
end
