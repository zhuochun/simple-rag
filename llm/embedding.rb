module EmbeddingMath
  module_function

  def dot_product(left, right)
    raise ArgumentError, "Embedding dimension mismatch: left=#{left.length}, right=#{right.length}" unless left.length == right.length

    left.each_index.sum { |index| left[index].to_f * right[index].to_f }
  end

  def normalize(embedding)
    values = Array(embedding).map do |value|
      Float(value)
    rescue ArgumentError, TypeError
      raise ArgumentError, "Embedding contains non-numeric values"
    end
    return [] if values.empty?

    norm = Math.sqrt(values.sum { |value| value * value })
    raise ArgumentError, "Embedding norm is zero" unless norm.positive?

    values.map { |value| value / norm }
  end

  def bucket_key(embedding, dimensions = 10)
    return 0 if dimensions.to_i <= 0 || embedding.empty?

    dimensions = [dimensions.to_i, embedding.length].min
    step = embedding.length / dimensions
    dimensions.times.reduce(0) do |key, index|
      (key << 1) | (embedding[index * step].to_f >= 0 ? 1 : 0)
    end
  end

  def neighbor_keys(key, dimensions = 10)
    [key, *dimensions.times.map { |index| key ^ (1 << index) }]
  end
end
