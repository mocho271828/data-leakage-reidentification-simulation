# frozen_string_literal: true

require_relative 'multiservice-bounds'

# 実行: ruby scripts/multiservice-balanced.rb
class BalancedServiceLeaks
  def initialize(group_size:, groups:, sample_size:, leaked:)
    @size, @groups, @sample = group_size, groups, sample_size
    raise ArgumentError unless groups.positive? && group_size.positive? &&
                               (1..groups * group_size).cover?(sample_size) && (0..group_size).cover?(leaked)

    @sample_count = MultiServiceBounds.choose(@size * @groups, @sample)
    @degree = [@size, @sample].min
    # 指定した i 人が過去1社の固定人数抽出で全員外れる確率。整数だけで累乗・包除する。
    missed = (0..@degree).map do |i|
      Rational(MultiServiceBounds.choose(@size - leaked, i), MultiServiceBounds.choose(@size, i))
    end
    @denominator = missed.map(&:denominator).reduce(1, :lcm)
    @numerators = missed.map { |p| p.numerator * (@denominator / p.denominator) }
    @by_incidents = {}
  end

  def group_coefficients(incidents)
    @by_incidents[incidents] ||= begin
      missed = @numerators.map { |count| count**incidents }
      (0..@degree).map do |j|
        # j人全員が過去に登場する確率の分子に、そのj人の選び方を掛ける。
        hits = (0..j).sum { |i| (i.even? ? 1 : -1) * MultiServiceBounds.choose(j, i) * missed[i] }
        MultiServiceBounds.choose(@size, j) * hits
      end
    end
  end

  def probability(services)
    raise ArgumentError if services.negative?

    rounds, extra = services.divmod(@groups)
    coefficients = [1]
    @groups.times do |group|
      factor = group_coefficients(rounds + (group < extra ? 1 : 0))
      # 全群から合計n人を引く。次数nを超えた項は最終結果に寄与しない。
      coefficients = Array.new([coefficients.size + @degree, @sample + 1].min) do |j|
        ([0, j - @degree].max..[j, coefficients.size - 1].min).sum do |k|
          coefficients[k] * factor[j - k]
        end
      end
    end
    Rational(coefficients.fetch(@sample), @sample_count * @denominator**services)
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
