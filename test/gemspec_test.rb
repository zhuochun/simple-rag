spec = Gem::Specification.load(File.expand_path("../simple-rag.gemspec", __dir__))
raise "Unable to load gemspec" if spec.nil?

dll = "vendor/sqlite-vec/vec0.dll"
raise "Missing packaged #{dll}" unless spec.files.include?(dll)
raise "Python bytecode must not be packaged" if spec.files.any? { |file| file.include?("/__pycache__/") || file.end_with?(".pyc") }

puts "gemspec_test: passed"
