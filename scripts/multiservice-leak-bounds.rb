# frozen_string_literal: true

require_relative 'multiservice-bounds'

class MultiServiceLeakBounds
  # 各人が過去に登場する確率を両側へ丸める。判定には浮動小数点を使わない。
  SCALE = 10**12

  def initialize(population:, sample:, services:, leak_percent:)
    @population, @sample = population, sample
    @q = Rational(leak_percent, 100)
    @hits = (0..services).map do |degree|
      hit = SCALE * (1 - (1 - @q)**degree)
      [hit.floor, hit.ceil]
    end
    @denominator = MultiServiceBounds.choose(population, sample)
    m = MultiServiceBounds.cutoff(population, sample)
    before = MultiServiceBounds.choose(m - 1, sample)
    at = MultiServiceBounds.choose(m, sample)
    # F(m)=C(m,n)/C(N,n) の整数間を線形補間し、80%と交わる点を求める。
    @jensen_cutoff = (SCALE * (m - 1 + Rational(4 * @denominator - 5 * before, 5 * (at - before)))).ceil
    @product_cutoff = (0..population * SCALE).bsearch do |value|
      5 * value**sample >= 4 * (population * SCALE)**sample
    end
  end

  # 上限の実人数がMなら、複数登録者に割く延べ枠の最小値は H = S - (M-D)。
  # D人にこのH枠を巡回順に割り振ると、個人の登録数は高々1しか違わない。
  def maximum_mean(slots, d, max_covered)
    singles = max_covered - d
    degree, extra = d.zero? ? [0, 0] : (slots - singles).divmod(d)
    low, high = @hits.fetch(degree)
    # extra=0でdegreeがサービス数そのものの場合、degree+1は存在しない。
    extra_low, extra_high = extra.zero? ? [0, 0] : @hits.fetch(degree + 1)
    [singles * @hits[1][0] + (d - extra) * low + extra * extra_low,
     singles * @hits[1][1] + (d - extra) * high + extra * extra_high]
  end

  def classify(mean_interval)
    lo, hi = mean_interval
    return 'below_for_all' if hi < @product_cutoff
    return 'crosses' if lo >= @jensen_cutoff

    'unresolved'
  end

  def low_layout_upper(max_common)
    # 最初のmax_common人に各社の複数登録枠をそろえ、足りない人に2枠まで移す。
    # この外側の人は高々2社なので、1人正答確率が全員正答確率の上界を与える。
    Rational(max_common + (@population - max_common) * (1 - (1 - @q)**2), @population)
  end

  def display_endpoints(mean_interval)
    lo, hi = mean_interval
    whole, part = lo.divmod(SCALE)
    ways = MultiServiceBounds.choose(whole, @sample)
    next_ways = MultiServiceBounds.choose(whole + 1, @sample)
    lower = Rational(ways * SCALE + (next_ways - ways) * part, @denominator * SCALE)
    upper = Rational(hi, @population * SCALE)**@sample
    [lo.fdiv(SCALE), lower, upper].map { |v| format('%.12g', v) }
  end

  def self.write_csv(io)
    csv = CSV.new(io)
    columns = %w[profile services mean_common leak_percent outcome d_start d_end]
    %w[start end].each { |side| columns.concat(%w[max_mean best_p_lower best_p_upper].map { |key| "#{key}_#{side}" }) }
    csv << columns
    MultiServiceBounds.each_design do |profile, k, c, counts|
      n = MultiServiceBounds::POPULATION
      cell = MultiServiceBounds::GridCell.new(n, counts)
      slots = counts.sum
      [12, 24].each do |percent|
        model = new(population: n, sample: MultiServiceBounds::SAMPLE, services: k, leak_percent: percent)
        raise '80%未達配置の上界を確認してください' unless model.low_layout_upper(counts.max) < Rational(4, 5)

        runs = MultiServiceBounds.outcome_runs(cell) do |d, limits|
          model.classify(model.maximum_mean(slots, d, limits.last))
        end
        runs.each do |outcome, first, last|
          ends = [first, last].flat_map do |d|
            model.display_endpoints(model.maximum_mean(slots, d, cell.bounds(d).last))
          end
          csv << [profile, k, c, percent, outcome, first, last, *ends]
        end
      end
    end
  end
end

MultiServiceLeakBounds.write_csv($stdout) if $PROGRAM_NAME == __FILE__
