# frozen_string_literal: true

require 'net/http'
require 'json'
require 'socket'
require 'uri'

# Docker API client without external dependencies, following the style of engine/
class DockerClient
  DEFAULT_SOCKET = '/var/run/docker.sock'
  API_VERSION = 'v1.41'  # Docker API version

  def initialize(socket_path = nil)
    @socket_path = socket_path || ENV['DOCKER_HOST'] || "unix://#{DEFAULT_SOCKET}"
    @socket_path = @socket_path.sub(/^unix:\/\//, '') if @socket_path.start_with?('unix://')
  end

  # List containers
  # Options:
  #   all: boolean - Show all containers (default false shows only running)
  def list_containers(options = {})
    params = []
    params << "all=#{options[:all]}" unless options[:all].nil?
    
    query_string = params.empty? ? '' : "?#{params.join('&')}"
    request(:get, "/containers/json#{query_string}")
  end

  # Get detailed container information
  def inspect_container(container_id)
    request(:get, "/containers/#{container_id}/json")
  end

  private

  def request(method, path)
    uri = URI("http://localhost/#{API_VERSION}#{path}")
    
    response = nil
    begin
      # Use Unix socket directly
      socket = UNIXSocket.new(@socket_path)
      
      # Build HTTP request
      request_line = "#{method.to_s.upcase} #{uri.path}#{uri.query ? "?#{uri.query}" : ''} HTTP/1.1\r\n"
      headers = "Host: localhost\r\n"
      headers += "Accept: application/json\r\n"
      headers += "Content-Type: application/json\r\n"
      headers += "Connection: close\r\n"
      headers += "\r\n"
      
      # Send request
      socket.write(request_line + headers)
      
      # Read headers first
      header_text = ''
      while line = socket.gets
        header_text += line
        break if line == "\r\n"  # Empty line marks end of headers
      end
      
      # Parse headers to get content-length or transfer-encoding
      content_length = nil
      chunked = false
      header_text.lines.each do |line|
        if line =~ /^Content-Length:\s*(\d+)/i
          content_length = $1.to_i
        elsif line =~ /^Transfer-Encoding:\s*chunked/i
          chunked = true
        end
      end
      
      # Read body based on transfer method
      body = ''
      if chunked
        # Read chunked response
        while true
          # Read chunk size
          chunk_line = socket.gets
          chunk_size = chunk_line.strip.to_i(16)
          break if chunk_size == 0
          
          # Read chunk data
          body += socket.read(chunk_size)
          socket.gets  # Read trailing CRLF after chunk
        end
        socket.gets  # Read final CRLF after last chunk
      elsif content_length
        # Read exact content length
        body = socket.read(content_length) if content_length > 0
      else
        # Read until connection closes (for Connection: close)
        body = socket.read
      end
      
      socket.close
      
      # Parse HTTP response
      response = parse_http_response(header_text + "\r\n" + body)
    rescue Errno::ENOENT, Errno::EACCES => e
      raise "Docker socket not accessible at #{@socket_path}: #{e.message}"
    rescue => e
      raise "Docker API request failed: #{e.message}"
    end
    
    # Handle response
    case response[:code].to_i
    when 200, 201, 204
      return nil if response[:body].nil? || response[:body].empty?
      JSON.parse(response[:body])
    when 404
      raise "Docker API endpoint not found: #{path}"
    else
      error_msg = "Docker API error (#{response[:code]}): "
      begin
        error_body = JSON.parse(response[:body])
        error_msg += error_body['message'] || response[:body]
      rescue
        error_msg += response[:body] || 'Unknown error'
      end
      raise error_msg
    end
  end

  def parse_http_response(response_text)
    # Split headers and body
    header_end = response_text.index("\r\n\r\n")
    return { code: 500, body: '' } unless header_end
    
    headers = response_text[0...header_end]
    body = response_text[(header_end + 4)..]
    
    # Parse status line
    status_line = headers.lines.first
    status_match = status_line.match(/HTTP\/\d\.\d (\d+)/)
    return { code: 500, body: '' } unless status_match
    
    { code: status_match[1], body: body }
  end
end