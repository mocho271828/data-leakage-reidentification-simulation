# 実行: ruby scripts/check-boundary-theory.rb
require 'bigdecimal'

# 人口・免許保有数は全国人口表（人口シード2026）のmanifestに記録された実数。
POPULATION = 73_322_000
HOLDERS = 61_112_249
REGISTRANTS = 18_330_500
REUSED_MAIL = 4_582_625
TARGET = BigDecimal('0.8')
# n<=100では包除式の係数の絶対値の総和は最大2^100。
# 約31桁の相殺に備え、各項を90桁で評価してから、表示だけを丸める。
DIGITS = 90
BigDecimal.limit(DIGITS)

def choose(n, k)
  (1..k).reduce(1) { |count, i| count * (n - i + 1) / i }
end

def all_in_subset(subset, population, n)
  BigDecimal(choose(subset, n)).div(choose(population, n), DIGITS)
end

def coverage_terms(n, incident_size)
  (0..n).map do |j|
    # 指定のj人が過去1事故で全員選ばれない確率を、事故件数だけ累乗する。
    coefficient = (j.even? ? 1 : -1) * choose(n, j)
    [coefficient, all_in_subset(REGISTRANTS - incident_size, REGISTRANTS, j)]
  end
end

def first_crossing(terms, ceiling)
  # 今回の事故には毎回対象外の登録者がいるため、有限回では天井値に届かない。
  return [] if ceiling <= TARGET

  probability = lambda do |k|
    terms.sum { |coefficient, absent| coefficient * absent.power(k, DIGITS) } * ceiling
  end
  # 各事故は過去の履歴に追加されるため、今回の一意メール条件では単調増加する。
  high = 1
  high *= 2 while probability.call(high) < TARGET
  k = (1..high).bsearch { |count| probability.call(count) >= TARGET }
  [k, probability.call(k - 1), probability.call(k)]
end

puts 'past_percent,new_size,service,masks,ceiling,first_k,p_before,p_at'
[12, 24].product([1, 10, 100]).each do |percent, n|
  terms = coverage_terms(n, REGISTRANTS * percent / 100)
  reuse = all_in_subset(REUSED_MAIL, REGISTRANTS, n)
  holders = all_in_subset(HOLDERS, POPULATION, n)
  services = [['A', 1], ['B', reuse]]
  masks = [['2|3', 1], ['31', holders]]
  services.product(masks).each do |(service, mail_probability), (mask, license_probability)|
    ceiling = BigDecimal(mail_probability * license_probability)
    k, before, at = first_crossing(terms, ceiling)
    values = [percent, n, service, mask, ceiling, k, before, at]
    puts values.map { |v| v.is_a?(BigDecimal) ? format('%.12g', v) : v }.join(',')
  end
end
