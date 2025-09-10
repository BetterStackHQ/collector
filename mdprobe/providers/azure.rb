# frozen_string_literal: true

require_relative 'base'

module Providers
  class Azure < Base
    METADATA_URL = 'http://169.254.169.254/metadata/instance'
    API_VERSION = '2021-02-01'
    METADATA_HEADER = { 'Metadata' => 'true' }

    def fetch_metadata
      # Azure requires Metadata header and api-version parameter
      instance_data = get_instance_metadata
      return nil unless instance_data

      compute = instance_data['compute'] || {}
      
      build_metadata(
        region: compute['location'],
        availability_zone: compute['zone'] || compute['platformFaultDomain']
      )
    rescue => e
      @logger.debug "Failed to fetch Azure metadata: #{e.message}"
      nil
    end

    private

    def get_instance_metadata
      url = "#{METADATA_URL}?api-version=#{API_VERSION}"
      response = http_get(url, METADATA_HEADER)
      return nil unless response
      
      JSON.parse(response)
    rescue JSON::ParserError => e
      @logger.debug "Failed to parse Azure metadata: #{e.message}"
      nil
    end
  end
end