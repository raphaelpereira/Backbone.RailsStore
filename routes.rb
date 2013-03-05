##
# Backbone.RailsStore Routes Example file
#
# These are the minimum routes that must be setup to complete Backbone.RailsStore functionality
#
YourApp::Application.routes.draw do
  match '/backbone_rails_store/refresh' => 'backbone_rails_store#refresh'
  match '/backbone_rails_store/commit' => 'backbone_rails_store#commit'
  match '/backbone_rails_store/find' => 'backbone_rails_store#find'
  match '/backbone_rails_store/auth' => 'backbone_rails_store#authenticate'
  match '/backbone_rails_store/logout' => 'backbone_rails_store#logout'
  match '/backbone_rails_store/upload' => 'backbone_rails_store#upload'
end
