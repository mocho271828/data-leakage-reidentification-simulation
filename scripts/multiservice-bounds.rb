# frozen_string_literal: true

require 'csv'

module MultiServiceBounds
  POPULATION = 10_000
  SAMPLE = 10
  SERVICES = [1, 2, 3, 5, 10, 20, 50, 100, 200, 500, 1000].freeze
  COMMON = [0, 10, 25, 50, 100, 250, 500, 1000].freeze

  class GridCell
    attr_reader :population

    def initialize(population, counts)
      raise ArgumentError, '対象登録者数は正の整数です' unless population.is_a?(Integer) && population.positive?
      if counts.empty? || counts.any? { |c| !c.is_a?(Integer) || !c.between?(0, population) }
        raise ArgumentError, '各社の共通登録者数の範囲を確認してください'
      end

      @population = population
      @slots = counts.sum
      @counts = Hash.new(0)
      counts.each { |c| @counts[c] += 1 }
    end

    def bounds(d)
      return unless d.is_a?(Integer) && d.between?(0, @population)

      # 各社の共有枠のうちD人に収まらない分は、全て別人の単独登録になる。
      lower = d + @counts.sum { |c, services| services * [c - d, 0].max }
      upper = [@population, @slots - d].min
      [lower, upper] if lower <= upper
    end
  end

  def self.choose(total, chosen)
    return 0 if total < chosen

    (1..chosen).reduce(1) { |v, i| v * (total - i + 1) / i }
  end

  def self.probability(population, sample, covered)
    choose(covered, sample).fdiv(choose(population, sample))
  end

  def self.cutoff(population, sample)
    raise ArgumentError, '抽出人数の範囲を確認してください' unless sample.between?(1, population)

    # 表示用の浮動小数点値を使わず、80%以上かを整数で正確に比較する。
    total = choose(population, sample)
    (sample..population).bsearch { |m| 5 * choose(m, sample) >= 4 * total }
  end

  def self.each_design
    SERVICES.each do |k|
      COMMON.each { |c| yield 'equal', k, c, Array.new(k, c) }
      next if k == 1

      counts = [50] * (k / 2) + [150] * (k / 2)
      counts << 100 if k.odd?
      yield 'unequal', k, 100, counts
    end
  end

  def self.outcome_runs(cell)
    runs = []
    (0..cell.population).each do |d|
      limits = cell.bounds(d)
      next unless limits

      outcome = yield(d, limits)
      if runs.any? && runs.last[0] == outcome && runs.last[2] + 1 == d
        runs.last[2] = d
      else
        runs << [outcome, d, d]
      end
    end
    runs
  end

  def self.runs(cell, threshold)
    outcome_runs(cell) do |_d, (lower, upper)|
      if lower >= threshold
        'reached'
      elsif upper < threshold
        'below'
      else
        'depends'
      end
    end
  end

  def self.write_csv(io)
    csv = CSV.new(io)
    columns = %w[profile services mean_common target_population new_size cutoff outcome d_start d_end]
    %w[start end].each { |side| columns.concat(%w[m_min m_max p_min p_max].map { |key| "#{key}_#{side}" }) }
    csv << columns
    threshold = cutoff(POPULATION, SAMPLE)
    each_design do |profile, k, c, counts|
      cell = GridCell.new(POPULATION, counts)
      runs(cell, threshold).each do |outcome, first, last|
        ends = [first, last].flat_map do |d|
          lower, upper = cell.bounds(d)
          [lower, upper, *[lower, upper].map { |m| format('%.12g', probability(POPULATION, SAMPLE, m)) }]
        end
        csv << [profile, k, c, POPULATION, SAMPLE, threshold, outcome, first, last, *ends]
      end
    end
  end
end

MultiServiceBounds.write_csv($stdout) if $PROGRAM_NAME == __FILE__
