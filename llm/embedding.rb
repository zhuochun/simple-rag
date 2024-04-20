
def cosine_similarity(array1, array2)
  dot_product = 0.0
  norm_a = 0.0
  norm_b = 0.0

  array1.each_with_index do |value1, index|
    value2 = array2[index]

    dot_product += value1 * value2
    norm_a += value1 * value1
    norm_b += value2 * value2
  end

  norm_a = Math.sqrt(norm_a)
  norm_b = Math.sqrt(norm_b)

  cosine_similarity = dot_product / (norm_a * norm_b)
end