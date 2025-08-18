#!/usr/bin/env ruby

# Proxy server for cluster agent and node agent metrics
#
# The server is a critical component for the collector's functionality, enabling remote
# configuration and metrics access.
#
# This server runs on port 33000 and provides:
# 1. /v1/config - Serves the latest database configuration (databases.json) to the Cluster Agent
# 2. /v1/cluster-agent-enabled - Returns "yes" or "no" based on BetterStackClient.cluster_collector?
# 3. /v1/metrics - Proxies requests to Vector's metrics endpoint (localhost:39090)
#
# The cluster agent running in the beyla container connects to this proxy via host network
# to fetch configuration and check if it should be running.
# 
# The node agent also runs in the beyla container and connects to the /v1/metrics endpoint
# via host network.


require 'webrick'
require 'json'
require 'net/http'
require 'uri'
require_relative 'engine/utils'
require_relative 'engine/better_stack_client'

class WebServer
  include Utils

  def initialize(working_dir)
    @working_dir = working_dir
    @client = BetterStackClient.new(working_dir)
  end

  def start
    server = WEBrick::HTTPServer.new(Port: 33000)

    server.mount_proc '/v1/config' do |req, res|
      res.content_type = 'application/json'
      res.body = latest_database_json
    end

    server.mount_proc '/v1/cluster-agent-enabled' do |req, res|
      res.content_type = 'text/plain'
      res.body = @client.cluster_collector? ? "yes" : "no"
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
