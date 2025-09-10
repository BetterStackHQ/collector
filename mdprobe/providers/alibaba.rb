# frozen_string_literal: true

require_relative 'base'

module Providers
  class Alibaba < Base
    METADATA_URL = 'http://100.100.100.200/latest/meta-data'

    def fetch_metadata
      # Check if service is available
      instance_id = get_metadata_field('instance-id')
      return nil unless instance_id
      
      build_metadata(
        region: get_metadata_field('region-id'),
        availability_zone: get_metadata_field('zone-id')
      )
    rescue => e
      @logger.debug "Failed to fetch Alibaba metadata: #{e.message}"
      nil
    end

    private

    def get_metadata_field(path)
      http_get("#{METADATA_URL}/#{path}")
    end
  end
end