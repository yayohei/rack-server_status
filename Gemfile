source 'https://rubygems.org'

# Specify your gem's dependencies in rack-server_status.gemspec
gemspec

group :development, :test do
  gem 'pry'
end
group :test do
  gem 'rack', "< 3" # https://github.com/rack/rack/issues/1592
  gem 'timecop'
end
