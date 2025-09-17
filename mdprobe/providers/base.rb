# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'timeout'

module Providers
  # Base class for all cloud metadata providers
  class Base
    METADATA_SERVICE_TIMEOUT = 5  # seconds

    def initialize(logger)
      @logger = logger
    end

    # Must be implemented by subclasses
    def fetch_metadata
      raise NotImplementedError, "#{self.class} must implement fetch_metadata"
    end

    protected

    # Common HTTP request with timeout
    def http_get(url, headers = {})
      uri = URI(url)
      
      Timeout.timeout(METADATA_SERVICE_TIMEOUT) do
        http = Net::HTTP.new(uri.host, uri.port)
        http.open_timeout = METADATA_SERVICE_TIMEOUT
        http.read_timeout = METADATA_SERVICE_TIMEOUT
        
        request = Net::HTTP::Get.new(uri)
        headers.each { |k, v| request[k] = v }
        
        response = http.request(request)
        
        if response.code.to_i == 200
          response.body
        else
          @logger.debug "HTTP request failed: #{response.code} #{response.message}"
          nil
        end
      end
    rescue Timeout::Error, StandardError => e
      @logger.debug "HTTP request error: #{e.message}"
      nil
    end

    # Common HTTP PUT request with timeout (for AWS tokens)
    def http_put(url, headers = {})
      uri = URI(url)
      
      Timeout.timeout(METADATA_SERVICE_TIMEOUT) do
        http = Net::HTTP.new(uri.host, uri.port)
        http.open_timeout = METADATA_SERVICE_TIMEOUT
        http.read_timeout = METADATA_SERVICE_TIMEOUT
        
        request = Net::HTTP::Put.new(uri)
        headers.each { |k, v| request[k] = v }
        
        response = http.request(request)
        
        if response.code.to_i == 200
          response.body
        else
          @logger.debug "HTTP PUT request failed: #{response.code} #{response.message}"
          nil
        end
      end
    rescue Timeout::Error, StandardError => e
      @logger.debug "HTTP PUT request error: #{e.message}"
      nil
    end

    # Build minimal metadata hash with only region and availability zone
    def build_metadata(region: nil, availability_zone: nil)
      {
        region: region,
        availability_zone: availability_zone
      }
    end
  end
end