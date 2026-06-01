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

    def build_index_chunks(title, body, max_tokens = MAX_WORDS)
        base_chunks = threshold_chunks(body, max_tokens)

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

        sections = split_by_headings(text).map { |section| clean_section(section) }
        sections.reject! { |section| section[:text].empty? }

        if sections.length <= 1
            return [] if sections.empty?
            return split_oversized_section(sections.first, max_tokens)
        end

        chunks = []
        current = []
        current_tokens = 0

        sections.each do |section|
            section_tokens = count_tokens(section[:text])

            # If a single heading section is too large, fall back to paragraph/line/token splitting.
            if section_tokens > max_tokens
                if current.any?
                    chunks << current.join("\n\n")
                    current = []
                    current_tokens = 0
                end
                chunks.concat(split_oversized_section(section, max_tokens))
                next
            end

            extra_tokens = current.empty? ? 0 : 1
            if current.any? && (current_tokens + section_tokens + extra_tokens > max_tokens)
                chunks << current.join("\n\n")
                current = [section[:text]]
                current_tokens = section_tokens
            else
                current << section[:text]
                current_tokens += section_tokens + extra_tokens
            end
        end

        chunks << current.join("\n\n") if current.any?
        chunks
    end

    def split_by_headings(text)
        lines = text.split("\n")
        sections = []
        heading_path = []
        current = { heading_path: [], lines: [] }
        fence = nil

        lines.each do |line|
            if fence
                current[:lines] << line
                fence = nil if closing_fence?(line, fence)
                next
            end

            opening_fence = parse_opening_fence(line)
            if opening_fence
                current[:lines] << line
                fence = opening_fence
                next
            end

            heading = parse_heading(line)
            if heading
                sections << current if section_has_body?(current)

                level, title = heading
                heading_path = heading_path.first(level - 1)
                heading_path[level - 1] = title
                current = { heading_path: heading_path.compact, lines: [] }
            else
                current[:lines] << line
            end
        end

        sections << current if current[:lines].any? || current[:heading_path].any?

        sections
    end

    def section_has_body?(section)
        section[:lines].any? { |line| !line.strip.empty? }
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

    def parse_heading(line)
        match = line.match(/^\s{0,3}([#]{1,6})\s+(.+?)\s*$/)
        return nil unless match

        title = match[2].sub(/\s+#+\s*$/, "")
        [match[1].length, strip_markdown(title)]
    end

    def clean_section(section)
        heading_path = section[:heading_path]
        body = strip_markdown(section[:lines].join("\n"))
        {
            heading_path: heading_path,
            body: body,
            text: join_section_text(heading_path, body),
        }
    end

    def split_oversized_section(section, max_tokens)
        return split_chunk_by_tokens(section[:text], max_tokens) if section[:heading_path].empty?

        heading_text = section[:heading_path].join("\n\n")
        available_tokens = max_tokens - count_tokens(heading_text)
        return split_chunk_by_tokens(section[:text], max_tokens) if available_tokens <= 0

        body_chunks = split_chunk_by_tokens(section[:body], available_tokens)
        return [heading_text] if body_chunks.empty?

        body_chunks.map { |body| join_section_text(section[:heading_path], body.strip) }
    end

    def join_section_text(heading_path, body)
        parts = heading_path.dup
        parts << body unless body.empty?
        parts.join("\n\n")
    end
end
