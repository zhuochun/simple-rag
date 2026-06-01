
class TextReader
    include ChunkUtils

    attr_accessor :file, :chunks

    def initialize(file)
        @file = file
        @loaded = false
        @chunks = []
    end

    MAX_WORDS = 1000
    MIN_WORDS = 10
    FRONTMATTER_START = /\A---\s*$/
    FRONTMATTER_END = /\A(?:---|\.\.\.)\s*$/

    def load
        return self if @loaded
        unless File.exist?(@file)
            @loaded = true
            return self
        end

        begin
            raw = File.read(@file)
            body = extract_body_without_frontmatter(raw)
            filtered = filter_notion_lines(body)
            @chunks = build_index_chunks(filtered)
        rescue Errno::ENOENT
            # file was removed after existence check; skip loading
        end

        @chunks = filter_small_chunks(@chunks, MIN_WORDS)
        @loaded = true

        self
    end

    def get_chunk(idx)
        return nil if @chunks.empty?
        index = idx || 0
        return nil if index >= @chunks.length || index < -@chunks.length
        @chunks[index]
    end

    private

    def extract_body_without_frontmatter(raw)
        return "" if raw.nil? || raw.empty?

        lines = raw.lines
        return raw unless lines[0]&.match?(FRONTMATTER_START)

        body_start = nil
        lines.each_with_index do |line, idx|
            next if idx.zero?
            if line.match?(FRONTMATTER_END)
                body_start = idx + 1
                break
            end
        end

        return raw if body_start.nil?
        lines[body_start..]&.join.to_s
    end

    def skip_notion_metadata_line?(line)
        stripped = line.lstrip
        (line.start_with?('- ') && line.include?(':')) ||
            line.start_with?('  - [[') ||
            stripped.start_with?('<')
    end

    def filter_notion_lines(text)
        return "" if text.nil? || text.empty?

        kept = []
        fence = nil
        text.each_line do |line|
            if fence
                kept << line
                fence = nil if closing_fence?(line, fence)
                next
            end

            opening_fence = parse_opening_fence(line)
            if opening_fence
                kept << line
                fence = opening_fence
                next
            end

            stripped = line.strip
            next if stripped == "---"
            next if skip_notion_metadata_line?(line)
            kept << line
        end
        kept.join
    end

    def strip_markdown(text)
        return "" if text.nil? || text.empty?

        s = text.dup

        # Strip reference-style link declarations and markdown images.
        s.gsub!(/^\s*\[[^\]]+\]:\s+\S+.*$/, "")
        s.gsub!(/!\[[^\]]*\]\([^\)]*\)/, " ")
        s.gsub!(/!\[[^\]]*\]\[[^\]]*\]/, " ")

        # Handle Notion wiki links first, including display text with brackets.
        s.gsub!(/\[\[([^|\]]+)\|(.*?)\]\]/, '\2')
        s.gsub!(/\[\[([^\]]+)\]\]/, '\1')

        # Keep readable link labels while removing URLs.
        s.gsub!(/\[([^\]]+)\]\([^\)]*\)/, '\1')
        s.gsub!(/\[([^\]]+)\]\[[^\]]*\]/, '\1')

        # Strip HTML tags and bare URLs.
        s.gsub!(%r{<[^>]+>}, " ")
        s.gsub!(%r{https?://\S+}, " ")

        # Remove markdown punctuation while keeping heading markers.
        s.gsub!(/^[ \t]*>+[ \t]?/, "")
        s.gsub!(/^[ \t]*[-*+][ \t]+/, "")
        s.gsub!(/^[ \t]*\d+\.[ \t]+/, "")
        s.gsub!(/^[ \t]*\[(?: |x|X)\][ \t]+/, "")
        s.gsub!(/[`*_~]/, "")

        # Normalize whitespace and collapse unnecessary empty lines.
        normalized = s.lines.map { |line| line.gsub(/[ \t]+/, " ").strip }
        compact = []
        normalized.each do |line|
            if line.empty?
                next if compact.empty? || compact.last.empty?
                compact << ""
            else
                compact << line
            end
        end

        compact.join("\n").strip
    end

    def build_index_chunks(text, max_tokens = MAX_WORDS)
        base_chunks = threshold_chunks(text, max_tokens)
        return [] if base_chunks.empty?

        h1 = first_heading_1(text)
        return base_chunks if h1.nil? || h1.empty?

        cleaned_h1 = strip_markdown(h1)
        base_chunks.map do |chunk|
            chunk.start_with?(cleaned_h1) ? chunk : "#{cleaned_h1}\n\n#{chunk}"
        end
    end

    def threshold_chunks(text, max_tokens)
        return [] if text.nil? || text.empty?

        sections = split_by_headings(text).map { |section| strip_markdown(section) }
        sections.reject!(&:empty?)

        if sections.length <= 1
            return split_chunk_by_tokens(sections.first.to_s, max_tokens)
        end

        chunks = []
        current = []
        current_tokens = 0

        sections.each do |section|
            section_tokens = count_tokens(section)

            if section_tokens > max_tokens
                if current.any?
                    chunks << current.join("\n\n")
                    current = []
                    current_tokens = 0
                end
                chunks.concat(split_chunk_by_tokens(section, max_tokens))
                next
            end

            extra_tokens = current.empty? ? 0 : 1
            if current.any? && (current_tokens + section_tokens + extra_tokens > max_tokens)
                chunks << current.join("\n\n")
                current = [section]
                current_tokens = section_tokens
            else
                current << section
                current_tokens += section_tokens + extra_tokens
            end
        end

        chunks << current.join("\n\n") if current.any?
        chunks
    end

    def split_by_headings(text)
        lines = text.split("\n")
        sections = []
        current = []
        fence = nil

        lines.each do |line|
            if fence
                current << line
                fence = nil if closing_fence?(line, fence)
                next
            end

            opening_fence = parse_opening_fence(line)
            if opening_fence
                current << line
                fence = opening_fence
                next
            end

            if heading_line?(line) && current.any?
                section = current.join("\n").strip
                sections << section unless section.empty?
                current = []
            end

            current << line
        end

        section = current.join("\n").strip
        sections << section unless section.empty?
        sections
    end

    def heading_line?(line)
        !!(line =~ /^\s{0,3}[#]{1,6}\s+\S+/)
    end

    def parse_opening_fence(line)
        match = line.match(/^\s{0,3}(`{3,}|~{3,})/)
        return nil unless match

        { marker: match[1][0], length: match[1].length }
    end

    def closing_fence?(line, fence)
        marker = Regexp.escape(fence[:marker])
        !!(line =~ /^\s{0,3}#{marker}{#{fence[:length]},}\s*$/)
    end

    def first_heading_1(text)
        return nil if text.nil? || text.empty?

        fence = nil
        text.each_line do |line|
            if fence
                fence = nil if closing_fence?(line, fence)
                next
            end

            opening_fence = parse_opening_fence(line)
            if opening_fence
                fence = opening_fence
                next
            end

            stripped = line.strip
            return stripped if stripped =~ /^#\s+\S+/
        end
        nil
    end
end
