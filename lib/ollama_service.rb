require "net/http"
require "uri"

module OllamaService
  DEFAULT_API_URL = "http://127.0.0.1:11434/api/tags".freeze
  LOCAL_HOSTS = ["localhost", "127.0.0.1", "::1"].freeze
  WINDOWS_INSTALL_PATHS = [
    ["LOCALAPPDATA", "Programs", "Ollama", "ollama.exe"],
    ["LOCALAPPDATA", "Ollama", "ollama.exe"],
  ].freeze

  module_function

  def ensure_started(config, out: STDOUT, wait_seconds: 15, sections: [:embedding, :chat])
    url = ollama_api_url(config, sections: sections)
    return true unless url

    return true if running?(url)

    unless local_url?(url)
      out << "Ollama provider configured at #{url}, but it is not reachable and cannot be auto-started as a remote service.\n"
      return false
    end

    executable = executable_path
    unless executable
      out << "Ollama is configured but could not be started: executable not found. Install Ollama, add it to PATH, or set OLLAMA_EXE.\n"
      return false
    end

    out << "Ollama is not running; starting `ollama serve`...\n"
    start(executable)

    deadline = Time.now + wait_seconds
    until Time.now >= deadline
      return true if running?(url)
      sleep 0.5
    end

    out << "Ollama did not become ready within #{wait_seconds} seconds. Try running `ollama serve` manually for details.\n"
    false
  rescue Errno::ENOENT
    out << "Ollama is configured but could not be started: executable not found. Install Ollama, add it to PATH, or set OLLAMA_EXE.\n"
    false
  rescue => e
    out << "Failed to check or start Ollama: #{concise_error(e)}\n"
    false
  end

  def ollama_api_url(config, sections: [:embedding, :chat])
    defaults = {
      embedding: "http://127.0.0.1:11434/api/embeddings",
      chat: "http://127.0.0.1:11434/api/chat",
    }
    urls = Array(sections).map do |section|
      section_url(config, section, defaults.fetch(section))
    end
    urls.compact.first&.then { |url| tags_url(url) }
  end

  def section_url(config, section, default_url)
    cfg_section = config.respond_to?(section) ? config.public_send(section) : nil
    return nil unless cfg_section

    provider = config_value(cfg_section, :provider)
    return nil unless provider.to_s.downcase == "ollama"

    config_value(cfg_section, :url) || default_url
  end

  def config_value(section, key)
    if section.respond_to?(key)
      section.public_send(key)
    elsif section.is_a?(Hash)
      section[key] || section[key.to_s]
    end
  end

  def tags_url(url)
    uri = URI(url)
    uri.host = "127.0.0.1" if uri.host.to_s.downcase == "localhost"
    uri.path = "/api/tags"
    uri.query = nil
    uri.fragment = nil
    uri.to_s
  rescue URI::InvalidURIError
    DEFAULT_API_URL
  end

  def running?(url)
    uri = URI(url)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 1, read_timeout: 2) do |http|
      http.get(uri.request_uri)
    end
    response.is_a?(Net::HTTPSuccess)
  rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ETIMEDOUT, Net::OpenTimeout, Net::ReadTimeout
    false
  end

  def local_url?(url)
    uri = URI(url)
    LOCAL_HOSTS.include?(uri.host.to_s.downcase)
  end

  def executable_path
    configured = ENV["OLLAMA_EXE"].to_s.strip
    return configured if executable_file?(configured)

    path_executable = find_on_path(Gem.win_platform? ? "ollama.exe" : "ollama")
    return path_executable if path_executable

    return unless Gem.win_platform?

    WINDOWS_INSTALL_PATHS.each do |env_name, *parts|
      base = ENV[env_name].to_s
      next if base.empty?

      candidate = File.join(base, *parts)
      return candidate if executable_file?(candidate)
    end
    nil
  end

  def find_on_path(command)
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |directory|
      next if directory.empty?

      candidate = File.join(directory, command)
      return candidate if executable_file?(candidate)
    end
    nil
  end

  def executable_file?(path)
    !path.to_s.empty? && File.file?(path) && (Gem.win_platform? || File.executable?(path))
  end

  def concise_error(error)
    message = error.message.to_s.lines.first.to_s.strip
    message.empty? ? error.class.to_s : "#{error.class}: #{message}"
  end

  def start(executable)
    pid = Process.spawn(executable, "serve", out: File::NULL, err: File::NULL)
    Process.detach(pid)
  end
end
