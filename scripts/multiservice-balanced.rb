# frozen_string_literal: true

require_relative 'multiservice-bounds'

# 1群の共通登録者は、残りの登録者とともに同じ名簿から非復元抽出される。
class FixedServiceCohort
  attr_reader :common, :denominator

  def initialize(roster:, common:, leaked:, sample:)
    raise ArgumentError unless roster.positive? && (1..roster).cover?(common) &&
                               (0..roster).cover?(leaked) && sample.positive?

    @common, @degree = common, [common, sample].min
    @miss_rate = (roster - leaked).fdiv(roster)
    missed = (0..@degree).map do |i|
      Rational(MultiServiceBounds.choose(roster - leaked, i), MultiServiceBounds.choose(roster, i))
    end
    @denominator = missed.map(&:denominator).reduce(1, :lcm)
    @numerators = missed.map { |p| p.numerator * (@denominator / p.denominator) }
    @by_incidents = {}
  end

  def expected_covered(incidents)
    @common * (1 - @miss_rate**incidents)
  end

  def group_coefficients(incidents)
    @by_incidents[incidents] ||= begin
      missed = @numerators.map { |count| count**incidents }
      (0..@degree).map do |j|
        # 指定したj人が全員1回以上登場する確率を包除で求め、選び方の数を掛ける。
        hits = (0..j).sum { |i| (i.even? ? 1 : -1) * MultiServiceBounds.choose(j, i) * missed[i] }
        MultiServiceBounds.choose(@common, j) * hits
      end
    end
  end
end

class CyclicServiceLeaks
  def initialize(cohorts:, sample:)
    @cohorts, @sample = cohorts, sample
    @population = @cohorts.sum(&:common)
    raise ArgumentError unless (1..@population).cover?(@sample)

    @sample_count = MultiServiceBounds.choose(@population, @sample)
  end

  def probability(services)
    denominator = @sample_count
    coefficients = [1]
    each_exposure(services) do |cohort, incidents|
      next if incidents.zero?

      factor = cohort.group_coefficients(incidents)
      denominator *= cohort.denominator**incidents
      # 全群から合計n人を引く。次数nを超えた項は最終結果に寄与しない。
      coefficients = Array.new([coefficients.size + factor.size - 1, @sample + 1].min) do |j|
        ([0, j - factor.size + 1].max..[j, coefficients.size - 1].min).sum do |k|
          coefficients[k] * factor[j - k]
        end
      end
    end
    Rational(coefficients.fetch(@sample, 0), denominator)
  end

  def multiple_registrants(services)
    each_exposure(services).sum { |cohort, incidents| incidents >= 2 ? cohort.common : 0 }
  end

  def first_crossing(target, limit)
    # 1人の正答確率だけを使う近似で探索開始点を選ぶ。採否は前後の厳密な分数で判定する。
    k = (1..limit).bsearch do |s|
      mean = each_exposure(s).sum { |cohort, incidents| cohort.expected_covered(incidents) }
      (mean / @population)**@sample >= target
    end || limit
    at = probability(k)
    while at < target
      return if k == limit

      k += 1
      at = probability(k)
    end
    before = probability(k - 1)
    while k > 1 && before >= target
      k -= 1
      at = before
      before = probability(k - 1)
    end
    [k, before, at]
  end

  private

  def each_exposure(services)
    raise ArgumentError if services.negative?
    return enum_for(__method__, services) unless block_given?

    rounds, extra = services.divmod(@cohorts.size)
    @cohorts.each_with_index { |cohort, i| yield cohort, rounds + (i < extra ? 1 : 0) }
  end
end

class BalancedServiceLeaks < CyclicServiceLeaks
  def initialize(group_size:, groups:, sample_size:, leaked:)
    raise ArgumentError unless groups.positive?

    @cohort = FixedServiceCohort.new(roster: group_size, common: group_size, leaked: leaked, sample: sample_size)
    super(cohorts: [@cohort] * groups, sample: sample_size)
  end

  def group_coefficients(incidents)
    @cohort.group_coefficients(incidents)
  end
end

if $PROGRAM_NAME == __FILE__
  target = Rational(4, 5)
  models = [12, 24, 100].map do |pct|
    BalancedServiceLeaks.new(group_size: 1000, groups: 10, sample_size: 10, leaked: 10 * pct)
  end
  # 各社を加えるほど既出の人数は増えるか不変。表には境界の直前と直後も収める。
  crossings = models.map { |model| (1..1000).bsearch { |k| model.probability(k) >= target } }
  service_counts = [1, 2, 3, 5, 10, 20, 50, 100, 130, 140, 150, 200, 280, 290, 300, 500, 1000]
  service_counts |= crossings.flat_map { |k| [k - 1, k, k + 1] }
  puts 'past_services,p_all_12,p_all_24,p_all_100'
  service_counts.sort.each do |k|
    # 80%判定後に限り、表示用の値を有効数字15桁に丸める。
    puts ([k] + models.map { |model| format('%.15g', model.probability(k).to_f) }).join(',')
  end
end
