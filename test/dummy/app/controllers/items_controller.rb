class ItemsController < ApplicationController
  def index
    render json: { tags: params[:tags] }
  end

  def create
    render json: { title: params[:title] }, status: :created
  end

  def redirect_read
    redirect_to "/api/items", status: :found
  end

  def redirect_write
    redirect_to "/api/items", status: :found
  end

  def boom
    render json: { error: "intentional failure" }, status: :internal_server_error
  end

  def string_value
    render body: JSON.generate("hello"), content_type: "application/json"
  end
end
