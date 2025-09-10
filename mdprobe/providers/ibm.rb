# frozen_string_literal: true

require_relative 'base'

module Providers
  class IBM < Base
    TOKEN_URL = 'http://169.254.169.254/instance_identity/v1/token'
    METADATA_URL = 'http://169.254.169.254/metadata/v1/instance'
    
    def fetch_metadata
      # Get token
      token = get_token
      return nil unless token
      
      # Get instance metadata
      response = http_get(
        "#{METADATA_URL}?version=2022-03-01",
        'Authorization' => "Bearer #{token}"
      )
      return nil unless response
      
      data = JSON.parse(response)
      zone = data.dig('zone', 'name')
      
      # Extract region from zone (e.g., us-south-1 -> us-south)
      region = zone ? zone.sub(/-\d+$/, '') : nil
      
      build_metadata(
        region: region,
        availability_zone: zone
      )
    rescue => e
      @logger.debug "Failed to fetch IBM metadata: #{e.message}"
      nil
    end
    
    private
    
    def get_token
      response = http_put(
        TOKEN_URL,
        'Metadata-Flavor' => 'ibm'
      )
      return nil unless response
      
      data = JSON.parse(response)
      data['access_token']
    rescue => e
      @logger.debug "Failed to get IBM token: #{e.message}"
      nil
    end
  end
end