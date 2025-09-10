# frozen_string_literal: true

require_relative 'base'

module Providers
  class GCP < Base
    METADATA_URL = 'http://metadata.google.internal/computeMetadata/v1'
    METADATA_HEADER = { 'Metadata-Flavor' => 'Google' }

    def fetch_metadata
      # GCP requires Metadata-Flavor header for all requests
      zone = get_metadata_field('instance/zone')
      return nil unless zone

      # Zone format: projects/PROJECT_NUMBER/zones/ZONE_NAME
      zone_parts = zone.split('/')
      zone_name = zone_parts.last if zone_parts.length > 0
      
      # Extract region from zone (e.g., us-central1-a -> us-central1)
      region = zone_name.rpartition('-').first if zone_name

      build_metadata(
        region: region,
        availability_zone: zone_name
      )
    rescue => e
      @logger.debug "Failed to fetch GCP metadata: #{e.message}"
      nil
    end

    private

    def get_metadata_field(path)
      http_get("#{METADATA_URL}/#{path}", METADATA_HEADER)
    end
  end
end