# frozen_string_literal: true

require 'minitest/autorun'
require 'stringio'
require_relative '../scripts/service-size-best-layout'

class ServiceSizeBestLayoutTest < Minitest::Test
  def test_bounds_enclose_every_layout_and_draw_in_a_small_population
    # 対象4人、A社3人中共通2人、B社4人中共通3人。各社から1人ずつ漏えいする。
    persons = (0...4).to_a
    miss_a = Rational(2, 3)
    miss_b = Rational(3, 4)
    assert_equal Rational(1, 2), ServiceSizeBestLayout.witness_lower(4, 2, 3)
    upper = ServiceSizeBestLayout.universal_upper(4, 2, miss_a, miss_b, 2, 3)
    persons.combination(2) do |a|
      persons.combination(3) do |b|
        draws = (a + [nil]).product(b + [nil]).map { |pair| pair.compact.uniq.size }
        mean = persons.sum { |i| 1 - (a.include?(i) ? miss_a : 1) * (b.include?(i) ? miss_b : 1) }
        exact = Rational(draws.sum { |x| MultiServiceBounds.choose(x, 2) }, 6 * draws.size)
        assert_equal Rational(draws.sum, draws.size), mean
        assert_operator ServiceSizeBestLayout.witness_lower(4, 2, mean), :<=, exact
        assert_operator exact, :<=, upper
      end
    end
  end

  def test_all_six_certificates
    output = StringIO.new
    ServiceSizeBestLayout.write_csv(output)
    rows = CSV.parse(output.string, headers: true)
    assert_equal [640, 298, 555, 255, 489, 223], rows.map { |row| row['minimum_possible_k'].to_i }
    assert rows.all? { |row| row['witness_d'] == '10000' }
    assert_raises(RuntimeError) { ServiceSizeBestLayout.certify('large', 'count120', [[8, 23, 10_000]]) }
  end
end
