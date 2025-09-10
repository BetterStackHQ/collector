#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'webmock/minitest'
require 'json'
require 'logger'
require_relative '../../providers/gcp'

class TestGCPProvider < Minitest::Test
  def setup
    @logger = Logger.new(nil)
    @provider = Providers::GCP.new(@logger)
    @base_url = 'http://metadata.google.internal/computeMetadata/v1/instance'
  end

  def test_fetch_metadata_success
    # GCP provider only fetches zone
    stub_request(:get, "#{@base_url}/zone")
      .with(headers: { 'Metadata-Flavor' => 'Google' })
      .to_return(status: 200, body: 'projects/123456789/zones/us-central1-a')

    metadata = @provider.fetch_metadata

    assert_equal 'us-central1', metadata[:region]
    assert_equal 'us-central1-a', metadata[:availability_zone]
    assert_equal 2, metadata.keys.size
  end

  def test_fetch_metadata_different_zone
    # Test with different zone format
    stub_request(:get, "#{@base_url}/zone")
      .with(headers: { 'Metadata-Flavor' => 'Google' })
      .to_return(status: 200, body: 'projects/456789/zones/europe-west1-b')

    metadata = @provider.fetch_metadata

    assert_equal 'europe-west1', metadata[:region]
    assert_equal 'europe-west1-b', metadata[:availability_zone]
    assert_equal 2, metadata.keys.size
  end

  def test_fetch_metadata_network_error
    # Zone request fails, indicating service not available
    stub_request(:get, "#{@base_url}/zone").to_return(status: 404)

    metadata = @provider.fetch_metadata
    assert_nil metadata
  end

  def test_fetch_metadata_timeout
    # Zone request times out
    stub_request(:get, "#{@base_url}/zone").to_timeout

    metadata = @provider.fetch_metadata
    assert_nil metadata
  end

  def test_parse_zone_formats
    # Test various zone formats
    test_cases = [
      ['projects/123/zones/us-central1-a', 'us-central1', 'us-central1-a'],
      ['projects/456/zones/asia-northeast1-c', 'asia-northeast1', 'asia-northeast1-c'],
      ['projects/789/zones/europe-west4-b', 'europe-west4', 'europe-west4-b'],
      ['us-west1-a', 'us-west1', 'us-west1-a'],  # Simple format
      ['us-east1', 'us', 'us-east1']  # Zone without letter suffix - rpartition removes last segment
    ]

    test_cases.each do |zone_response, expected_region, expected_zone|
      stub_request(:get, "#{@base_url}/zone")
        .with(headers: { 'Metadata-Flavor' => 'Google' })
        .to_return(status: 200, body: zone_response)

      metadata = @provider.fetch_metadata
      assert_equal expected_region, metadata[:region], "Failed for zone: #{zone_response}"
      assert_equal expected_zone, metadata[:availability_zone], "Failed for zone: #{zone_response}"
    end
  end
end
