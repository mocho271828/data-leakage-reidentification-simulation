# frozen_string_literal: true

require 'csv'

module RepetitionResults
  SCORE_COLUMNS = %w[service targets correct incorrect unresolved all_correct health_revealed].freeze
  COUNTS = %w[targets correct incorrect unresolved health_revealed].freeze
  SERVICES = %w[A B].freeze

  module_function

  def count(value, name)
    return value if value.is_a?(Integer) && value >= 0
    return Integer(value, 10) if value.is_a?(String) && /\A[0-9]+\z/.match?(value)

    raise ArgumentError, "#{name} は非負の整数である必要があります: #{value.inspect}"
  end

  def true_count(rows, name)
    rows.count do |row|
      case row.fetch(name).to_s
      when 'true' then true
      when 'false' then false
      else raise ArgumentError, "#{name} はtrueまたはfalseである必要があります"
      end
    end
  end

  def trial_rows(score_csv, incident_manifest, seed, mask)
    scores = CSV.read(score_csv, headers: true)
    unless scores.headers == SCORE_COLUMNS && scores.map { |s| s['service'] }.sort == SERVICES
      raise ArgumentError, "#{score_csv} の列またはサービスA・Bの行に過不足があります"
    end
    incidents = incident_manifest.fetch('new_incidents')
    unless incident_manifest.fetch('history_seed') == seed && incidents.map { |i| i.fetch('service') }.sort == SERVICES
      raise ArgumentError, '事故生成記録のシードまたはサービスが一致しません'
    end

    scores.map do |score|
      service = score['service']
      context = "#{score_csv} (#{service})"
      incident = incidents.find { |i| i.fetch('service') == service }
      raise ArgumentError, "#{context} の列数が一致しません" unless score.headers == SCORE_COLUMNS

      values = COUNTS.to_h { |name| [name, count(score[name], "#{context} #{name}")] }
      targets, correct, incorrect, unresolved, health = values.values_at(*COUNTS)
      seen = count(incident.fetch('new_people_seen_in_past'), 'new_people_seen_in_past')
      registrants_seen = count(incident.fetch('registrants_seen_in_past'), 'registrants_seen_in_past')
      service_size = count(incident.fetch('service_size'), 'service_size')
      recorded = count(incident.fetch('health_recorded_count'), 'health_recorded_count')
      all_correct = correct == targets

      unless targets.positive? && targets == incident.fetch('new_rows') && targets == correct + incorrect + unresolved &&
             all_correct.to_s == score['all_correct'] && health <= correct && health <= recorded && recorded <= targets &&
             correct <= seen && seen <= targets && seen <= registrants_seen && registrants_seen <= service_size && targets <= service_size
        raise ArgumentError, "#{context} の採点人数・全員正答フラグが事故生成記録と整合しません"
      end
      { 'seed' => seed, 'mask' => mask, 'service' => service }.merge(values).merge(
        'all_correct' => all_correct, 'seen_in_past' => seen, 'all_seen' => seen == targets,
        'service_size' => service_size, 'registrants_seen_in_past' => registrants_seen
      )
    end
  end

  # scripts/boundary-summary.sql と同じ両側95% Wilson区間。全成功・全失敗では端点を厳密にする。
  def wilson95(successes, trials)
    z = 1.959963984540054
    rate = successes.fdiv(trials)
    denom = 1 + z**2 / trials
    center = (rate + z**2 / (2 * trials)) / denom
    radius = z / denom * Math.sqrt(rate * (1 - rate) / trials + z**2 / (4 * trials**2))
    [successes.zero? ? 0.0 : center - radius, successes == trials ? 1.0 : center + radius]
  end

  def aggregate(rows)
    raise ArgumentError, '集計する反復がありません' if rows.empty?

    groups = rows.group_by { |r| [count(r.fetch('mask'), 'mask'), r.fetch('service')] }
    groups.sort.map do |(mask, service), trials|
      n = trials.size
      unless trials.map { |r| count(r.fetch('seed'), 'seed') }.uniq.size == n
        raise ArgumentError, "mask=#{mask}, service=#{service} の事故シードが重複しています"
      end
      # 本人の正答と健診結果の判明は別々に数える。全件特定の分母は人数でなく事故数。
      totals = (COUNTS + %w[seen_in_past service_size registrants_seen_in_past]).to_h do |name|
        [name, trials.sum { |r| count(r.fetch(name), name) }]
      end
      successes = true_count(trials, 'all_correct')
      all_seen = true_count(trials, 'all_seen')
      lower, upper = wilson95(successes, n)
      decision = if lower >= 0.8
                   'reached'
                 elsif upper < 0.8
                   'below'
                 else
                   'uncertain'
                 end
      targets, correct, incorrect, unresolved, health = totals.values_at(*COUNTS)
      {
        'mask' => mask, 'service' => service, 'trials' => n, 'successes' => successes, 'rate' => successes.fdiv(n),
        'lower95' => lower, 'upper95' => upper, 'decision' => decision, 'total_targets' => targets,
        'mean_correct' => correct.fdiv(n), 'mean_incorrect' => incorrect.fdiv(n), 'mean_unresolved' => unresolved.fdiv(n),
        'correct_rate' => correct.fdiv(targets), 'incorrect_rate' => incorrect.fdiv(targets),
        'unresolved_rate' => unresolved.fdiv(targets), 'mean_health' => health.fdiv(n),
        'mean_seen' => totals['seen_in_past'].fdiv(n), 'all_seen_rate' => all_seen.fdiv(n),
        'seen_rate' => totals['seen_in_past'].fdiv(targets),
        'registrants_seen_rate' => totals['registrants_seen_in_past'].fdiv(totals['service_size'])
      }
    end
  end
end
