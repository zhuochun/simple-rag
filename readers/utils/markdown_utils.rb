module MarkdownUtils
    def strip_markdown(text, preserve_heading_markers: false, compact_blank_lines: true)
        return "" if text.nil? || text.empty?

        s = text.dup

        # Strip reference-style link declarations and markdown images.
        s.gsub!(/^\s*\[[^\]]+\]:\s+\S+.*$/, "")
        s.gsub!(/!\[[^\]]*\]\([^\)]*\)/, " ")
        s.gsub!(/!\[[^\]]*\]\[[^\]]*\]/, " ")

        # Handle wiki links before standard links so display labels may contain brackets.
        s.gsub!(/\[\[([^|\]]+)\|(.*?)\]\]/, '\2')
        s.gsub!(/\[\[([^\]]+)\]\]/, '\1')
        s = strip_markdown_link_urls(s)
        s.gsub!(/\[([^\]]+)\]\[[^\]]*\]/, '\1')

        # Strip HTML tags, bare URLs, and line-level markdown punctuation.
        s.gsub!(%r{<[^>]+>}, " ")
        s.gsub!(%r{https?://\S+}, " ")
        s.gsub!(/^[ \t]*>+[ \t]?/, "")
        s.gsub!(/^[ \t]*[-*+]?[ \t]*\[(?: |x|X)\][ \t]+/, "")
        s.gsub!(/^[ \t]*[-*+][ \t]+/, "")
        s.gsub!(/^[ \t]*\d+\.[ \t]+/, "")
        s.gsub!(/^\s{0,3}#+\s+/, "") unless preserve_heading_markers
        s.gsub!(/[`*_~]/, "")

        normalized = s.lines.map { |line| line.gsub(/[ \t]+/, " ").strip }
        normalized = compact_blank_lines(normalized) if compact_blank_lines
        normalized.join("\n").strip
    end

    def strip_markdown_link_urls(text)
        text.gsub(/\[([^\]]+)\]\([^\)]*\)/, '\1')
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

    private

    def compact_blank_lines(lines)
        lines.each_with_object([]) do |line, compact|
            next if line.empty? && (compact.empty? || compact.last.empty?)
            compact << line
        end
    end
end
