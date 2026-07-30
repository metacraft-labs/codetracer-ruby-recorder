# frozen_string_literal: true

# RS-M6 demo app — Rails.
#
# The same API as the Sinatra demo, expressed as a single-file Rails
# application, so `http.route` can be shown to come from the RAILS ROUTER:
# `ActionDispatch::Journey::Router` publishes the matched pattern as
# `env['action_dispatch.route_uri_pattern']`, and
# `CodeTracer::Rack::Middleware` records that rather than the concrete path.
# `/api/users/2` and `/api/users/999` therefore both report the route
# `/api/users/:user_id`, which is the assertion
# `rails_requests_land_in_span_stream` exists to make.
#
# ## Where the middleware sits, and why
#
# It is inserted ABOVE `ActionDispatch::ShowExceptions`.  That is the position
# a real deployment uses — you want to observe the status the client actually
# received — and it means a raising action is turned into a 500 *below* the
# middleware, exactly as in production.  The span then takes its status from
# the response and its `error.message` from the exception Rails leaves in
# `env['action_dispatch.exception']`, which is the branch this demo covers.
# (The Sinatra demo covers the other branch, where the exception escapes the
# app and the middleware's own `rescue` records it.)
#
# `Rails.application` is still the whole middleware stack, so the recorded step
# range of a request covers dispatch as well as the action.  Rails' own code
# lives under `gems/` and is filtered out of the recording by the recorder's
# `should_ignore_path`, so in practice only THIS file's steps land in the
# range.
#
# Everything is configured for a non-interactive, disk-free run: no eager
# loading, no logging, no host authorization, an in-memory session store.

require 'logger'
require 'json'
require 'action_controller/railtie'

module CodeTracerDemo
  USERS = {
    1 => { 'id' => 1, 'name' => 'Alice' },
    2 => { 'id' => 2, 'name' => 'Bob' }
  }.freeze

  # `ActionController::API` rather than `Base`: no view layer, no asset
  # pipeline, nothing this demo would have to stub out.
  class DemoController < ActionController::API
    def index
      users = CodeTracerDemo::USERS.values
      payload = { 'users' => users, 'count' => users.length }
      render json: payload
    end

    def create
      submitted = params.permit(:name).to_h
      created = { 'id' => CodeTracerDemo::USERS.keys.max + 1,
                  'name' => submitted['name'] || 'anonymous' }
      render json: created, status: :created
    end

    def show
      user_id = params[:user_id].to_i
      user = CodeTracerDemo::USERS[user_id]
      if user.nil?
        render json: { 'error' => "no user #{user_id}" }, status: :not_found
      else
        render json: user
      end
    end

    # A conditional-GET style response, so the panel's "redirect" colour bucket
    # is represented in the recording.
    def stylesheet
      head :not_modified
    end

    # Slow enough that `http.duration_ms` is unambiguously non-trivial.
    def slow_report
      sleep 0.05
      render json: { 'report' => 'slow', 'rows' => 3 }
    end

    def boom
      raise ArgumentError, 'demo failure in /api/boom'
    end

    def health
      render plain: 'ok'
    end
  end

  # A whole Rails application in one class.  `Rails::Application` subclasses
  # are singletons, so this file must be loaded exactly once per process.
  class RailsApp < Rails::Application
    config.load_defaults 7.2
    config.eager_load = false
    config.logger = Logger.new(IO::NULL)
    config.log_level = :fatal
    # `false` selects the production behaviour: `ShowExceptions` renders a plain
    # 500 and stores the exception in `action_dispatch.exception`, instead of
    # `DebugExceptions` rendering its interactive page.
    config.consider_all_requests_local = false
    config.action_dispatch.show_exceptions = :all
    config.secret_key_base = 'codetracer-rs-m6-demo-secret-key-base-0000'
    config.hosts.clear
    config.session_store :cookie_store, key: '_codetracer_demo'
    config.active_support.to_time_preserves_timezone = :zone

    routes.append do
      get '/api/users', to: 'code_tracer_demo/demo#index'
      post '/api/users', to: 'code_tracer_demo/demo#create'
      get '/api/users/:user_id', to: 'code_tracer_demo/demo#show'
      get '/static/app.css', to: 'code_tracer_demo/demo#stylesheet'
      get '/api/reports/slow', to: 'code_tracer_demo/demo#slow_report'
      get '/api/boom', to: 'code_tracer_demo/demo#boom'
      get '/health', to: 'code_tracer_demo/demo#health'
    end
  end
end
