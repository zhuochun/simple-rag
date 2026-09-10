spec = Gem::Specification.load(File.expand_path("../simple-rag.gemspec", __dir__))
raise "Unable to load gemspec" if spec.nil?
raise "Duplicate audit CLI must be packaged" unless spec.executables.include?("run-duplicates") && spec.files.include?("lib/duplicate_audit.rb")

dll = "vendor/sqlite-vec/vec0.dll"
raise "Missing packaged #{dll}" unless spec.files.include?(dll)
raise "Python bytecode must not be packaged" if spec.files.any? { |file| file.include?("/__pycache__/") || file.end_with?(".pyc") }

sqlite3_requirement = spec.runtime_dependencies.find { |dependency| dependency.name == "sqlite3" }&.requirement
raise "sqlite3 >= 2.9.5 must be required" unless sqlite3_requirement&.satisfied_by?(Gem::Version.new("2.9.5"))
raise "sqlite3 versions below 2.9.5 must be rejected" if sqlite3_requirement&.satisfied_by?(Gem::Version.new("2.9.4"))
raise "Ruby 3.2 must be supported" unless spec.required_ruby_version.satisfied_by?(Gem::Version.new("3.2"))
raise "Ruby versions below 3.2 must be rejected" if spec.required_ruby_version.satisfied_by?(Gem::Version.new("3.1.9"))

puts "gemspec_test: passed"
