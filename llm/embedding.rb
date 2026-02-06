# Calculate dot product on two equal length arrays
def dot_product(a1, a2)
  sum = 0.0
  a1.each_with_index { |v, i| sum += v * a2[i] }
  sum
end

# Normalize an embedding to unit length
def normalize_embedding(embedding)
  norm = Math.sqrt(embedding.inject(0.0) { |s, v| s + v * v })
  embedding.map { |v| v / norm }
end

# Generate an integer hash based on embedding sign buckets
def bucket_key(embedding, dims = 10)
  step = embedding.length / dims
  key = 0
  dims.times do |i|
    key <<= 1
    key |= 1 if embedding[i * step] >= 0
  end
  key
end

# Return neighboring bucket keys with Hamming distance 1
def neighbor_keys(key, dims = 10)
  keys = [key]
  dims.times { |i| keys << (key ^ (1 << i)) }
  keys
end
