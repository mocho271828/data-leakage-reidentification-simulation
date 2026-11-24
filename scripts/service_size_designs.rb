# frozen_string_literal: true

module ServiceSizeDesigns
  # [A社の登録者数, B社の登録者数, A社の共通人数, B社の共通人数]
  PROFILES = {
    'previous' => [1000, 1000, 1000, 1000],
    'dense' => [500, 1500, 500, 1500],
    'same_half' => [1000, 1000, 500, 500],
    'flat' => [750, 1250, 500, 500],
    'large' => [750, 1250, 250, 750],
    'small' => [750, 1250, 750, 250],
    'equal_large' => [1000, 1000, 250, 750],
    'equal_small' => [1000, 1000, 750, 250],
    'sparse' => [750, 1250, 250, 250]
  }.each_value(&:freeze).freeze

  RULES = %w[rate12 rate24 full count120 count240].freeze

  def self.leaked(rule, roster)
    case rule
    when 'rate12', 'rate24'
      count, remainder = (roster * (rule == 'rate12' ? 12 : 24)).divmod(100)
      raise ArgumentError, '漏えい人数が整数になる名簿を指定してください' unless remainder.zero?

      count
    when 'full' then roster
    when 'count120', 'count240'
      count = rule == 'count120' ? 120 : 240
      raise ArgumentError, '漏えい人数が登録者数を超えています' if count > roster

      count
    else raise ArgumentError, "不明な漏えい条件: #{rule}"
    end
  end
end
