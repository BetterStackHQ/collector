#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'webmock/minitest'
require 'json'
require 'logger'
require_relative '../../providers/scaleway'

class TestScalewayProvider < Minitest::Test
  def setup
    @logger = Logger.new(nil)
    @provider = Providers::Scaleway.new(@logger)
    @base_url = 'http://169.254.42.42'
  end

  def test_fetch_metadata_success
    # Mock key=value format response
    metadata_response = <<~EOF
      ID=aeb8cebb-5af6-49b8-b036-e8e7e816001a
      NAME=my-instance
      COMMERCIAL_TYPE=DEV1-S
      HOSTNAME=my-instance
      ORGANIZATION=b4bd99e0-b6ed-4e52-b95f-e627a77d8e57
      PROJECT=b4bd99e0-b6ed-4e52-b95f-e627a77d8e57
      ZONE=fr-par-1
      PRIVATE_IP=10.1.2.3
      PUBLIC_IP=51.15.123.45
    EOF

    stub_request(:get, "#{@base_url}/conf").to_return(status: 200, body: metadata_response)

    metadata = @provider.fetch_metadata

    assert_equal 'fr-par', metadata[:region]
    assert_equal 'fr-par-1', metadata[:availability_zone]
    assert_equal 2, metadata.keys.size
  end

  def test_fetch_metadata_different_zone
    # Test with different zone
    metadata_response = <<~EOF
      ID=xyz-123-456
      NAME=private-instance
      COMMERCIAL_TYPE=GP1-XS
      ORGANIZATION=org-12345
      ZONE=nl-ams-1
      PRIVATE_IP=192.168.50.100
    EOF

    stub_request(:get, "#{@base_url}/conf").to_return(status: 200, body: metadata_response)

    metadata = @provider.fetch_metadata

    assert_equal 'nl-ams', metadata[:region]
    assert_equal 'nl-ams-1', metadata[:availability_zone]
    assert_equal 2, metadata.keys.size
  end

  def test_fetch_metadata_zone_without_suffix
    # Test zone without number suffix
    metadata_response = "ZONE=fr-par\nID=abc-def-789\n"

    stub_request(:get, "#{@base_url}/conf").to_return(status: 200, body: metadata_response)

    metadata = @provider.fetch_metadata

    assert_equal 'fr-par', metadata[:region]
    assert_equal 'fr-par', metadata[:availability_zone]
  end

  def test_parse_region_from_zone
    test_cases = [
      ['fr-par-1', 'fr-par'],
      ['fr-par-2', 'fr-par'],
      ['nl-ams-1', 'nl-ams'],
      ['pl-waw-1', 'pl-waw'],
      ['fr-par', 'fr-par'],  # Zone without number
      ['unknown', 'unknown']
    ]

    test_cases.each do |zone, expected_region|
      metadata_response = "ZONE=#{zone}\nID=test-#{zone}\n"

      stub_request(:get, "#{@base_url}/conf").to_return(status: 200, body: metadata_response)

      metadata = @provider.fetch_metadata
      assert_equal expected_region, metadata[:region], "Failed for zone: #{zone}"
    end
  end

  def test_fetch_metadata_network_error
    stub_request(:get, "#{@base_url}/conf").to_return(status: 404)

    metadata = @provider.fetch_metadata
    assert_nil metadata
  end

  def test_fetch_metadata_timeout
    stub_request(:get, "#{@base_url}/conf").to_timeout

    metadata = @provider.fetch_metadata
    assert_nil metadata
  end

  def test_fetch_metadata_invalid_format
    # Test with invalid key=value format
    stub_request(:get, "#{@base_url}/conf").to_return(status: 200, body: 'not a valid format')

    metadata = @provider.fetch_metadata
    # Should return hash with nil values since no ZONE found
    assert_nil metadata[:region]
    assert_nil metadata[:availability_zone]
    assert_equal 2, metadata.keys.size
  end

  def test_fetch_metadata_minimal_response
    # Test with minimal valid response
    metadata_response = "ZONE=fr-par-1\n"

    stub_request(:get, "#{@base_url}/conf").to_return(status: 200, body: metadata_response)

    metadata = @provider.fetch_metadata

    assert_equal 'fr-par', metadata[:region]
    assert_equal 'fr-par-1', metadata[:availability_zone]
    assert_equal 2, metadata.keys.size
  end

  def test_fetch_metadata_empty_lines
    # Test with empty lines in response
    metadata_response = <<~EOF
      ZONE=pl-waw-1
      
      ID=proj-instance
      
      COMMERCIAL_TYPE=PRO2-M
    EOF

    stub_request(:get, "#{@base_url}/conf").to_return(status: 200, body: metadata_response)

    metadata = @provider.fetch_metadata

    assert_equal 'pl-waw', metadata[:region]
    assert_equal 'pl-waw-1', metadata[:availability_zone]
  end
end
