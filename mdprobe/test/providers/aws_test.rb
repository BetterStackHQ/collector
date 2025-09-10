#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'webmock/minitest'
require 'json'
require 'logger'
require_relative '../../providers/aws'

class TestAWSProvider < Minitest::Test
  def setup
    @logger = Logger.new(nil)
    @provider = Providers::AWS.new(@logger)
    @base_url = 'http://169.254.169.254/latest'
  end

  def test_fetch_metadata_success
    # Mock token request (required for IMDSv2)
    stub_request(:put, "#{@base_url}/api/token")
      .with(headers: { 'X-aws-ec2-metadata-token-ttl-seconds' => '21600' })
      .to_return(status: 200, body: 'test-token')

    # Mock instance identity document - only need region and AZ
    instance_identity = {
      'region' => 'us-west-2',
      'availabilityZone' => 'us-west-2a'
    }

    stub_request(:get, "#{@base_url}/dynamic/instance-identity/document")
      .with(headers: { 'X-aws-ec2-metadata-token' => 'test-token' })
      .to_return(status: 200, body: instance_identity.to_json)

    metadata = @provider.fetch_metadata

    assert_equal 'us-west-2', metadata[:region]
    assert_equal 'us-west-2a', metadata[:availability_zone]
    assert_equal 2, metadata.keys.size
  end

  def test_fetch_metadata_different_region
    stub_request(:put, "#{@base_url}/api/token").to_return(status: 200, body: 'test-token')

    instance_identity = {
      'region' => 'eu-central-1',
      'availabilityZone' => 'eu-central-1b'
    }

    stub_request(:get, "#{@base_url}/dynamic/instance-identity/document")
      .with(headers: { 'X-aws-ec2-metadata-token' => 'test-token' })
      .to_return(status: 200, body: instance_identity.to_json)

    metadata = @provider.fetch_metadata

    assert_equal 'eu-central-1', metadata[:region]
    assert_equal 'eu-central-1b', metadata[:availability_zone]
  end

  def test_fetch_metadata_token_failure
    # Token request fails
    stub_request(:put, "#{@base_url}/api/token").to_return(status: 401)

    metadata = @provider.fetch_metadata
    assert_nil metadata
  end

  def test_fetch_metadata_timeout
    stub_request(:put, "#{@base_url}/api/token").to_timeout

    metadata = @provider.fetch_metadata
    assert_nil metadata
  end

  def test_fetch_metadata_invalid_identity_document
    stub_request(:put, "#{@base_url}/api/token").to_return(status: 200, body: 'test-token')

    stub_request(:get, "#{@base_url}/dynamic/instance-identity/document")
      .with(headers: { 'X-aws-ec2-metadata-token' => 'test-token' })
      .to_return(status: 200, body: 'invalid json')

    metadata = @provider.fetch_metadata
    assert_nil metadata
  end
end
