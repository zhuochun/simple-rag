module ProviderEnvValidator
  REQUIRED_ENV_BY_PROVIDER = {
    "openai" => "DOT_OPENAI_KEY",
    "gemini" => "DOT_GEMINI_KEY",
    "openrouter" => "DOT_OPENROUTER_KEY",
  }.freeze

  module_function

  def missing_key_message(config, sections: [:chat, :embedding])
    providers = Array(sections).filter_map do |section|
      provider_name(config, section)
    end.map(&:downcase).uniq

    providers.each do |provider|
      env_key = REQUIRED_ENV_BY_PROVIDER[provider]
      next if env_key.nil?
      next unless ENV[env_key].to_s.empty?
      return <<~MSG.strip
        Missing API key for provider "#{provider}".
        Required env var: #{env_key}
        PowerShell (current session): $env:#{env_key}="YOUR_KEY"
        cmd.exe (current session): set #{env_key}=YOUR_KEY
      MSG
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
