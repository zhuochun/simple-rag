class MarkdownReader
    include ChunkUtils

    MAX_WORDS = 1000
    MIN_WORDS = 10

    FRONTMATTER_START = /\A---\s*$/
    FRONTMATTER_END = /\A(?:---|\.\.\.)\s*$/

    attr_accessor :file, :chunks

    def initialize(file)
        @file = file
        @loaded = false
        @chunks = []
    end

    def load
        return self if @loaded

        unless File.exist?(@file)
            @loaded = true
            return self
        end

        begin
            raw = File.read(@file)
            title, status, body = extract_frontmatter_and_body(raw)
            if skip_by_status?(status)
                @loaded = true
                return self
            end
            @chunks = build_index_chunks(title, body)
        rescue Errno::ENOENT
            @loaded = true
            return self
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

    def extract_frontmatter_and_body(raw)
        return [nil, nil, raw] if raw.nil? || raw.empty?

        lines = raw.lines
        return [nil, nil, raw] unless lines[0]&.match?(FRONTMATTER_START)

        fm_lines = []
        body_start = nil

        lines.each_with_index do |line, idx|
            next if idx.zero?

            if line.match?(FRONTMATTER_END)
                body_start = idx + 1
                break
            end

            fm_lines << line
        end

        return [nil, nil, raw] if body_start.nil?

        frontmatter = fm_lines.join
        title = extract_title_from_frontmatter(frontmatter)
        status = extract_status_from_frontmatter(frontmatter)
        body = lines[body_start..]&.join.to_s
        [title, status, body]
    end

    def extract_title_from_frontmatter(frontmatter)
        return nil if frontmatter.nil? || frontmatter.empty?

        frontmatter.each_line do |line|
            if line =~ /^\s*title\s*:\s*(.+?)\s*$/
                return unquote_yaml_scalar($1.strip)
            end
        end

        nil
    end

    def unquote_yaml_scalar(value)
        return "" if value.nil?
        stripped = value.strip
        if (stripped.start_with?('"') && stripped.end_with?('"')) ||
           (stripped.start_with?("'") && stripped.end_with?("'"))
            stripped = stripped[1...-1]
        end
        stripped
    end

    def extract_status_from_frontmatter(frontmatter)
        return nil if frontmatter.nil? || frontmatter.empty?

        frontmatter.each_line do |line|
            if line =~ /^\s*status\s*:\s*(.+?)\s*$/
                return unquote_yaml_scalar($1.strip)
            end
        end

        nil
    end

    def skip_by_status?(status)
        return true if status.nil? || status.empty?
        status.downcase == "seed"
    end

    def build_index_text(title, body)
        cleaned = strip_markdown(body)
        if title && !title.empty?
            return title if cleaned.empty?
            "#{title}\n\n#{cleaned}"
        else
            cleaned
        end
    end

    def strip_markdown(text)
        return "" if text.nil? || text.empty?

        s = text.dup

        # Strip reference-style link declarations and markdown images.
        s.gsub!(/^\s*\[[^\]]+\]:\s+\S+.*$/, "")
        s.gsub!(/!\[[^\]]*\]\([^\)]*\)/, " ")
        s.gsub!(/!\[[^\]]*\]\[[^\]]*\]/, " ")

        # Keep readable link labels while removing URLs.
        s.gsub!(/\[([^\]]+)\]\([^\)]*\)/, '\1')
        s.gsub!(/\[([^\]]+)\]\[[^\]]*\]/, '\1')

        # Strip wiki links and HTML.
        s.gsub!(/\[\[([^\]|]+)\|([^\]]+)\]\]/, '\2')
        s.gsub!(/\[\[([^\]]+)\]\]/, '\1')
        s.gsub!(%r{<[^>]+>}, " ")

        # Remove markdown punctuation while retaining text.
        s.gsub!(/^\s{0,3}(#{Regexp.union(["#", ">", "-", "*", "+"]).source})\s+/, "")
        s.gsub!(/^\s*\d+\.\s+/, "")
        s.gsub!(/[`*_~]/, "")

        # Drop bare URLs and normalize whitespace.
        s.gsub!(%r{https?://\S+}, " ")
        s.gsub!(/[ \t]+/, " ")
        s.gsub!(/\n{3,}/, "\n\n")

        s.lines.map(&:strip).join("\n").strip
    end

    def build_index_chunks(title, body)
        cleaned = strip_markdown(body)
        base_chunks = threshold_chunks(cleaned, MAX_WORDS)

        # If the file only has frontmatter title and no body, still index the title.
        if base_chunks.empty?
            return [] if title.nil? || title.empty?
            return [title]
        end

        if title && !title.empty?
            base_chunks.map { |chunk| "#{title}\n\n#{chunk}" }
        else
            base_chunks
        end
    end

    def threshold_chunks(text, max_tokens)
        return [] if text.nil? || text.empty?

        sections = split_by_headings(text)
        if sections.length <= 1
            return split_chunk_by_tokens(text, max_tokens)
        end

        chunks = []
        current = []
        current_tokens = 0

        sections.each do |section|
            section_tokens = count_tokens(section)

            # If a single heading section is too large, fall back to paragraph/line/token splitting.
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

        lines.each do |line|
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
end
