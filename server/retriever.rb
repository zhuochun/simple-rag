require "pathname"

require_relative "cache"
require_relative "../llm/llm"
require_relative "../llm/embedding"
require_relative "../readers/reader"
require_relative "../storage/index_cache"

AGENT_PROMPT = <<~PROMPT
Expand the user input to a better search query so it is easier to retrieve related markdown
documents using embedding. Return only the expanded query in a single line.
PROMPT

def expand_query(q)
    msgs = [
        { role: ROLE_SYSTEM, content: AGENT_PROMPT },
        { role: ROLE_USER, content: q },
    ]

    query = chat(msgs).strip
    STDOUT << "Expand query: #{query}\n"

    query
end

def retrieve_by_embedding(lookup_paths, q)
    qe = CACHE.get_or_set(q, method(:embedding).to_proc)
    qn = normalize_embedding(qe)

    entries = []
    lookup_paths.each do |p|
        STDOUT << "Reading index: #{p.name}\n"

        index = load_index_cache(p)
        next unless index
        reader_cls = index.reader_cls
        next unless reader_cls

        bucket_ids = neighbor_keys(bucket_key(qn)).flat_map { |k| index.buckets[k] }.uniq
        bucket_ids.each do |idx|
            item = index.items[idx]

            score = dot_product(qn, item[:embedding])
            next if score < p.threshold

            entries << {
                "path" => item[:path],
                "chunk" => item[:chunk],
                "score" => score,
                "lookup" => p.name,
                "id" => extract_id(item[:path]),
                "url" => extract_url(item[:path], p.url),
                "reader" => reader_cls.new(item[:path])
            }
        end

        STDOUT << "Matched num: #{entries.length}\n"
    end

    entries
end

def extract_id(file_path)
    path = Pathname.new(file_path)
    File.join(path.each_filename.to_a[-2..-1])
end

def extract_url(file_path, url)
    if url
        path = Pathname.new(file_path)
        # Extract the filename without the extension
        filename_without_extension = path.basename(path.extname).to_s
        # Return the final URL
        "#{url}#{filename_without_extension}"
    else
        "file://#{file_path}"
    end
end

VARIANT_PROMPT = <<~PROMPT
Generate three alternative search keywords based on the user input to retrieve related markdown using exact keyword matches.
Return the search keywords in one CSV line.
PROMPT

def expand_variants(q)
    msgs = [
        { role: ROLE_SYSTEM, content: VARIANT_PROMPT },
        { role: ROLE_USER, content: q },
    ]

    variants = chat(msgs).split(',')
    STDOUT << "Expand variants: #{variants}\n"
    variants
end

def retrieve_by_text(lookup_paths, q)
    entries = []
    lookup_paths.each do |p|
        STDOUT << "Reading text index: #{p.name}\n"

        index_file = File.expand_path(p.out)
        next unless File.exist?(index_file)

        reader_cls = get_reader(p.reader)
        next if reader_cls.nil?

        file_cache = {}
        File.foreach(index_file) do |line|
            item = JSON.parse(line)
            reader = file_cache[item["path"]] ||= reader_cls.new(item["path"]).load
            chunk_text = reader.get_chunk(item["chunk"])
            next unless chunk_text&.include?(q)

            item["score"] = 1.0
            item["lookup"] = p.name
            item["id"] = extract_id(item["path"])
            item["url"] = extract_url(item["path"], p.url)
            item["reader"] = reader

            entries << item
        end

        STDOUT << "Matched num: #{entries.length}\n"
    end

    entries
end