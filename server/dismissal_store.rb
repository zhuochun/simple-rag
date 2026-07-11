require "fileutils"
require "set"
require "tempfile"
require "thread"

module SimpleRag
  class DismissalStore
    def initialize(path)
      @path = path.to_s.strip
      @path = nil if @path.empty?
      @mutex = Mutex.new
      @ids = load_ids
    end

    def include?(id)
      @mutex.synchronize { @ids.include?(id.to_s) }
    end

    def dismiss(id)
      value = id.to_s.strip
      return false if value.empty?

      @mutex.synchronize do
        return false if @ids.include?(value)

        updated = @ids.dup.add(value)
        persist!(updated) if @path
        @ids = updated
        true
      end
    end

    private

    def load_ids
      return Set.new unless @path && File.file?(@path)

      Set.new(File.read(@path, encoding: "UTF-8").split(/\n+/).map(&:strip).reject(&:empty?))
    end

    def persist!(ids)
      directory = File.dirname(File.expand_path(@path))
      FileUtils.mkdir_p(directory)
      temp = Tempfile.new([".#{File.basename(@path)}.", ".tmp"], directory, encoding: "UTF-8")
      begin
        ids.to_a.sort.each { |id| temp.puts(id) }
        temp.flush
        temp.fsync
        temp.close
        File.rename(temp.path, @path)
      ensure
        temp.close unless temp.closed?
        temp.unlink if File.exist?(temp.path)
      end
    end
  end
end
