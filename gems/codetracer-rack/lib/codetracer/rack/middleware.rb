# frozen_string_literal: true

require_relative 'span_recorder'

module CodeTracer
  module Rack
    # Rack middleware that records each HTTP request as a `web-request` span in
    # the CodeTracer trace container the recorder is producing (RS-M6).
    #
    # ## What changed in RS-M6
    #
    # This middleware used to append a row of HTTP metadata to a
    # `codetracer_spans.jsonl` sidecar, and to call a
    # `CodeTracer::Native.begin_span` that had never existed.  It now writes a
    # span RECORD into the container's `spans.dat` stream (spec:
    # `codetracer-specs/Trace-Files/CTFS-Request-Span-Streams.md`).
    #
    # The difference that matters is *binding*.  A sidecar row was HTTP
    # metadata with no way back into the recording; a span record names a
    # `(process, thread, step range)` coordinate INSIDE the container, which is
    # what lets CodeTracer's Request Panel seek from a request row into that
    # request's handler.  Sidecar emission is retained one more release but is
    # now opt-in — see `span_recorder.rb`.
    #
    # ## Usage
    #
    #   use CodeTracer::Rack::Middleware
    #
    # In Sinatra:
    #
    #   class App < Sinatra::Base
    #     use CodeTracer::Rack::Middleware, framework: 'sinatra'
    #   end
    #
    # In Rails:
    #
    #   config.middleware.use CodeTracer::Rack::Middleware, framework: 'rails'
    #
    # Mounting it is always safe: with no recorder installed in the process
    # every entry point is a no-op and nothing is written anywhere.
    #
    # ## Options
    #
    # * `:framework` — recorded as the `framework` metadata key.
    # * `:concurrent` — mark the emitted spans as possibly overlapping their
    #   siblings.  Set it for a thread-per-request server; the default (false)
    #   describes the single-threaded serving the tests and demos use.
    # * `:publish_open` — append an in-flight record at request start (default
    #   true), which is what makes a live panel show a request before it
    #   finishes.
    # * `:manifest_path` — write the legacy JSONL sidecar to this path.
    #   Opt-in; `CODETRACER_SPAN_MANIFEST` does the same.
    # * `:route` — fallback `http.route` for an app whose framework publishes
    #   none.
    #
    # ## Where the middleware must sit
    #
    # `http.route` is read from the request environment AFTER the wrapped app
    # has run, because the router is what puts it there.  That works from any
    # position in the stack, but the span's step range only means "this
    # request's handler" if the middleware is close to the app: everything
    # below it in the stack falls inside the range.
    class Middleware
      def initialize(app, options = {})
        @app = app
        @options = options
        @span_recorder = RequestSpanRecorder.new(
          framework: options[:framework].to_s,
          concurrent: options.fetch(:concurrent, false),
          publish_open: options.fetch(:publish_open, true),
          manifest_path: options[:manifest_path]
        )
      end

      def call(env)
        http_method = env['REQUEST_METHOD']
        url = request_url(env)
        # The span object lives in THIS frame for the whole request.  No
        # thread-local, no "current span" global: two requests in flight at once
        # (a threaded server, or an app that re-enters this middleware) must not
        # be able to see each other's state.
        pending = @span_recorder.begin_request(http_method, url, env['REMOTE_ADDR'].to_s)

        begin
          status, headers, body = @app.call(env)
        rescue StandardError => e
          # An exception that escapes the app is a 500 as far as the client is
          # concerned, and the span says so plus why.  The exception is
          # re-raised: this middleware observes, it never swallows.
          pending.finish(
            500,
            route: route_for(env),
            error_message: "#{e.class}: #{e.message}"
          )
          raise
        end

        pending.finish(
          status.to_i,
          response_size: response_size(headers),
          route: route_for(env),
          error_message: error_message_for(env, status)
        )
        [status, headers, body]
      end

      private

      # The request URL as the panel shows it: path plus query string.
      #
      # `SCRIPT_NAME` is included so a Rack app mounted under a prefix reports
      # the URL the client actually asked for.
      def request_url(env)
        path = "#{env['SCRIPT_NAME']}#{env['PATH_INFO']}"
        path = '/' if path.empty?
        query = env['QUERY_STRING'].to_s
        query.empty? ? path : "#{path}?#{query}"
      end

      # The ROUTED PATTERN this request matched, not the concrete path — which
      # is the whole point of `http.route`: `/api/users/:id` groups every
      # request to that endpoint, while `/api/users/42` groups nothing.
      #
      # Each framework publishes it in the request environment during dispatch,
      # so this must be read AFTER the app has run:
      #
      # * Sinatra sets `sinatra.route` to `"GET /api/users/:id"`
      #   (`sinatra/base.rb`, `route_eval`); the method is stripped here so the
      #   value is a route in every framework.
      # * Rails (>= 7.1) sets `action_dispatch.route_uri_pattern` to the Journey
      #   pattern, e.g. `/api/users/:id(.:format)`
      #   (`action_dispatch/journey/router.rb`); the optional format suffix is
      #   dropped because it is a Rails encoding detail rather than part of the
      #   route a user recognises.
      #
      # A plain Rack app has no router and therefore no route; the key is then
      # omitted rather than filled in with the raw path, which would make an
      # unrouted app look as though it had one route per URL.
      def route_for(env)
        sinatra_route = env['sinatra.route']
        if sinatra_route.is_a?(String) && !sinatra_route.empty?
          # "GET /api/users/:id" -> "/api/users/:id"
          parts = sinatra_route.split(' ', 2)
          return parts.length == 2 ? parts[1] : sinatra_route
        end

        rails_route = env['action_dispatch.route_uri_pattern']
        if rails_route.is_a?(String) && !rails_route.empty?
          return rails_route.sub(/\(\.:format\)\z/, '')
        end

        @options[:route]
      end

      # `Content-Length` when the framework computed one.  Returns nil (rather
      # than 0) when it did not, so "no size reported" stays distinguishable
      # from "an empty body" in the panel.
      def response_size(headers)
        return nil unless headers.respond_to?(:each)

        headers.each do |key, value|
          return value.to_i if key.to_s.downcase == 'content-length'
        end
        nil
      end

      # A 5xx produced by the framework's OWN exception handling — Rails rescues
      # in `ActionDispatch::ShowExceptions`, Sinatra in `Sinatra::Base#call!` —
      # never reaches this middleware's `rescue`.  Both leave the exception in
      # the environment, so the span can still say what went wrong.
      def error_message_for(env, status)
        return nil if status.to_i < 500

        error = env['action_dispatch.exception'] || env['sinatra.error'] || env['rack.exception']
        return nil unless error.respond_to?(:message)

        "#{error.class}: #{error.message}"
      end
    end
  end
end
