require "json"
require "sinatra/base"

require_relative "runtime"
require_relative "retrieval_pipeline"

module SimpleRag
  class ServerApp < Sinatra::Base
    set :public_folder, File.expand_path("../exe/public", __dir__)
    set :static, true
    set :show_exceptions, false
    set :raise_errors, false
    set :runtime, nil

    def self.for_runtime(runtime:)
      Class.new(self).tap { |app| app.set :runtime, runtime }
    end

    helpers do
      def runtime
        settings.runtime || raise("Server runtime is not configured")
      end

      def json_body
        data = JSON.parse(request.body.read)
        raise ServerRuntime::BadRequest, "JSON body must be an object" unless data.is_a?(Hash)

        data
      rescue JSON::ParserError => error
        raise ServerRuntime::BadRequest, "Invalid JSON: #{error.message}"
      end

      def json_response(payload, status_code: nil)
        status status_code if status_code
        content_type :json
        JSON.generate(payload)
      end

      def error_response(error, status_code)
        json_response({ error: error.message }, status_code: status_code)
      end
    end

    error ServerRuntime::BadRequest, RetrievalInputError do
      error_response(env.fetch("sinatra.error"), 400)
    end

    error ServerRuntime::NotFound do
      error_response(env.fetch("sinatra.error"), 404)
    end

    error ServerRuntime::UpstreamError do
      error_response(env.fetch("sinatra.error"), 502)
    end

    error StandardError do
      error = env.fetch("sinatra.error")
      error_response(RuntimeError.new("#{error.class}: #{error.message}"), 500)
    end

    get "/health" do
      json_response(runtime.health)
    end

    get "/paths" do
      json_response(runtime.paths)
    end

    get "/map_data" do
      content_type :json
      runtime.map_data
    end

    post "/map_note" do
      json_response(runtime.map_note(json_body))
    end

    post "/q" do
      json_response(runtime.query(json_body))
    end

    post "/q_plus" do
      json_response(runtime.query(json_body, expanded: true))
    end

    post "/discuss" do
      json_response(runtime.discuss(json_body))
    end

    post "/duplicates" do
      json_response(runtime.duplicates(json_body))
    end

    post "/dismiss" do
      json_response(runtime.dismiss(json_body))
    end

    post "/random" do
      json_response(runtime.random(json_body))
    end

    post "/similar" do
      json_response(runtime.similar(json_body))
    end

    get "/reader/cache_articles" do
      json_response(runtime.cached_articles)
    end

    post "/reader/load_cache_article" do
      json_response(runtime.cached_article(json_body))
    end

    post "/reader/fetch_url" do
      json_response(runtime.fetch_article(json_body))
    end

    post "/reader/extract_notes" do
      json_response(runtime.extract_notes(json_body))
    end
  end
end
