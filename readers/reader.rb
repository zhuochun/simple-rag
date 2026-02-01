READERS = %w[text note journal]

module ChunkUtils
    DEFAULT_MAX_TOKENS = 1000
    DEFAULT_MIN_TOKENS = 10

    def count_tokens(str)
        return 0 if str.nil? || str.empty?
        tokens = str.scan(/[\p{Han}]|[\p{L}\p{N}]+|[^\s]/)
        tokens.length
    end

    def split_chunk_by_tokens(text, max_tokens = DEFAULT_MAX_TOKENS)
        return [] if text.nil? || text.empty?
        return [text] if count_tokens(text) <= max_tokens

        parts = []
        paragraphs = text.split(/\n{2,}/)
        current = []
        current_tokens = 0

        paragraphs.each do |para|
            para_tokens = count_tokens(para)

            if para_tokens > max_tokens
                if current.any?
                    parts << current.join("\n\n")
                    current = []
                    current_tokens = 0
                end
                parts.concat(split_large_block_by_lines(para, max_tokens))
                next
            end

            if current_tokens + para_tokens + (current.empty? ? 0 : 1) > max_tokens
                parts << current.join("\n\n")
                current = [para]
                current_tokens = para_tokens
            else
                current << para
                current_tokens += para_tokens
            end
        end

        parts << current.join("\n\n") if current.any?
        parts
    end

    def split_large_block_by_lines(text, max_tokens)
        parts = []
        lines = text.split("\n")
        current = []
        current_tokens = 0

        lines.each do |line|
            line_tokens = count_tokens(line)

            if line_tokens > max_tokens
                if current.any?
                    parts << current.join("\n")
                    current = []
                    current_tokens = 0
                end
                parts.concat(split_hard_by_chars(line, max_tokens))
                next
            end

            if current_tokens + line_tokens + (current.empty? ? 0 : 1) > max_tokens
                parts << current.join("\n")
                current = [line]
                current_tokens = line_tokens
            else
                current << line
                current_tokens += line_tokens
            end
        end

        parts << current.join("\n") if current.any?
        parts
    end

    def split_hard_by_chars(text, max_tokens)
        max_chars = [max_tokens * 4, 1000].max
        text.scan(/.{1,#{max_chars}}/m)
    end

    def filter_small_chunks(chunks, min_tokens = DEFAULT_MIN_TOKENS)
        chunks.select { |c| count_tokens(c) >= min_tokens }
    end
end

def get_reader(name)
    case name.to_s.downcase
    when "text"
        require_relative "text"
        TextReader
    when "note"
        require_relative "note"
        NoteReader
    when "journal"
        require_relative "journal"
        JournalReader
    else
        nil
    end
end

def available_readers
    READERS
end
