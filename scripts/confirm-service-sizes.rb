# frozen_string_literal: true

require 'csv'
require 'json'

abort '使い方: ruby scripts/confirm-service-sizes.rb 境界.csv 新規出力.csv' unless ARGV.size == 2
profiles = %w[flat large small dense]
rules = %w[rate12 rate24 count120 count240]
boundaries = CSV.read(ARGV.first, headers: true).select do |r|
  r.fetch('first_type') == 'A' && profiles.include?(r.fetch('profile')) && rules.include?(r.fetch('rule'))
end
unless boundaries.map { |r| r.values_at('profile', 'rule') }.sort == profiles.product(rules).sort
  abort '検証する16条件に欠落または重複があります'
end
input = boundaries.map do |r|
  {
    profile: r['profile'], rule: r['rule'], first_services: Integer(r.fetch('first_services')),
    roster: %w[roster_a roster_b].map { |key| Integer(r.fetch(key)) },
    common: %w[common_a common_b].map { |key| Integer(r.fetch(key)) },
    leaked: %w[leaked_a leaked_b].map { |key| Integer(r.fetch(key)) },
    exact: %w[p_before p_at].map { |key| Float(r.fetch(key)) }
  }
end
command = %w[cargo run --release --locked --example multiservice_leaks -- --size-study --output] + [ARGV.last]
IO.popen(command, 'w') { |pipe| pipe.write(JSON.generate(input)) }
exit($?.success? ? 0 : 1)
