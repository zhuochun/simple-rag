require "json"
require "digest"
require "set"
require_relative "config_loader"
require_relative "../storage/sqlite_index"
require_relative "../llm/embedding"

module SimpleRag
  # Separate from the web chunk-cluster finder: source connections never migrate schemas.
  class DuplicateAudit
    def initialize(paths:, threshold: 0.95, coverage: 0.8, neighbors: 64, limit: 20,
                   prefix: nil, evidence: 3, brief_chars: 240)
      @paths, @threshold, @coverage = paths, threshold, coverage
      @neighbors, @limit, @prefix = neighbors, limit, prefix && canonical(prefix)
      @evidence, @brief_chars = evidence, brief_chars
      raise ArgumentError, "threshold and coverage must be finite and in (0, 1]" unless
        [threshold, coverage].all? { |v| v.finite? && v > 0 && v <= 1 }
      raise ArgumentError, "neighbors must be 2..4096" unless (2..4096).cover?(neighbors)
      raise ArgumentError, "limit, evidence and brief-chars must be positive" unless
        [limit, evidence, brief_chars].all? { |v| v > 0 }
    end

    def run
      @warnings = ["Embedding model provenance is not stored by this index schema; same-dimension mixed models cannot be detected.",
                   "Coverage describes indexed chunks, not the full source. Semantic similarity is not proof of duplication."]
      @documents, @rows, @dimensions, @diagnostics = {}, {}, Set.new, []
      store = SqliteIndex.new(":memory:", "audit")
      @paths.sort_by(&:name).each { |path| load_path(path, store) }
      pairs = Hash.new { |hash, key| hash[key] = {} }
      saturated = 0
      store.each_vector_neighborhood(@neighbors, threshold: @threshold) do |row, hits|
        saturated += 1 if hits.length == @neighbors && hits.last["score"] >= @threshold
        hits.each do |hit|
          next if hit["path"] == row["path"] || hit["score"] < @threshold
          left, right = [row, hit].sort_by { |r| r["path"] }
          pair = [left["path"], right["path"]]
          key = [left["chunk"], right["chunk"]]
          pairs[pair][key] = [pairs[pair][key] || -1.0, hit["score"]].max
        end
      end
      @warnings << "#{saturated} chunk searches reached the neighbor cap above threshold; candidates/coverage may be missed. Increase --neighbors or narrow --paths/--prefix." if saturated > 0
      accepted = 0
      best = []
      pairs.each do |members, matches|
        candidate = aggregate(members, matches)
        next unless candidate
        accepted += 1
        best << candidate
        best.sort_by! { |c| [-c[:coverage].values.map { |v| v[:characters] }.min, -c[:similarity][:mean], c[:members]] }
        best.pop if best.length > @limit
      end
      {schema_version: 1, purpose: "Human review leads only; never deletion decisions",
       algorithm: "Overlapping two-document complete-link clusters; no transitive merging",
       parameters: {threshold: @threshold, coverage: @coverage, neighbors: @neighbors,
                    limit: @limit, prefix: @prefix, paths: @paths.map(&:name).sort},
       stats: {documents: @documents.length, chunks: @rows.length, dimensions: @dimensions.to_a.sort,
               candidate_pairs: pairs.length, qualifying_pairs: accepted, returned_clusters: best.length,
               truncated: accepted > best.length, saturated_queries: saturated},
       indexes: @diagnostics, warnings: @warnings.uniq.sort, clusters: best}
    ensure
      store&.close
    end

    def self.text(report)
      lines = [report[:purpose], "#{report[:stats][:documents]} documents, #{report[:stats][:chunks]} chunks; #{report[:stats][:qualifying_pairs]} qualifying pairs (#{report[:stats][:returned_clusters]} shown)"]
      report[:warnings].each { |warning| lines << "Warning: #{warning}" }
      report[:indexes].each { |index| lines << "Index #{index[:name]}: #{index.reject { |k, _| k == :name }.to_json}" }
      report[:clusters].each_with_index do |cluster, index|
        lines << "\nCluster #{index + 1}: cosine min/mean #{cluster[:similarity].values.join('/')}"
        cluster[:members].each do |file|
          coverage = cluster[:coverage][file]
          lines << "  #{file} (chunks #{coverage[:matched_chunks]}/#{coverage[:total_chunks]}, character coverage #{coverage[:characters]})"
        end
        cluster[:matches].each do |match|
          lines << "  Match cosine #{match[:similarity]}"
          match[:chunks].each { |chunk| lines << "    #{chunk[:file]}#chunk=#{chunk[:chunk]}: #{chunk[:text]}" }
        end
      end
      lines << "No qualifying pairs." if report[:clusters].empty?
      lines.join("\n")
    end

    private

    def canonical(file)
      ConfigLoader.comparable_path(ConfigLoader.canonical_target(file))
    end

    def in_scope?(file)
      !@prefix || file == @prefix || file.start_with?(@prefix.end_with?("/") ? @prefix : "#{@prefix}/")
    end

    def load_path(path, store)
      diagnostic = {name: path.name, db: File.expand_path(path.db_file), table: path.db_table,
                    missing_sources: 0, newer_sources: 0, unindexed_files: 0}
      @diagnostics << diagnostic
      unless File.file?(path.db_file)
        diagnostic[:status] = "missing_database"
        @warnings << "Missing index: #{path.name}"
        return
      end
      db = SQLite3::Database.new(path.db_file, readonly: true)
      db.results_as_hash = true
      db.execute("BEGIN")
      table = path.db_table
      raise ArgumentError, "Invalid table name" unless SqliteIndex::TABLE_NAME_PATTERN.match?(table)
      tables = db.execute("SELECT name FROM sqlite_master WHERE type='table'").map { |r| r["name"] }
      unless tables.include?(table)
        diagnostic[:status] = "missing_table"
        @warnings << "Missing index table: #{path.name}"
        return
      end
      scan_table = "#{table}__scan_timestamps"
      scan = tables.include?(scan_table) && db.get_first_value("SELECT scanned_at FROM \"#{scan_table}\" WHERE scope='last_completed'")
      diagnostic[:last_scan] = scan || nil
      @warnings << "No completed scan timestamp: #{path.name}; freshness unknown" unless scan
      seen = Set.new
      canonical_paths = {}
      batch = []
      db.execute("SELECT path, chunk, hash, embedding, text FROM \"#{table}\" ORDER BY path, chunk") do |row|
        file = canonical_paths[row["path"]] ||= canonical(row["path"])
        next unless in_scope?(file)
        unless seen.include?(file)
          diagnostic[:missing_sources] += 1 unless File.file?(file)
          diagnostic[:newer_sources] += 1 if scan && File.file?(file) && File.mtime(file).to_f > scan.to_f
          seen << file
        end
        row["path"] = file
        key = [file, row["chunk"]]
        if @rows.key?(key)
          raise ArgumentError, "Conflicting overlapping indexes for #{file} chunk #{row['chunk']}" unless @rows[key][:signature] == Digest::SHA256.hexdigest(row.values_at("hash", "embedding", "text").to_json)
          next
        end
        vector = JSON.parse(row["embedding"])
        raise ArgumentError, "Invalid embedding: #{file} chunk #{row['chunk']}" unless vector.is_a?(Array) && !vector.empty? && vector.all? { |n| n.is_a?(Numeric) && n.finite? }
        @dimensions << vector.length
        raise ArgumentError, "Mixed embedding dimensions: #{@dimensions.to_a.sort.join(', ')}; select compatible indexes" if @dimensions.length > 1
        signature = Digest::SHA256.hexdigest(row.values_at("hash", "embedding", "text").to_json)
        row["embedding"] = EmbeddingMath.normalize(vector)
        raise ArgumentError, "Missing chunk text: #{file}" if row["text"].to_s.empty?
        @rows[key] = {text: row["text"], signature: signature}
        (@documents[file] ||= []) << row["chunk"]
        batch << row.merge("text" => nil)
        if batch.length >= 200
          store.transaction { store.upsert_chunks(batch) }
          batch.clear
        end
      end
      store.transaction { store.upsert_chunks(batch) } unless batch.empty?
      if path.dir && Dir.exist?(path.dir)
        # Same default file pattern as the indexer; status-filtered files may intentionally have no rows.
        pattern = File.join("**", path.nameMatch || "*.{md,markdown}")
        diagnostic[:unindexed_files] = Dir.glob(File.join(path.dir, pattern)).count { |f| File.file?(f) && in_scope?(canonical(f)) && !seen.include?(canonical(f)) }
      else
        @warnings << "Source directory unavailable: #{path.name}"
      end
      diagnostic[:status] = "read"
      @warnings << "#{path.name}: source/index gaps detected; see indexes diagnostics (unindexed files may be intentionally excluded)." if diagnostic.values_at(:missing_sources, :newer_sources, :unindexed_files).any?(&:positive?)
    ensure
      db&.close
    end

    def aggregate(members, matches)
      used = [Set.new, Set.new]
      # One-to-one greedy matching stops one shared quotation covering many chunks.
      selected = matches.sort_by { |chunks, score| [-score, chunks] }.filter_map do |chunks, score|
        next if chunks.each_with_index.any? { |chunk, side| used[side].include?(chunk) }
        chunks.each_with_index { |chunk, side| used[side] << chunk }
        [chunks, score]
      end
      coverage = members.each_with_index.to_h do |file, side|
        chunks = @documents.fetch(file)
        total_chars = chunks.sum { |chunk| @rows.fetch([file, chunk])[:text].length }
        matched_chars = used[side].sum { |chunk| @rows.fetch([file, chunk])[:text].length }
        ratio = matched_chars.fdiv(total_chars)
        fraction = used[side].length.fdiv(chunks.length)
        return nil if ratio < @coverage || fraction < @coverage
        [file, {matched_chunks: used[side].length, total_chunks: chunks.length,
                matched_characters: matched_chars, total_characters: total_chars,
                characters: ratio.round(6), chunks: fraction.round(6)}]
      end
      scores = selected.map(&:last)
      {id: Digest::SHA256.hexdigest(members.to_json)[0, 16], members: members, coverage: coverage,
       similarity: {min: scores.min.round(6), mean: (scores.sum / scores.length).round(6)},
       matched_pairs: selected.length,
       matches: selected.first(@evidence).map do |chunks, score|
         {similarity: score.round(6), chunks: members.each_with_index.map do |file, side|
           text = @rows.fetch([file, chunks[side]])[:text]
           {file: file, chunk: chunks[side], position: "zero-based indexed chunk; source line offsets unavailable",
            text: text[0, @brief_chars], truncated: text.length > @brief_chars}
         end}
       end}
    end
  end
end
