require "pathname"

require_relative "cache"

require_relative "../llm/openai"
require_relative "../llm/embedding"

require_relative "../readers/reader"

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