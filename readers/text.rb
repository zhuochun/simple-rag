
require_relative "utils/chunk_utils"
require_relative "utils/markdown_utils"

class TextReader
    include ChunkUtils
    include MarkdownUtils

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
        super(text, preserve_heading_markers: true, compact_blank_lines: true)
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
        discard_small_trailing_chunk(chunks, max_tokens)
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
