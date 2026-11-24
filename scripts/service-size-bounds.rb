# frozen_string_literal: true

require_relative 'multiservice-leak-bounds'
require_relative 'service_size_designs'

module ServiceSizeBounds
  SERVICES = [10, 20, 50, 100, 140, 200, 280, 299, 300, 500, 600, 1000].freeze
  POPULATION = MultiServiceBounds::POPULATION
  SAMPLE = MultiServiceBounds::SAMPLE

  def self.write_csv(io)
    csv = CSV.new(io)
    columns = %w[profile services registrants_a registrants_b common_a common_b leak_percent leaked_a leaked_b
                 feasible_d_count outcome d_start d_end]
    %w[start end].each do |side|
      columns.concat(%w[best_p_lower best_p_upper worst_p_upper].map { |key| "#{key}_#{side}" })
    end
    csv << columns

    threshold = MultiServiceBounds.cutoff(POPULATION, SAMPLE)
    SERVICES.each do |k|
      [12, 24, 100].each do |percent|
        rule = percent == 100 ? 'full' : "rate#{percent}"
        partial = if percent < 100
                    MultiServiceLeakBounds.new(population: POPULATION, sample: SAMPLE, services: k, leak_percent: percent)
                  end
        ServiceSizeDesigns::PROFILES.each do |name, (n_a, n_b, c_a, c_b)|
          raise '共通登録者数は各社の登録者数以下にする必要があります' if c_a > n_a || c_b > n_b
          leaked_a, leaked_b = [n_a, n_b].map { |n| ServiceSizeDesigns.leaked(rule, n) }

          counts = [c_a] * ((k + 1) / 2) + [c_b] * (k / 2)
          cell = MultiServiceBounds::GridCell.new(POPULATION, counts)
          slots = counts.sum
          if partial
            # 各社の分母が違っても、全社で q が同じなら登場人数の期待値は登録先の数で決まる。
            low_layout = partial.low_layout_upper(counts.max)
            raise '80%未達の配置を確認できません' unless low_layout < Rational(4, 5)
            runs = MultiServiceBounds.outcome_runs(cell) do |d, limits|
              partial.classify(partial.maximum_mean(slots, d, limits.last))
            end
          else
            runs = MultiServiceBounds.runs(cell, threshold)
          end
          feasible = runs.sum { |_, first, last| last - first + 1 }
          runs.each do |outcome, first, last|
            ends = [first, last].flat_map do |d|
              low, high = cell.bounds(d)
              if partial
                _, best_low, best_high = partial.display_endpoints(partial.maximum_mean(slots, d, high))
                [best_low, best_high, format('%.12g', low_layout)]
              else
                best, worst = [high, low].map { |m| format('%.12g', MultiServiceBounds.probability(POPULATION, SAMPLE, m)) }
                [best, best, worst]
              end
            end
            # 全記録用と部分漏えい用の既存スクリプトで異なる区分名を統一する。
            label = { 'below' => 'below_for_all', 'depends' => 'crosses', 'reached' => 'reached_for_all' }.fetch(outcome, outcome)
            csv << [name, k, n_a, n_b, c_a, c_b, percent, leaked_a, leaked_b,
                    feasible, label, first, last, *ends]
          end
        end
      end
    end
  end
end

ServiceSizeBounds.write_csv($stdout) if $PROGRAM_NAME == __FILE__
