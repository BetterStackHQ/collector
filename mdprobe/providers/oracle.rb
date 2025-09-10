# frozen_string_literal: true

require_relative 'base'

module Providers
  class Oracle < Base
    METADATA_URL = 'http://169.254.169.254/opc/v2'
    METADATA_HEADER = { 'Authorization' => 'Bearer Oracle' }

    def fetch_metadata
      instance_data = get_instance_metadata
      return nil unless instance_data

      build_metadata(
        region: instance_data['region'] || instance_data['canonicalRegionName'],
        availability_zone: instance_data['availabilityDomain']
      )
    rescue => e
      @logger.debug "Failed to fetch Oracle metadata: #{e.message}"
      nil
    end

    private

    def get_instance_metadata
      response = http_get("#{METADATA_URL}/instance", METADATA_HEADER)
      return nil unless response
      
      JSON.parse(response)
    rescue JSON::ParserError => e
      @logger.debug "Failed to parse Oracle instance metadata: #{e.message}"
      nil
    end
  end
end