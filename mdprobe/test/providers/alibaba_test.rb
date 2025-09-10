#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'webmock/minitest'
require 'json'
require 'logger'
require_relative '../../providers/alibaba'

class TestAlibabaProvider < Minitest::Test
  def setup
    @logger = Logger.new(nil)
    @provider = Providers::Alibaba.new(@logger)
    @base_url = 'http://100.100.100.200/latest/meta-data'
  end

  def test_fetch_metadata_success
    # Mock only the fields our minimal provider uses
    stub_request(:get, "#{@base_url}/instance-id").to_return(status: 200, body: 'i-bp1hygp5b04o1k1l0abc')

    stub_request(:get, "#{@base_url}/region-id").to_return(status: 200, body: 'cn-hangzhou')

    stub_request(:get, "#{@base_url}/zone-id").to_return(status: 200, body: 'cn-hangzhou-b')

    metadata = @provider.fetch_metadata

    assert_equal 'cn-hangzhou', metadata[:region]
    assert_equal 'cn-hangzhou-b', metadata[:availability_zone]
    # Only two fields in minimal implementation
    assert_equal 2, metadata.keys.size
  end

  def test_fetch_metadata_different_region
    stub_request(:get, "#{@base_url}/instance-id").to_return(status: 200, body: 'i-sg12345abcdefg')

    stub_request(:get, "#{@base_url}/region-id").to_return(status: 200, body: 'ap-southeast-1')

    stub_request(:get, "#{@base_url}/zone-id").to_return(status: 200, body: 'ap-southeast-1a')

    metadata = @provider.fetch_metadata

    assert_equal 'ap-southeast-1', metadata[:region]
    assert_equal 'ap-southeast-1a', metadata[:availability_zone]
  end

  def test_fetch_metadata_network_error
    # Instance ID request fails - service not available
    stub_request(:get, "#{@base_url}/instance-id").to_return(status: 404)

    metadata = @provider.fetch_metadata
    assert_nil metadata
  end

  def test_fetch_metadata_timeout
    stub_request(:get, "#{@base_url}/instance-id").to_timeout

    metadata = @provider.fetch_metadata
    assert_nil metadata
  end
end
