#!/usr/bin/env ruby

# cluster-agent proxy
#
# 1. It provides a configuration endpoint (/v1/config) that serves the latest database configuration
#    to the Cluster Agent, allowing it to monitor databases in the cluster.
# 2. It acts as a proxy for metrics requests (/v1/metrics), forwarding them to Vector's metrics endpoint.
#    endpoint (localhost:39090).
#
# The server runs on port 33000 and is a critical component for the collector's functionality,
# enabling remote configuration and metrics access.

require 'webrick'
require 'json'
require 'net/http'
require 'uri'
require_relative 'engine/utils'

class WebServer
  include Utils

  def initialize(working_dir)
    @working_dir = working_dir
  end

  def start
    server = WEBrick::HTTPServer.new(Port: 33000)

    server.mount_proc '/v1/config' do |req, res|
      res.content_type = 'application/json'
      res.body = latest_database_json
    end

    # to preserve compatibility and prevent errors
    server.mount_proc '/v1/metrics' do |req, res|
      begin
        uri = URI('http://localhost:39090/')

        # Forward the request to the target server (localhost:39090)
        response = Net::HTTP.start(uri.host, uri.port) do |http|
          # Create new request object based on original request method
          proxy_req = case req.request_method
          when 'GET'
            Net::HTTP::Get.new(uri)
          when 'POST'
            Net::HTTP::Post.new(uri)
          else
            raise "Unsupported HTTP method: #{req.request_method}"
          end

          # Copy all original headers except 'host' to maintain request context
          req.header.each { |k,v| proxy_req[k] = v unless k.downcase == 'host' }

          # Copy request body for POST requests
          proxy_req.body = req.body if req.request_method == 'POST'

          # Send request and get response
          http.request(proxy_req)
        end

        # Copy response status, headers and body back to client
        res.status = response.code
        response.each_header { |k,v| res[k] = v }
        res.body = response.body
      rescue => e
        # Return 502 Bad Gateway if proxy request fails
        puts "Bad Gateway error: #{e.message}"
        res.status = 502
        res.body = "Bad Gateway: #{e.message}"
      end
    end

    trap 'INT' do server.shutdown end
    trap 'TERM' do server.shutdown end

    $stdout.sync = true
    server.start
  end
end

working_dir = File.expand_path(File.dirname(__FILE__))

web_server = WebServer.new(working_dir)
web_server.start
