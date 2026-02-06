module ProviderEnvValidator
  REQUIRED_ENV_BY_PROVIDER = {
    "openai" => "DOT_OPENAI_KEY",
    "gemini" => "DOT_GEMINI_KEY",
    "openrouter" => "DOT_OPENROUTER_KEY",
  }.freeze

  module_function

  def missing_key_message(config)
    providers = [
      provider_name(config, :chat),
      provider_name(config, :embedding),
    ].compact.map(&:downcase).uniq

    providers.each do |provider|
      env_key = REQUIRED_ENV_BY_PROVIDER[provider]
      next if env_key.nil?
      return "Remember to set env #{env_key}" if ENV[env_key].to_s.empty?
    end

    nil
  end

  def provider_name(config, section)
    cfg_section = config.respond_to?(section) ? config.public_send(section) : nil
    return nil if cfg_section.nil?

    if cfg_section.respond_to?(:provider)
      cfg_section.provider
    elsif cfg_section.is_a?(Hash)
      cfg_section[:provider] || cfg_section["provider"]
    end
  end
end
