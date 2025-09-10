# frozen_string_literal: true

require_relative 'base'

module Providers
  class Hetzner < Base
    METADATA_URL = 'http://169.254.169.254/hetzner/v1/metadata'

    def fetch_metadata
      metadata = get_metadata
      return nil unless metadata

      build_metadata(
        region: metadata['region'],
        availability_zone: metadata['availability-zone']
      )
    rescue => e
      @logger.debug "Failed to fetch Hetzner metadata: #{e.message}"
      nil
    end

    private

    def get_metadata
      response = http_get(METADATA_URL)
      return nil unless response
      
      # Hetzner returns YAML format
      parse_yaml_metadata(response)
    rescue => e
      @logger.debug "Failed to parse Hetzner metadata: #{e.message}"
      nil
    end

    def parse_yaml_metadata(yaml_content)
      # Simple YAML parser for flat key-value pairs
      metadata = {}
      yaml_content.each_line do |line|
        next if line.strip.empty? || line.start_with?('#')
        
        if line.include?(':')
          key, value = line.split(':', 2)
          metadata[key.strip] = value.strip if key && value
        end
      end
      metadata
    end
  end
end