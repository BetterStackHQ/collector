# frozen_string_literal: true

require_relative 'base'

module Providers
  class AWS < Base
    METADATA_URL = 'http://169.254.169.254/latest'
    TOKEN_TTL = 21600  # 6 hours

    def fetch_metadata
      # AWS IMDSv2 requires a token
      token = get_token
      return nil unless token

      # Fetch instance identity for region and AZ
      instance_identity = get_instance_identity(token)
      return nil unless instance_identity

      build_metadata(
        region: instance_identity['region'],
        availability_zone: instance_identity['availabilityZone']
      )
    rescue => e
      @logger.debug "Failed to fetch AWS metadata: #{e.message}"
      nil
    end

    private

    def get_token
      http_put(
        "#{METADATA_URL}/api/token",
        'X-aws-ec2-metadata-token-ttl-seconds' => TOKEN_TTL.to_s
      )
    end

    def get_instance_identity(token)
      response = http_get(
        "#{METADATA_URL}/dynamic/instance-identity/document",
        'X-aws-ec2-metadata-token' => token
      )
      return nil unless response
      
      JSON.parse(response)
    rescue JSON::ParserError => e
      @logger.debug "Failed to parse instance identity: #{e.message}"
      nil
    end
  end
end