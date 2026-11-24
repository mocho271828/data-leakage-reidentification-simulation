# frozen_string_literal: true

require_relative 'multiservice-bounds'
require_relative 'service_size_designs'

module ServiceSizeBestLayout
  # 各行は [A型への登録回数, B型への登録回数, 該当人数]。
  # 種別ごとにサービス名を輪に並べ、各人の登録回数だけ連続して割り当てる。
  WITNESSES = {
    'large' => {
      'count120' => [[8, 24, 10_000]],
      'count240' => [[3, 12, 2750], [4, 10, 1000], [4, 11, 6250]]
    },
    'flat' => {
      'count120' => [[14, 13, 1500], [13, 14, 1000], [14, 14, 7500]],
      'count240' => [[6, 7, 6000], [7, 5, 2500], [7, 6, 1500]]
    },
    'small' => {
      'count120' => [[18, 6, 5250], [19, 6, 3750], [18, 7, 1000]],
      'count240' => [[8, 3, 4250], [8, 4, 1750], [9, 2, 4000]]
    }
  }.freeze

  def self.universal_upper(population, sample, miss_a, miss_b, slots_a, slots_b)
    # 未登場確率の相加平均は相乗平均以上。母集団全体の積は各種別の延べ登録枠で決まる。
    # 共通因子で根の次数を縮め、整数比較で相乗平均の下界を小数12桁まで求める。
    divisor = population.gcd(slots_a).gcd(slots_b)
    degree = population / divisor
    product = miss_a**(slots_a / divisor) * miss_b**(slots_b / divisor)
    scale = 10**12
    limit = product.numerator * scale**degree
    first_above = (1..(scale + 1)).bsearch { |i| i**degree * product.denominator > limit }
    mean_hit_upper = 1 - Rational(first_above - 1, scale)
    # 非復元抽出の負の関連とMaclaurinの不等式により、全員正答は個人平均のsample乗以下。
    mean_hit_upper**sample
  end

  def self.witness_lower(population, sample, mean)
    # 整数上のC(X,sample)の傾きは単調増加するため、線形補間した関数にJensenを適用できる。
    floor = mean.floor
    at = MultiServiceBounds.choose(floor, sample)
    slope = MultiServiceBounds.choose(floor, sample - 1)
    Rational(at + (mean - floor) * slope, MultiServiceBounds.choose(population, sample))
  end

  def self.certify(profile, rule, groups)
    n = MultiServiceBounds::POPULATION
    sample = MultiServiceBounds::SAMPLE
    n_a, n_b, c_a, c_b = ServiceSizeDesigns::PROFILES.fetch(profile)
    l_a, l_b = [n_a, n_b].map { |s| ServiceSizeDesigns.leaked(rule, s) }
    miss_a, miss_b = [Rational(n_a - l_a, n_a), Rational(n_b - l_b, n_b)]
    k_a, r_a = groups.sum { |a, _, people| a * people }.divmod(c_a)
    k_b, r_b = groups.sum { |_, b, people| b * people }.divmod(c_b)
    k = k_a + k_b
    unless r_a.zero? && r_b.zero? && k_a == (k + 1) / 2 && groups.sum(&:last) == n &&
           groups.all? { |a, b, people| (0..k_a).cover?(a) && (0..k_b).cover?(b) && a + b >= 2 && people.positive? }
      raise '各社の共通人数または全員の2社以上への登録を実現できません'
    end

    before = universal_upper(n, sample, miss_a, miss_b, (k / 2) * c_a, ((k - 1) / 2) * c_b)
    mean = groups.sum { |a, b, people| people * (1 - miss_a**a * miss_b**b) }
    lower = witness_lower(n, sample, mean)
    # 各社の共通登録者を順に割り当て2巡する。その後はAに2回登録した人の一部に全社を集中させる。
    pairs, remainder = n.divmod(c_a + c_b)
    core = [c_a, c_b].max
    raise '低い配置の2巡分の枠を確認してください' unless remainder.zero? && k >= 4 * pairs && core <= pairs * c_a

    outside_a = pairs * c_a - core
    outside_b = pairs * c_b
    low_mean_upper = core + outside_a * (1 - miss_a**2) + outside_b * (1 - miss_b**2)
    low_upper = (low_mean_upper / n)**sample
    target = Rational(4, 5)
    raise '80%の可能境界を確認できません' unless before < target && lower >= target && low_upper < target

    [profile, n_a, n_b, c_a, c_b, rule, l_a, l_b, k, n,
     *[before, mean, lower, low_upper].map { |p| format('%.15g', p) }, groups.map { |g| g.join('/') }.join(' ')]
  end

  def self.write_csv(io)
    csv = CSV.new(io)
    csv << %w[profile roster_a roster_b common_a common_b rule leaked_a leaked_b minimum_possible_k witness_d
              all_layouts_upper_at_previous_k witness_mean_covered_at_k witness_lower_at_k
              low_layout_upper_at_k witness_groups_a_b_people]
    WITNESSES.each do |profile, rules|
      rules.each { |rule, groups| csv << certify(profile, rule, groups) }
    end
  end
end

ServiceSizeBestLayout.write_csv($stdout) if $PROGRAM_NAME == __FILE__
