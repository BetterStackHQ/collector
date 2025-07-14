#!/usr/bin/env ruby

require 'webrick'
require 'json'
require 'uri'
require 'fileutils'

# Required environment variables:
# - INGESTING_HOST: The host to ingest data to (e.g. "logs.betterstack.com")
# - SOURCE_TOKEN: The source token for authentication
# - COLLECTOR_SECRET: The collector secret for testing (default: "COLLECTOR_SECRET")

# Validate required environment variables
raise "INGESTING_HOST environment variable must be set" unless ENV['INGESTING_HOST']
raise "SOURCE_TOKEN environment variable must be set" unless ENV['SOURCE_TOKEN']
raise "COLLECTOR_SECRET environment variable must be set" unless ENV['COLLECTOR_SECRET']

# Set constants
PORT = 3010
REQUIRED_SECRET = ENV['COLLECTOR_SECRET']
LATEST_VERSION = "2025-05-11T11:13:00.000"
TEST_FILES_DIR = File.join(File.dirname(__FILE__), 'versions', LATEST_VERSION)

# Ensure test files directory exists
FileUtils.mkdir_p(TEST_FILES_DIR)

# Create server
server = WEBrick::HTTPServer.new(Port: PORT)

# Helper method to validate collector secret
def validate_secret(req)
  # For POST requests, parameters are in the request body
  if req.request_method == "POST"
    params = req.body ? WEBrick::HTTPUtils.parse_query(req.body) : {}
    secret = params['collector_secret']
  else
    # still handle GET params
    secret = req.query['collector_secret']
  end

  secret == REQUIRED_SECRET
end

# Helper method to log request details
def log_request(req)
  puts "=== REQUEST ==="
  puts "Path: #{req.path}"
  puts "Method: #{req.request_method}"
  if req.request_method == "POST"
    puts "POST params: #{WEBrick::HTTPUtils.parse_query(req.body)}" if req.body && !req.body.empty?
  else
    puts "Query params: #{req.query}"
  end
  puts "==============="
end

# Helper method to log response details
def log_response(res)
  puts "=== RESPONSE ==="
  puts "Status: #{res.status}"
  puts "Body: #{res.body}"
  puts "==============="
  puts
  puts
end

# Helper method to mount endpoints with logging
def mount_endpoint(server, path, &block)
  server.mount_proc "/api#{path}" do |req, res|
    log_request(req)
    block.call(req, res)
    log_response(res)
  end
end

# Default handler for /
mount_endpoint(server, '/') do |req, res|
  res.body = "Hello world from test/test_server.rb"
end

# Endpoint: /collector/ping
mount_endpoint(server, '/collector/ping') do |req, res|
  # Only accept POST requests
  if req.request_method != "POST"
    res.status = 405
    res.body = JSON.generate({ status: 'method_not_allowed' })
    next
  end

  unless validate_secret(req)
    res.status = 401
    res.body = JSON.generate({ status: 'invalid_collector_secret' })
    next
  end

  # For POST requests, parameters are in the request body
  params = req.body ? WEBrick::HTTPUtils.parse_query(req.body) : {}
  current_version = params['configuration_version']

  if current_version == LATEST_VERSION
    res.status = 204
  else
    res.status = 200
    res.body = JSON.generate({
      status: 'new_version_available',
      configuration_version: LATEST_VERSION
    })
  end
end

# Endpoint: /collector/configuration
mount_endpoint(server, '/collector/configuration') do |req, res|
  # Only accept POST requests
  if req.request_method != "POST"
    res.status = 405
    res.body = JSON.generate({ status: 'method_not_allowed' })
    next
  end

  unless validate_secret(req)
    res.status = 401
    res.body = JSON.generate({ status: 'invalid_collector_secret' })
    next
  end

  # For POST requests, parameters are in the request body
  params = req.body ? WEBrick::HTTPUtils.parse_query(req.body) : {}
  configuration_version = params['configuration_version']

  if configuration_version == LATEST_VERSION
    res.status = 200
    res.body = JSON.generate({
      files: [
        {
          path: "/api/collector/configuration-file?file=vector.yaml&configuration_version=#{configuration_version}",
          name: "vector.yaml"
        },
        {
          path: "/api/collector/configuration-file?file=databases.json&configuration_version=#{configuration_version}",
          name: "databases.json"
        }
      ]
    })
  else
    res.status = 404
    res.body = JSON.generate({ status: 'version_not_found' })
  end
end

# Endpoint: /collector/cluster-collector
mount_endpoint(server, '/collector/cluster-collector') do |req, res|
  # Only accept POST requests
  if req.request_method != "POST"
    res.status = 405
    res.body = JSON.generate({ status: 'method_not_allowed' })
    next
  end

  unless validate_secret(req)
    res.status = 401
    res.body = JSON.generate({ status: 'invalid_collector_secret' })
    next
  end

  # Return 409 to indicate this is not a cluster collector
  res.status = 409
end

# Endpoint for file downloads
mount_endpoint(server, '/collector/configuration-file') do |req, res|
  filename = req.query['file']
  configuration_version = req.query['configuration_version']

  # Security check to prevent directory traversal
  if filename.nil? || filename.empty? || filename.include?('..') || filename.start_with?('/')
    res.status = 400
    res.body = "Invalid filename"
    next
  end

  file_path = File.join(File.dirname(__FILE__), 'versions', configuration_version, filename)

  if File.exist?(file_path)
    res.status = 200
    content = File.read(file_path)

    # Replace placeholders with environment variables
    content.gsub!('INGESTING_HOST', ENV['INGESTING_HOST'])
    content.gsub!('SOURCE_TOKEN', ENV['SOURCE_TOKEN'])

    res.body = content

    # Set appropriate content type
    if filename.end_with?('.json')
      res['Content-Type'] = 'application/json'
    elsif filename.end_with?('.yaml', '.yml')
      res['Content-Type'] = 'application/yaml'
    else
      res['Content-Type'] = 'text/plain'
    end
  else
    res.status = 404
    res.body = "File not found"
  end
end

# Setup signal handling for graceful shutdown
trap('INT') { server.shutdown }
trap('TERM') { server.shutdown }

# Start the server
puts "Starting test server on port #{PORT}"
puts "Required collector secret: #{REQUIRED_SECRET}"
puts "Latest version: #{LATEST_VERSION}"
puts "Using INGESTING_HOST: #{ENV['INGESTING_HOST']}"
puts "Using SOURCE_TOKEN: #{ENV['SOURCE_TOKEN']}"
puts "Using COLLECTOR_SECRET: #{ENV['COLLECTOR_SECRET']}"
server.start
