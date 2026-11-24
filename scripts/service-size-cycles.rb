# frozen_string_literal: true

require_relative 'multiservice-balanced'
require_relative 'service_size_designs'

if $PROGRAM_NAME == __FILE__
  csv = CSV.new($stdout)
  csv << %w[profile roster_a roster_b common_a common_b rule leaked_a leaked_b cycle_services first_services
            p_before p_at d_before d_at first_type]
  population = MultiServiceBounds::POPULATION
  sample = MultiServiceBounds::SAMPLE
  ServiceSizeDesigns::PROFILES.each do |profile, (n_a, n_b, c_a, c_b)|
    pairs, remainder = population.divmod(c_a + c_b)
    raise '共通登録者の群で新規名簿を分割できません' unless remainder.zero? && pairs.positive?

    ServiceSizeDesigns::RULES.each do |rule|
      leaked_a, leaked_b = [n_a, n_b].map { |n| ServiceSizeDesigns.leaked(rule, n) }
      a = FixedServiceCohort.new(roster: n_a, common: c_a, leaked: leaked_a, sample: sample)
      b = FixedServiceCohort.new(roster: n_b, common: c_b, leaked: leaked_b, sample: sample)
      { 'A' => [a, b], 'B' => [b, a] }.each do |first_type, pair|
        model = CyclicServiceLeaks.new(cohorts: pair * pairs, sample: sample)
        crossing = model.first_crossing(Rational(4, 5), 2000)
        raise '調査範囲内に到達点がありません' unless crossing

        k, before, at = crossing
        csv << [profile, n_a, n_b, c_a, c_b, rule, leaked_a, leaked_b, 2 * pairs, k,
                *[before, at].map { |p| format('%.15g', p.to_f) },
                model.multiple_registrants(k - 1), model.multiple_registrants(k), first_type]
      end
    end
  end
end
