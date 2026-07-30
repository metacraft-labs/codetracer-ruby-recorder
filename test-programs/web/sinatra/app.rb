# frozen_string_literal: true

# RS-M6 demo app — Sinatra.
#
# A tiny REST-ish API whose routes cover every status bucket CodeTracer's
# Request Panel colours (2xx, 3xx, 4xx, 5xx), a parameterised route (so
# `http.route` can be shown to be the routed PATTERN and not the raw path), a
# handler slow enough that its duration is visibly non-zero, and a handler that
# raises (so a span carries an error status and an `error.message`).
#
# It is a plain `Sinatra::Base` subclass and therefore a plain Rack app: the
# span emission under test is `CodeTracer::Rack::Middleware`, which `serve.rb`
# wraps around this app.  Nothing CodeTracer-specific appears in this file —
# a demo that had to be written against the recorder would prove nothing about
# real applications.
#
# The handler bodies are deliberately several statements long: a span's step
# range is only interesting if the handler executes more than one step.

require 'json'
require 'sinatra/base'

module CodeTracerDemo
  # The demo API.  Routes are declared in the order the demo drives them.
  class SinatraApp < Sinatra::Base
    # `raise_errors` lets an exception escape to the surrounding Rack stack —
    # which is the path this demo wants exercised, because it is the
    # middleware's own `rescue` that then records the error.  `show_exceptions`
    # would otherwise replace the response with Sinatra's HTML debug page.
    set :raise_errors, true
    set :show_exceptions, false
    set :environment, :production
    set :logging, false

    USERS = {
      1 => { 'id' => 1, 'name' => 'Alice' },
      2 => { 'id' => 2, 'name' => 'Bob' }
    }.freeze

    get '/api/users' do
      content_type :json
      users = USERS.values
      payload = { 'users' => users, 'count' => users.length }
      JSON.generate(payload)
    end

    post '/api/users' do
      content_type :json
      body = request.body.read
      submitted = body.empty? ? {} : JSON.parse(body)
      created = { 'id' => USERS.keys.max + 1, 'name' => submitted['name'] || 'anonymous' }
      status 201
      JSON.generate(created)
    end

    get '/api/users/:user_id' do
      content_type :json
      user_id = params['user_id'].to_i
      user = USERS[user_id]
      if user.nil?
        status 404
        JSON.generate({ 'error' => "no user #{user_id}" })
      else
        JSON.generate(user)
      end
    end

    # A conditional-GET style response: no body, a 3xx status, so the panel's
    # "redirect" colour bucket is represented in the recording.
    get '/static/app.css' do
      status 304
      ''
    end

    # Slow enough that `http.duration_ms` is unambiguously non-trivial, which
    # is what makes the duration column assertable as more than "well formed".
    get '/api/reports/slow' do
      content_type :json
      sleep 0.05
      JSON.generate({ 'report' => 'slow', 'rows' => 3 })
    end

    get '/api/boom' do
      # Raised, not rescued: with `raise_errors` set this escapes into the Rack
      # stack, where `CodeTracer::Rack::Middleware` records the span as an error
      # and re-raises.
      raise ArgumentError, 'demo failure in /api/boom'
    end

    get '/health' do
      content_type :text
      'ok'
    end
  end
end
