# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../scripts/multiservice-balanced'

class MultiserviceBalancedTest < Minitest::Test
  def test_exact_probability_matches_enumeration_of_all_incidents_and_targets
    groups = [[0, 1, 2], [3, 4, 5]]
    [1, 2, 4].each do |target_size|
      targets = (0...6).to_a.combination(target_size).to_a
      (0..3).each do |leaked|
        model = BalancedServiceLeaks.new(group_size: 3, groups: 2, sample_size: target_size, leaked: leaked)
        histories = [[]]
        (0..4).each do |k|
          successes = histories.sum { |seen| targets.count { |target| (target - seen).empty? } }
          assert_equal Rational(successes, targets.size * histories.size), model.probability(k)
          histories = histories.product(groups[k % 2].combination(leaked).to_a).map { |seen, incident| seen | incident }
        end
      end
    end
  end
end
