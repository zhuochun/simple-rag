require_relative "reader"

# check-reader reader filepath

reader_name = ARGV[0]
file_path = ARGV[1..]&.join(" ")

if reader_name.nil? || reader_name.empty? || file_path.nil? || file_path.empty?
    STDOUT << "Usage: ruby readers\\check-reader.rb <reader> <filepath>\n"
    exit 1
end

reader = get_reader(reader_name)
if reader.nil?
    STDOUT << "Reader #{reader_name} not found\n"
    exit 1
end

file = reader.new(file_path)
file.load

STDOUT << "Print chunks #{file_path} [#{file.chunks.length}]:\n"

file.chunks.each_with_index do |chunk, idx|
    STDOUT << "\n========== Chunk #{idx} ==========\n"
    STDOUT << chunk << "\n"
    STDOUT << "========== END #{idx} ==========\n"
end
