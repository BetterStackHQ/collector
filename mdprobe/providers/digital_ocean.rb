# frozen_string_literal: true

require_relative 'base'

module Providers
  class DigitalOcean < Base
    METADATA_URL = 'http://169.254.169.254/metadata/v1'

    def fetch_metadata
      # Check if the metadata service is available by fetching ID
      instance_id = get_metadata_field('id')
      return nil unless instance_id

      region = get_metadata_field('region')

      build_metadata(
        region: region,
        availability_zone: region  # Same as the region per coroot
      )
    rescue => e
      @logger.debug "Failed to fetch DigitalOcean metadata: #{e.message}"
      nil
    end

    private

    def get_metadata_field(path)
      http_get("#{METADATA_URL}/#{path}")
    end
  end
end
