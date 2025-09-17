# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'

# Net::HTTP subclass for Unix socket support
class UnixSocketHttp < Net::HTTP
  def initialize(socket_path)
    super('localhost', nil)
    @socket_path = socket_path
  end

  def connect
    @socket = Net::BufferedIO.new(UNIXSocket.new(@socket_path))
    on_connect
  end
end

# Docker API client without external dependencies, following the style of engine/
class DockerClient
  DEFAULT_SOCKET = '/var/run/docker.sock'
  API_VERSION = 'v1.41'  # Docker API version

  def initialize(socket_path = nil)
    @socket_path = socket_path || ENV['DOCKER_HOST'] || "unix://#{DEFAULT_SOCKET}"
    @socket_path = @socket_path.sub(/^unix:\/\//, '') if @socket_path.start_with?('unix://')
    @http = nil
  end

  # List containers
  # Options:
  #   all: boolean - Show all containers (default false shows only running)
  def list_containers(options = {})
    params = []
    params << "all=#{options[:all]}" unless options[:all].nil?

    query_string = params.empty? ? '' : "?#{params.join('&')}"
    get("/containers/json#{query_string}")
  end

  # Get detailed container information
  def inspect_container(container_id)
    get("/containers/#{container_id}/json")
  end

  private

  def http
    @http ||= UnixSocketHttp.new(@socket_path)
  end

  def get(path)
    uri = URI("http://localhost/#{API_VERSION}#{path}")

    request = Net::HTTP::Get.new(uri.path + (uri.query ? "?#{uri.query}" : ''))
    request['Accept'] = 'application/json'
    request['Content-Type'] = 'application/json'

    response = http.request(request)

    # Handle response
    case response.code.to_i
    when 200, 201, 204
      return nil if response.body.nil? || response.body.empty?
      JSON.parse(response.body)
    when 404
      raise "Docker API endpoint not found: #{path}"
    else
      error_msg = "Docker API error (#{response.code}): "
      begin
        error_body = JSON.parse(response.body)
        error_msg += error_body['message'] || response.body
      rescue JSON::ParserError
        error_msg += response.body || 'Unknown error'
      end
      raise error_msg
    end
  rescue Errno::ENOENT, Errno::EACCES => e
    raise "Docker socket not accessible at #{@socket_path}: #{e.message}"
  end
end