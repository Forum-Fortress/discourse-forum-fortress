# frozen_string_literal: true

ForumFortress::Engine.routes.draw do
  get "/status" => "admin#status"
  get "/portal" => "admin#portal"
  post "/test" => "admin#test"
end

Discourse::Application.routes.draw { mount ::ForumFortress::Engine, at: "forum-fortress" }
