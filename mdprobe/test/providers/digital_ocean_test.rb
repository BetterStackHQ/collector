#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'webmock/minitest'
require 'json'
require 'logger'
require_relative '../../providers/digital_ocean'

class TestDigitalOceanProvider < Minitest::Test
  def setup
    @logger = Logger.new(nil)
    @provider = Providers::DigitalOcean.new(@logger)
    @base_url = 'http://169.254.169.254/metadata/v1'
  end

  def test_fetch_metadata_success
    # Mock individual field responses
    stub_request(:get, "#{@base_url}/id").to_return(status: 200, body: '289794365')

    stub_request(:get, "#{@base_url}/region").to_return(status: 200, body: 'nyc3')

    metadata = @provider.fetch_metadata

    assert_equal 'nyc3', metadata[:region]
    assert_equal 'nyc3', metadata[:availability_zone]
    assert_equal 2, metadata.keys.size
  end

  def test_fetch_metadata_different_region
    # Mock metadata with different region
    stub_request(:get, "#{@base_url}/id").to_return(status: 200, body: '123456789')

    stub_request(:get, "#{@base_url}/region").to_return(status: 200, body: 'sfo3')

    metadata = @provider.fetch_metadata

    assert_equal 'sfo3', metadata[:region]
    assert_equal 'sfo3', metadata[:availability_zone]
    assert_equal 2, metadata.keys.size
  end

  def test_fetch_metadata_no_region
    # Mock metadata with no region available
    stub_request(:get, "#{@base_url}/id").to_return(status: 200, body: '987654321')

    stub_request(:get, "#{@base_url}/region").to_return(status: 404)

    metadata = @provider.fetch_metadata

    assert_nil metadata[:region]
    assert_nil metadata[:availability_zone]
    assert_equal 2, metadata.keys.size
  end

  def test_fetch_metadata_network_error
    # ID request fails, indicating service not available
    stub_request(:get, "#{@base_url}/id").to_return(status: 404)

    metadata = @provider.fetch_metadata
    assert_nil metadata
  end

  def test_fetch_metadata_timeout
    # ID request times out
    stub_request(:get, "#{@base_url}/id").to_timeout

    metadata = @provider.fetch_metadata
    assert_nil metadata
  end
end
