Rails.application.routes.draw do
  get "/page_a", to: "pages#a"
  get "/page_b", to: "pages#b"
  get "/page_empty", to: "pages#empty"
  get "/api/items", to: "items#index"
  post "/api/items", to: "items#create"
  get "/api/redirect", to: "items#redirect_read"
  post "/api/redirect_write", to: "items#redirect_write"
  get "/api/boom", to: "items#boom"
  get "/api/string", to: "items#string_value"
  get "/favicon.ico", to: proc { [204, {}, []] }
end
