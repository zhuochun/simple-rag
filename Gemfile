source 'https://rubygems.org'

gem 'rack'
gem 'sinatra'
gem "rackup"
if Gem::Platform.local.to_s.include?("mingw-ucrt")
  gem "sqlite3"
  gem "webrick"
else
  gem "puma"
  gem "sqlite3"
  gem "sqlite-vec"
end
