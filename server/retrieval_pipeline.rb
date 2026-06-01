require "thread"

require_relative "../storage/sqlite_index"

QueryPlan = Struct.new(
  :original_query,
  :semantic_rewrite,
  :keyword_variants,
  :lists,
  keyword_init: true
)

class RetrievalInputError < ArgumentError
end

class QueryPlanner
  ORIGINAL_QUERY_PHRASE_MAX_TOKENS = 5

  LIST_WEIGHTS = {
    "vec:original" => 1.2,
    "bm25:original" => 1.1,
    "bm25:phrase" => 1.2,
    "vec:expanded" => 0.7,
    "bm25:variants" => 0.6,
  }.freeze

  REWRITE_PROMPT = <<~PROMPT
    Rewrite the user query into one concise semantic search query.

    Rules:
    - Preserve the exact intent.
    - Do not broaden the scope.
    - Do not add assumptions.
    - Prefer terms likely to appear in notes.
    - Output one query only.
  PROMPT

  VARIANT_PROMPT = <<~PROMPT
    Generate 6 short keyword variants for exact keyword matching in markdown.

    Rules:
    - Keep the same intent as the user input.
    - Output exactly 6 terms:
      - 3 Chinese terms, each 1 to 6 characters.
      - 3 English terms, each 1 to 3 words.
    - Prefer concrete nouns, names, acronyms, and likely terms from docs.
    - Terms must be distinct and useful for search.
    - Output one CSV line only in this order:
      zh_term1, zh_term2, zh_term3, en_term1, en_term2, en_term3
    - No numbering, no bullets, no quotes, no extra text.
  PROMPT

  class ExpansionError < StandardError
    attr_reader :semantic_rewrite, :keyword_variants

    def initialize(message, semantic_rewrite: nil, keyword_variants: [])
      super(message)
      @semantic_rewrite = semantic_rewrite
      @keyword_variants = keyword_variants
    end
  end

  def initialize(chat_fn:)
    @chat_fn = chat_fn
  end

  def build_q_plan(query)
    original = normalize_query(query)
    QueryPlan.new(
      original_query: original,
      semantic_rewrite: nil,
      keyword_variants: [],
      lists: original_lists(original)
    )
  end

  def build_q_plus_plan(query)
    original = normalize_query(query)
    rewrite = nil
    variants = []

    begin
      rewrite = semantic_rewrite(original)
      variants = keyword_variants(original)
    rescue => e
      raise ExpansionError.new(
        "Query expansion failed: #{e.class}: #{e.message}",
        semantic_rewrite: rewrite,
        keyword_variants: variants
      )
    end

    normalized_original = normalized_comparison(original)
    normalized_rewrite = normalized_comparison(rewrite)
    retained_variants = variants.reject do |variant|
      normalized = normalized_comparison(variant)
      normalized.empty? || normalized == normalized_original || normalized == normalized_rewrite
    end
    retained_variants = deduplicate_queries(retained_variants)

    lists = original_lists(original)
    if !normalized_rewrite.empty? && normalized_rewrite != normalized_original
      lists << list("vec:expanded", "vector", "expanded", rewrite)
    end
    unless retained_variants.empty?
      lists << list("bm25:variants", "bm25", "expanded", retained_variants, phrase: true)
    end

    expanded_lists = lists.select { |item| item[:query_type] == "expanded" }
    if normalized_rewrite.empty? || retained_variants.empty? || expanded_lists.empty?
      raise ExpansionError.new(
        "Query expansion produced no usable expanded plan",
        semantic_rewrite: rewrite,
        keyword_variants: retained_variants
      )
    end

    QueryPlan.new(
      original_query: original,
      semantic_rewrite: rewrite,
      keyword_variants: retained_variants,
      lists: lists
    )
  end

  def semantic_rewrite(query)
    response = @chat_fn.call([
      { role: "system", content: REWRITE_PROMPT },
      { role: "user", content: query },
    ])
    normalize_query(response)
  end

  def keyword_variants(query)
    response = @chat_fn.call([
      { role: "system", content: VARIANT_PROMPT },
      { role: "user", content: query },
    ])
    deduplicate_queries(response.to_s.split(",")).first(6)
  end

  def token_count(query)
    query.to_s.scan(/[\p{L}\p{N}_]+/u).length
  end

  def normalize_query(query)
    query.to_s.gsub(/\s+/, " ").strip
  end

  private

  def original_lists(query)
    lists = [list("vec:original", "vector", "original", query)]
    if token_count(query) > ORIGINAL_QUERY_PHRASE_MAX_TOKENS
      lists << list("bm25:original", "bm25", "original", query)
    end
    lists << list("bm25:phrase", "bm25", "original", query, phrase: true)
    lists
  end

  def list(name, backend, query_type, query, phrase: false)
    {
      name: name,
      backend: backend,
      query_type: query_type,
      query: query,
      phrase: phrase,
      weight: LIST_WEIGHTS.fetch(name),
    }
  end

  def deduplicate_queries(queries)
    seen = {}
    Array(queries).filter_map do |query|
      value = normalize_query(query)
      normalized = normalized_comparison(value)
      next if normalized.empty? || seen[normalized]

      seen[normalized] = true
      value
    end
  end

  def normalized_comparison(query)
    normalize_query(query).downcase
  end
end

class RetrievalExecutor
  RETRIEVAL_THREADS_MAX = 8
  VECTOR_CANDIDATE_DEPTH = { multiplier: 12, min: 64, max: 512 }.freeze
  BM25_CANDIDATE_DEPTH = { multiplier: 20, min: 100, max: 800 }.freeze

  def initialize(embedding_fn:, id_fn:, url_fn:, store_factory: nil, threads_max: RETRIEVAL_THREADS_MAX)
    @embedding_fn = embedding_fn
    @id_fn = id_fn
    @url_fn = url_fn
    @store_factory = store_factory || ->(path) { SqliteIndex.new(path.db_file, path.db_table) }
    @threads_max = [[threads_max.to_i, 1].max, RETRIEVAL_THREADS_MAX].min
  end

  def execute_plan(plan, lookup_paths, top_n:)
    jobs = []
    plan.lists.each do |source|
      query_embedding = source[:backend] == "vector" ? normalized_embedding(@embedding_fn.call(source[:query])) : nil
      lookup_paths.each do |path|
        jobs << { source: source, path: path, query_embedding: query_embedding }
      end
    end

    job_results = run_jobs(jobs, top_n)
    source_lists = []
    plan.lists.each do |source|
      results = job_results.select { |result| result[:source].equal?(source) }
      if source[:backend] == "vector"
        entries = results.flat_map { |result| result[:entries] }
        entries = stable_sort(entries).first(vector_candidate_depth(top_n))
        entries.each_with_index { |entry, idx| annotate_rank!(entry, source[:name], idx + 1) }
        source_lists << source_list(source, source[:name], entries)
      else
        results.sort_by { |result| result[:path].name.to_s }.each do |result|
          entries = stable_sort(result[:entries])
          name = "#{source[:name]}:#{result[:path].name}"
          entries.each_with_index { |entry, idx| annotate_rank!(entry, name, idx + 1) }
          source_lists << source_list(source, name, entries)
        end
      end
    end
    source_lists
  end

  private

  def run_jobs(jobs, top_n)
    queue = Queue.new
    jobs.each { |job| queue << job }
    results = []
    results_mutex = Mutex.new
    errors = Queue.new
    worker_count = [jobs.length, @threads_max].min

    workers = worker_count.times.map do
      Thread.new do
        loop do
          job = queue.pop(true)
          result = execute_job(job, top_n)
          results_mutex.synchronize { results << result }
        rescue ThreadError
          break
        rescue => e
          errors << e
          break
        end
      end
    end
    workers.each(&:join)
    raise errors.pop unless errors.empty?

    results
  end

  def execute_job(job, top_n)
    source = job[:source]
    path = job[:path]
    store = @store_factory.call(path)
    entries = if source[:backend] == "vector"
      store.vector_search(job[:query_embedding], vector_candidate_depth(top_n)).filter_map do |item|
        score = item["score"].to_f
        next if score < path.threshold.to_f

        candidate(item, path, score, source)
      end
    else
      store.text_search_any(
        source[:query],
        limit: bm25_candidate_depth(top_n),
        phrase: source[:phrase]
      ).map { |item| candidate(item, path, item["score"].to_f, source) }
    end
    { source: source, path: path, entries: entries }
  ensure
    store.close if store && store.respond_to?(:close)
  end

  def candidate(item, path, score, source)
    {
      "path" => item["path"],
      "chunk" => item["chunk"].to_i,
      "text" => item["text"],
      "lookup" => path.name,
      "id" => @id_fn.call(item["path"]),
      "url" => @url_fn.call(item["path"], path.url),
      "score" => score,
      "_backend" => source[:backend],
      "_query_type" => source[:query_type],
      "_weight" => source[:weight].to_f,
    }
  end

  def stable_sort(entries)
    entries.sort_by do |item|
      [-item["score"].to_f, item["lookup"].to_s, item["path"].to_s, item["chunk"].to_i]
    end
  end

  def annotate_rank!(entry, source_name, rank)
    entry["_source_list"] = source_name
    entry["_rank"] = rank
  end

  def source_list(source, name, entries)
    {
      name: name,
      backend: source[:backend],
      query_type: source[:query_type],
      weight: source[:weight].to_f,
      entries: entries,
    }
  end

  def normalized_embedding(raw)
    values = Array(raw)
    raise RuntimeError, "Embedding is empty" if values.empty?

    values = values.map do |value|
      Float(value)
    rescue ArgumentError, TypeError
      raise RuntimeError, "Embedding contains non-numeric values"
    end
    norm = Math.sqrt(values.sum { |value| value * value })
    raise RuntimeError, "Embedding norm is zero" if norm <= 0.0

    values.map { |value| value / norm }
  end

  def vector_candidate_depth(top_n)
    clamp(top_n.to_i * VECTOR_CANDIDATE_DEPTH[:multiplier], VECTOR_CANDIDATE_DEPTH)
  end

  def bm25_candidate_depth(top_n)
    clamp(top_n.to_i * BM25_CANDIDATE_DEPTH[:multiplier], BM25_CANDIDATE_DEPTH)
  end

  def clamp(value, config)
    [[value, config[:min]].max, config[:max]].min
  end
end

class FusionEngine
  RRF_K = 60
  FINAL_SCORE_WEIGHTS = { rrf: 0.75, score_signal: 0.15 }.freeze
  BOOSTS = {
    original_rank_1: 0.05,
    original_rank_2_or_3: 0.02,
    expanded_only_penalty: -0.05,
  }.freeze

  def fuse_chunk_candidates(source_lists, rrf_k: RRF_K)
    merged = {}
    source_lists.each do |source|
      entries = Array(source[:entries])
      next if entries.empty?

      scores = entries.map { |entry| entry["score"].to_f }
      min_score = scores.min || 0.0
      max_score = scores.max || 0.0
      entries.each do |entry|
        normalized_score = min_max_normalize(entry["score"], min_score, max_score)
        contribution = source[:weight].to_f * (1.0 / (rrf_k + entry["_rank"].to_i))
        row = (merged[chunk_key(entry)] ||= fused_row(entry))
        row["_rrf_score"] += contribution
        row["_score_signal"] += source[:weight].to_f * normalized_score
        row["evidence"] << {
          "source_list" => source[:name],
          "backend" => source[:backend],
          "query_type" => source[:query_type],
          "rank" => entry["_rank"].to_i,
          "raw_score" => entry["score"].to_f,
          "normalized_score" => normalized_score,
          "rrf_contribution" => contribution,
        }
      end
    end

    rows = merged.values
    max_rrf = rows.map { |row| row["_rrf_score"] }.max.to_f
    max_signal = rows.map { |row| row["_score_signal"] }.max.to_f
    rows.each do |row|
      row["evidence"].sort_by! { |item| [item["source_list"], item["rank"]] }
      row["sources"] = row["evidence"].map { |item| item["source_list"] }.uniq
      row["normalized_rrf"] = max_rrf > 0 ? row["_rrf_score"] / max_rrf : 0.0
      row["normalized_score_signal"] = max_signal > 0 ? row["_score_signal"] / max_signal : 0.0
      apply_chunk_boosts(row)
      row.delete("_rrf_score")
      row.delete("_score_signal")
    end
    stable_sort(rows)
  end

  private

  def fused_row(entry)
    {
      "path" => entry["path"],
      "chunk" => entry["chunk"],
      "text" => entry["text"],
      "lookup" => entry["lookup"],
      "id" => entry["id"],
      "url" => entry["url"],
      "_rrf_score" => 0.0,
      "_score_signal" => 0.0,
      "evidence" => [],
    }
  end

  def apply_chunk_boosts(row)
    original_ranks = row["evidence"].filter_map do |item|
      item["rank"] if item["query_type"] == "original"
    end
    top_rank_boost = if original_ranks.include?(1)
      BOOSTS[:original_rank_1]
    elsif original_ranks.any? { |rank| rank == 2 || rank == 3 }
      BOOSTS[:original_rank_2_or_3]
    else
      0.0
    end
    expanded_only_penalty = original_ranks.empty? ? BOOSTS[:expanded_only_penalty] : 0.0
    row["boosts"] = {
      "top_rank_original" => top_rank_boost,
      "expanded_only_penalty" => expanded_only_penalty,
    }
    raw_score = (
      FINAL_SCORE_WEIGHTS[:rrf] * row["normalized_rrf"] +
      FINAL_SCORE_WEIGHTS[:score_signal] * row["normalized_score_signal"] +
      top_rank_boost +
      expanded_only_penalty
    )
    row["final_score"] = clamp_score(raw_score)
  end

  def min_max_normalize(score, min_score, max_score)
    value = score.to_f
    return (value - min_score) / (max_score - min_score) if max_score > min_score
    return 1.0 if value > 0

    0.0
  end

  def chunk_key(item)
    [item["lookup"], item["path"], item["chunk"]]
  end

  def stable_sort(rows)
    rows.sort_by do |row|
      [-row["final_score"], row["lookup"].to_s, row["path"].to_s, row["chunk"].to_i]
    end
  end

  def clamp_score(score)
    [[score, 0.0].max, 1.0].min
  end
end

class FileAggregator
  STRONG_CHUNK_THRESHOLD = 0.35
  MAX_CHUNKS_PER_FILE = 3
  TOP_GLOBAL_STRONG_CHUNKS = { multiplier: 3, min: 30, max: 100 }.freeze
  BOOSTS = {
    multi_chunk_evidence: 0.02,
    source_list_diversity_per_extra_list: 0.01,
    source_list_diversity_cap: 0.02,
  }.freeze

  def aggregate_files(fused_chunks, top_n:)
    top_global = fused_chunks.first(top_global_depth(top_n)).each_with_object({}) do |chunk, out|
      out[chunk_key(chunk)] = true
    end
    files = fused_chunks.group_by { |chunk| [chunk["lookup"], chunk["path"]] }.map do |_key, chunks|
      build_file(chunks, top_global)
    end
    files.sort_by do |file|
      [
        -file[:score],
        -file[:anchor_chunk][:score],
        -file[:source_summary][:original_match_count],
        file[:lookup].to_s,
        file[:path].to_s,
      ]
    end.first(top_n.to_i)
  end

  private

  def build_file(chunks, top_global)
    ordered = chunks.sort_by { |chunk| [-chunk["final_score"], chunk["chunk"].to_i] }
    anchor = ordered.first
    retained = ordered.select do |chunk|
      chunk["final_score"] >= STRONG_CHUNK_THRESHOLD || top_global[chunk_key(chunk)]
    end
    retained.unshift(anchor) unless retained.include?(anchor)
    retained = retained.uniq.first(MAX_CHUNKS_PER_FILE)
    matched_chunks = retained.map { |chunk| chunk_output(chunk) }
    strong_chunks = matched_chunks.select { |chunk| chunk[:score] >= STRONG_CHUNK_THRESHOLD }
    source_summary = source_summary(matched_chunks)
    evidence_boost = multi_chunk_evidence_boost(strong_chunks)
    diversity_boost = source_list_diversity_boost(strong_chunks)
    file_score = clamp_score(anchor["final_score"] + evidence_boost + diversity_boost)

    {
      path: anchor["path"],
      id: anchor["id"],
      lookup: anchor["lookup"],
      url: anchor["url"],
      score: file_score,
      anchor_chunk: chunk_output(anchor),
      matched_chunks: matched_chunks,
      source_summary: source_summary,
      debug: {
        anchor_rrf: anchor["normalized_rrf"],
        anchor_score_signal: anchor["normalized_score_signal"],
        anchor_boosts: symbolize_hash(anchor["boosts"]),
        file_boosts: {
          multi_chunk_evidence: evidence_boost,
          source_list_diversity: diversity_boost,
        },
      },
    }
  end

  def chunk_output(chunk)
    {
      chunk: chunk["chunk"],
      score: chunk["final_score"],
      text: chunk["text"],
      sources: chunk["sources"],
      evidence: chunk["evidence"].map { |item| symbolize_hash(item) },
    }
  end

  def source_summary(chunks)
    evidence = chunks.flat_map { |chunk| chunk[:evidence] }
    original_count = chunks.count do |chunk|
      chunk[:evidence].any? { |item| item[:query_type] == "original" }
    end
    expanded_count = chunks.count do |chunk|
      chunk[:evidence].any? { |item| item[:query_type] == "expanded" }
    end
    {
      source_lists: evidence.map { |item| item[:source_list] }.uniq.sort,
      has_original_match: original_count > 0,
      has_expanded_match: expanded_count > 0,
      original_match_count: original_count,
      expanded_match_count: expanded_count,
    }
  end

  def multi_chunk_evidence_boost(chunks)
    return 0.0 if chunks.length < 2
    return 0.0 unless chunks.any? { |chunk| chunk[:evidence].any? { |item| item[:query_type] == "original" } }

    BOOSTS[:multi_chunk_evidence]
  end

  def source_list_diversity_boost(chunks)
    source_count = chunks.flat_map { |chunk| chunk[:sources] }.uniq.length
    extra_lists = [source_count - 1, 0].max
    [
      extra_lists * BOOSTS[:source_list_diversity_per_extra_list],
      BOOSTS[:source_list_diversity_cap],
    ].min
  end

  def top_global_depth(top_n)
    value = top_n.to_i * TOP_GLOBAL_STRONG_CHUNKS[:multiplier]
    [[value, TOP_GLOBAL_STRONG_CHUNKS[:min]].max, TOP_GLOBAL_STRONG_CHUNKS[:max]].min
  end

  def chunk_key(chunk)
    [chunk["lookup"], chunk["path"], chunk["chunk"]]
  end

  def symbolize_hash(hash)
    hash.each_with_object({}) { |(key, value), out| out[key.to_sym] = value }
  end

  def clamp_score(score)
    [[score, 0.0].max, 1.0].min
  end
end

class Retriever
  MAX_TOP_N = 100

  def initialize(planner:, executor:, fusion_engine: FusionEngine.new, file_aggregator: FileAggregator.new)
    @planner = planner
    @executor = executor
    @fusion_engine = fusion_engine
    @file_aggregator = file_aggregator
  end

  def retrieve_q(lookup_paths, query, top_n:)
    validate_inputs!(lookup_paths, query, top_n)
    execute(@planner.build_q_plan(query), lookup_paths, top_n, requested_mode: "q")
  end

  def retrieve_q_plus(lookup_paths, query, top_n:)
    validate_inputs!(lookup_paths, query, top_n)
    begin
      plan = @planner.build_q_plus_plan(query)
      execute(plan, lookup_paths, top_n, requested_mode: "q_plus")
    rescue QueryPlanner::ExpansionError => e
      fallback_plan = @planner.build_q_plan(query)
      execute(
        fallback_plan,
        lookup_paths,
        top_n,
        requested_mode: "q_plus",
        fallback: { reason: "expansion_failed", message: e.message },
        semantic_rewrite: e.semantic_rewrite,
        keyword_variants: e.keyword_variants
      )
    end
  end

  def validate_inputs!(lookup_paths, query, top_n)
    raise RetrievalInputError, "Query text is required" if query.to_s.strip.empty?
    raise RetrievalInputError, "top_n must be > 0" unless top_n.to_i > 0
    raise RetrievalInputError, "top_n must be <= #{MAX_TOP_N}" if top_n.to_i > MAX_TOP_N
    raise RetrievalInputError, "At least one lookup path is required" if Array(lookup_paths).empty?
  end

  private

  def execute(plan, lookup_paths, top_n, requested_mode:, fallback: nil, semantic_rewrite: plan.semantic_rewrite, keyword_variants: plan.keyword_variants)
    source_lists = @executor.execute_plan(plan, lookup_paths, top_n: top_n)
    fused_chunks = @fusion_engine.fuse_chunk_candidates(source_lists)
    files = @file_aggregator.aggregate_files(fused_chunks, top_n: top_n)
    {
      query: plan.original_query,
      requested_mode: requested_mode,
      mode: fallback ? "q" : requested_mode,
      fallback: fallback,
      semantic_rewrite: semantic_rewrite,
      keyword_variants: keyword_variants,
      count: files.length,
      data: files,
    }
  end
end
