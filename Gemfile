source 'https://rubygems.org'

gem 'rack'
gem 'sinatra'
gem "rackup"
gem "fiddle"
gem "ostruct"
gem "sqlite3", ">= 2.9.5"
if Gem::Platform.local.to_s.include?("mingw-ucrt")
  gem "webrick"
else
  gem "puma"
  gem "sqlite-vec"
end
