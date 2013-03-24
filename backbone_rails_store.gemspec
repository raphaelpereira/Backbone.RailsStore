$:.push File.expand_path("../lib", __FILE__)

# Maintain your gem's version:
require "backbone_rails_store/version"

# Describe your gem and declare its dependencies:
Gem::Specification.new do |s|
  s.name        = "backbone_rails_store"
  s.version     = BackboneRailsStore::VERSION
  s.authors     = ["Raphael Derosso Pereira"]
  s.email       = ["raphael@rmi.inf.br"]
  s.homepage    = "http://github.com/raphaelpereira/Backbone.RailsStore"
  s.summary     = "Rails models to Backbone.js"
  s.description = "Easy Rails model operations in javascript, persistence layer, rails model relationships to Backbone.js models."

  s.files = Dir["app/**/*"] + Dir["vendor/**/*"] + Dir["lib/**/*"] + ["MIT-LICENSE", "Rakefile", "README.rdoc"]
  s.test_files = Dir["test/**/*"]

  s.add_dependency "rails", ">= 3.1.0"
  s.add_dependency('railties', '>= 3.1.0')
  s.add_dependency('coffee-script', '~> 2.2.0')
  s.add_dependency('jquery-rails', '~> 2.2')
  s.add_dependency('ejs', '~> 1.1.1')
end
