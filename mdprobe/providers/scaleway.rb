# frozen_string_literal: true

require_relative 'base'

module Providers
  class Scaleway < Base
    METADATA_URL = 'http://169.254.42.42'

    def fetch_metadata
      response = http_get("#{METADATA_URL}/conf")
      return nil unless response
      
      # Parse key=value format
      metadata = {}
      response.each_line do |line|
        next if line.strip.empty?
        key, value = line.strip.split('=', 2)
        metadata[key] = value if key && value
      end
      
      zone = metadata['ZONE']
      # Extract region from zone (e.g., fr-par-1 -> fr-par)
      region = zone ? zone.sub(/-\d+$/, '') : nil
      
      build_metadata(
        region: region,
        availability_zone: zone
      )
    rescue => e
      @logger.debug "Failed to fetch Scaleway metadata: #{e.message}"
      nil
    end
  end
end