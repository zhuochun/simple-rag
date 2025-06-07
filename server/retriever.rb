require "pathname"

require_relative "cache"

require_relative "../llm/llm"

require_relative "../readers/reader"

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

    entries = []
    lookup_paths.each do |p|
        STDOUT << "Reading index: #{p.name}\n"

        index_file = File.expand_path(p.out)
        unless File.exist?(index_file)
            STDOUT << "Path not exists! path: #{index_file}\n"
            next
        end

        reader = get_reader(p.reader)
        if reader.nil?
            STDOUT << "Reader undefinied! reader: #{path.reader}\n"
            next
        end

        File.foreach(index_file) do |line|
            item = JSON.parse(line)

            score = cosine_similarity(qe, item["embedding"])
            next if score < p.threshold

            item["score"] = score
            item["lookup"] = p.name
            item["id"] = extract_id(item["path"])
            item["url"] = extract_url(item["path"], p.url)
            item["reader"] = reader.new(item["path"])

            entries << item
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