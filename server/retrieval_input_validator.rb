require_relative "../lib/query_helpers"

class RetrievalInputError < ArgumentError
end

module SimpleRag
  module RetrievalInputValidator
    module_function

    def validate!(lookup_paths, query, top_n)
      raise RetrievalInputError, "Query text is required" if query.to_s.strip.empty?
      raise RetrievalInputError, "top_n must be > 0" unless top_n.to_i > 0
      raise RetrievalInputError, "top_n must be <= #{QueryHelpers::MAX_TOP_N}" if top_n.to_i > QueryHelpers::MAX_TOP_N
      raise RetrievalInputError, "At least one lookup path is required" if Array(lookup_paths).empty?
    end
  end
end
