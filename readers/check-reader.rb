require_relative "reader"

# check-reader reader filepath

reader = get_reader(ARGV[0])
if reader.nil?
    STDOUT << "Reader #{ARGV[0]} not found\n"
    exit 1
end

file = reader.new(ARGV[1])
file.load

STDOUT << "Print chunks #{ARGV[1]} [#{file.chunks.length}]:\n"

file.chunks.each do |chunk|
    STDOUT << chunk << "\n---\n"
end