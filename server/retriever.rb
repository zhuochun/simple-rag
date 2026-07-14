require_relative "../llm/embedding"
require_relative "index_catalog"
require_relative "retrieval_pipeline"

module SimpleRag
  class SimilarityRetriever
    VECTOR_SEARCH_K = 512
    VECTOR_SEARCH_K_MIN = 64
    VECTOR_SEARCH_K_MULTIPLIER = 12

    def initialize(embedding_fn:, catalog:)
      @embedding_fn = embedding_fn
      @catalog = catalog
    end

    def retrieve(paths, query, top_n:)
      validate_inputs!(paths, query, top_n)
      embedding = EmbeddingMath.normalize(@embedding_fn.call(query))
      raise RuntimeError, "Embedding is empty" if embedding.empty?

      @catalog.vector_search(paths, embedding, k: search_depth(top_n))
              .sort_by { |row| [-row["score"].to_f, row["lookup"].to_s, row["path"].to_s, row["chunk"].to_i] }
              .first(top_n.to_i)
    end

    private

    def validate_inputs!(paths, query, top_n)
      raise RetrievalInputError, "Query text is required" if query.to_s.strip.empty?
      raise RetrievalInputError, "top_n must be > 0" unless top_n.to_i > 0
      raise RetrievalInputError, "top_n must be <= #{QueryHelpers::MAX_TOP_N}" if top_n.to_i > QueryHelpers::MAX_TOP_N
      raise RetrievalInputError, "At least one lookup path is required" if Array(paths).empty?
    end

    def search_depth(top_n)
      count = top_n.to_i
      return VECTOR_SEARCH_K unless count.positive?

      [[count * VECTOR_SEARCH_K_MULTIPLIER, VECTOR_SEARCH_K_MIN].max, VECTOR_SEARCH_K].min
    end
  end

  module RetrieverFactory
    module_function

    def build(chat_fn:, embedding_fn:, locator: DocumentLocator.new, store_factory: nil)
      Retriever.new(
        planner: QueryPlanner.new(chat_fn: chat_fn),
        executor: RetrievalExecutor.new(
          embedding_fn: embedding_fn,
          id_fn: locator.method(:id),
          url_fn: locator.method(:url),
          store_factory: store_factory
        )
      )
    end
  end
end
