# frozen_string_literal: true

require_relative 'multiservice-bounds'
require_relative 'service_size_designs'

class RandomServiceRosters
  SCALE = 10**30

  def initialize(population:, sample:, rosters:, leaked:, pairs:)
    unless sample.between?(1, population) && pairs.positive? && rosters.size == 2 &&
           leaked.size == 2 && rosters.zip(leaked).all? { |n, l| n.positive? && l.between?(0, n) }
      raise ArgumentError, '人数または社数が指定範囲外です'
    end

    @population, @sample, @rosters, @leaked, @pairs = population, sample, rosters, leaked, pairs
    @weights = (0..sample).map do |j|
      (0..j).map { |h| (h.even? ? 1 : -1) * MultiServiceBounds.choose(j, h) }
    end
  end

  # 指定した j 人が1社の漏えいに誰も出ない確率を、j = 0..新規人数について求める。
  def miss_probabilities(common, roster, leaked)
    raise ArgumentError, '共通人数が名簿の範囲外です' unless common.between?(0, [roster, @population].min)

    # 全員が登録され、かつ漏えいする確率を h 人から h+1 人へ更新する。
    hits = [1.to_r]
    @sample.times do |h|
      hits << if h >= common || h >= leaked
                0
              else
                hits.last * Rational(common - h, @population - h) * Rational(leaked - h, roster - h)
              end
    end
    @weights.map { |weights| weights.each_with_index.sum { |w, h| w * hits[h] } }
  end

  # 非負の区間を掛けるたびに外向きに丸め、累乗後も真値を含むようにする。
  def power_bounds(value)
    base = [(value * SCALE).floor, (value * SCALE).ceil]
    result = [SCALE, SCALE]
    k = @pairs
    while k.positive?
      result = product_bounds(result, base) if k.odd?
      k /= 2
      base = product_bounds(base, base) if k.positive?
    end
    result
  end

  def product_bounds(left, right)
    [left[0] * right[0] / SCALE, (left[1] * right[1] + SCALE - 1) / SCALE]
  end

  def probability_bounds(common_a, common_b)
    a, b = [common_a, common_b].each_with_index.map { |c, i| miss_probabilities(c, @rosters[i], @leaked[i]) }
    lo = hi = 0
    @weights.last.each_with_index do |weight, j|
      low, high = power_bounds(a[j] * b[j])
      # 奇数次数の包除項では、上限を引いて下限を作る。
      low, high = high, low if weight.negative?
      lo += weight * low
      hi += weight * high
    end
    [Rational([lo, 0].max, SCALE), Rational([hi, SCALE].min, SCALE)]
  end

  def self.boundary(model, units, limit)
    intervals = Hash.new { |cache, t| cache[t] = model.probability_bounds(units[0] * t, units[1] * t) }
    target = Rational(4, 5)
    # 名簿の外部者1枠を未登録の新規対象者に置き換えても、既存の対象者の枠は失われない。
    first = (0..limit).bsearch do |t|
      low, high = intervals[t]
      raise '有理数の区間で80%を判定できません' if low < target && high >= target

      low >= target
    end
    [first, intervals]
  end

  def self.write_csv(io)
    out = CSV.new(io)
    out << %w[services roster_a roster_b rule leaked_a leaked_b allocation units_a units_b
              t_max outcome first_t common_a common_b total_slots p_before p_at p_max]
    rosters = [750, 1250]
    [140, 200, 300, 500, 1000].each do |k|
      ServiceSizeDesigns::RULES.each do |rule|
        leaked = rosters.map { |n| ServiceSizeDesigns.leaked(rule, n) }
        model = new(population: MultiServiceBounds::POPULATION, sample: MultiServiceBounds::SAMPLE,
                    rosters: rosters, leaked: leaked, pairs: k / 2)
        { 'equal' => [1, 1], 'large' => [1, 3], 'small' => [3, 1] }.each do |name, units|
          limit = rosters.zip(units).map { |n, u| n / u }.min
          first, intervals = boundary(model, units, limit)
          display = ->(t) { format('%.13g', (intervals[t].sum / 2).to_f) }
          row = [k, *rosters, rule, *leaked, name, *units, limit]
          if first
            a, b = units.map { |u| u * first }
            row.concat(['reached', first, a, b, (a + b) * (k / 2), display.call(first - 1), display.call(first)])
          else
            row.concat(['unreachable', nil, nil, nil, nil, nil, nil])
          end
          out << [*row, display.call(limit)]
        end
      end
    end
  end
end

RandomServiceRosters.write_csv($stdout) if $PROGRAM_NAME == __FILE__
