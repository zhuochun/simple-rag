module ConfigPathResolver
  module_function

  def default_candidates
    [
      File.expand_path("config.json", Dir.pwd),
      File.expand_path("~/.config/simple-rag/config.json"),
    ]
  end

  def resolve_config_path(arg = nil)
    raw = arg.to_s.strip
    return File.expand_path(raw) unless raw.empty?

    default_candidates.find { |path| File.exist?(path) }
  end

  def default_search_message
    paths = default_candidates.map { |p| "  - #{p}" }.join("\n")
    "No config file provided and no default config found.\nChecked:\n#{paths}\nPass an explicit config path."
  end
end
