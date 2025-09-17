#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'webmock/minitest'
require 'json'
require 'logger'
require_relative '../../providers/ibm'

class TestIBMProvider < Minitest::Test
  def setup
    @logger = Logger.new(nil)
    @provider = Providers::IBM.new(@logger)
    @token_url = 'http://169.254.169.254/instance_identity/v1/token'
    @metadata_url = 'http://169.254.169.254/metadata/v1/instance'
  end

  def test_fetch_metadata_success
    # Mock token request
    stub_request(:put, @token_url)
      .with(headers: { 'Metadata-Flavor' => 'ibm' })
      .to_return(
        status: 200,
        body: { 'access_token' => 'test-token-12345' }.to_json
      )

    # Mock metadata request
    metadata_response = {
      'initialization' => {
        'user_data' => 'user-data-here'
      },
      'name' => 'my-vsi-instance',
      'id' => 'i-0123456789abcdef0',
      'profile' => {
        'name' => 'cx2-2x4'
      },
      'zone' => {
        'name' => 'us-south-1'
      },
      'vpc' => {
        'id' => 'vpc-12345',
        'name' => 'my-vpc'
      },
      'primary_network_interface' => {
        'id' => 'eth0-12345',
        'primary_ipv4_address' => '10.240.0.4',
        'floating_ips' => [
          {
            'address' => '169.63.123.45'
          }
        ]
      }
    }

    stub_request(:get, "#{@metadata_url}?version=2022-03-01")
      .with(headers: { 'Authorization' => 'Bearer test-token-12345' })
      .to_return(status: 200, body: metadata_response.to_json)

    metadata = @provider.fetch_metadata

    assert_equal 'us-south', metadata[:region]
    assert_equal 'us-south-1', metadata[:availability_zone]
    assert_equal 2, metadata.keys.size
  end

  def test_fetch_metadata_no_floating_ips
    # Mock token request
    stub_request(:put, @token_url)
      .with(headers: { 'Metadata-Flavor' => 'ibm' })
      .to_return(
        status: 200,
        body: { 'access_token' => 'test-token-67890' }.to_json
      )

    # Mock metadata without floating IPs
    metadata_response = {
      'name' => 'private-vsi',
      'id' => 'i-private-instance',
      'profile' => {
        'name' => 'bx2-4x16'
      },
      'zone' => {
        'name' => 'eu-de-2'
      },
      'vpc' => {
        'id' => 'vpc-67890'
      },
      'primary_network_interface' => {
        'primary_ipv4_address' => '172.16.10.20'
        # No floating_ips array
      }
    }

    stub_request(:get, "#{@metadata_url}?version=2022-03-01")
      .with(headers: { 'Authorization' => 'Bearer test-token-67890' })
      .to_return(status: 200, body: metadata_response.to_json)

    metadata = @provider.fetch_metadata

    assert_equal 'eu-de', metadata[:region]
    assert_equal 'eu-de-2', metadata[:availability_zone]
    assert_equal 2, metadata.keys.size
  end

  def test_fetch_metadata_empty_floating_ips
    # Mock token request
    stub_request(:put, @token_url)
      .with(headers: { 'Metadata-Flavor' => 'ibm' })
      .to_return(
        status: 200,
        body: { 'access_token' => 'test-token-empty' }.to_json
      )

    # Mock metadata with empty floating IPs array
    metadata_response = {
      'id' => 'i-empty-floating',
      'profile' => { 'name' => 'mx2-2x16' },
      'zone' => { 'name' => 'jp-tok-1' },
      'vpc' => { 'id' => 'vpc-japan' },
      'primary_network_interface' => {
        'primary_ipv4_address' => '192.168.1.10',
        'floating_ips' => []  # Empty array
      }
    }

    stub_request(:get, "#{@metadata_url}?version=2022-03-01")
      .with(headers: { 'Authorization' => 'Bearer test-token-empty' })
      .to_return(status: 200, body: metadata_response.to_json)

    metadata = @provider.fetch_metadata

    assert_equal 'jp-tok', metadata[:region]
    assert_equal 'jp-tok-1', metadata[:availability_zone]
    assert_equal 2, metadata.keys.size
  end

  def test_parse_region_from_zone
    test_cases = [
      ['us-south-1', 'us-south'],
      ['us-south-2', 'us-south'],
      ['us-east-1', 'us-east'],
      ['eu-de-1', 'eu-de'],
      ['eu-de-2', 'eu-de'],
      ['jp-tok-1', 'jp-tok'],
      ['au-syd-1', 'au-syd'],
      ['ca-tor-1', 'ca-tor'],
      ['br-sao-1', 'br-sao'],
      ['unknown', 'unknown']  # No dash-digit pattern
    ]

    test_cases.each do |zone, expected_region|
      stub_request(:put, @token_url)
        .to_return(status: 200, body: { 'access_token' => "token-#{zone}" }.to_json)

      metadata_response = {
        'id' => "test-#{zone}",
        'zone' => { 'name' => zone },
        'vpc' => { 'id' => 'test-vpc' },
        'primary_network_interface' => {
          'primary_ipv4_address' => '10.0.0.1'
        }
      }

      stub_request(:get, "#{@metadata_url}?version=2022-03-01")
        .with(headers: { 'Authorization' => "Bearer token-#{zone}" })
        .to_return(status: 200, body: metadata_response.to_json)

      metadata = @provider.fetch_metadata
      assert_equal expected_region, metadata[:region], "Failed for zone: #{zone}"
    end
  end

  def test_fetch_metadata_token_failure
    # Token request fails
    stub_request(:put, @token_url).to_return(status: 401)

    metadata = @provider.fetch_metadata
    assert_nil metadata
  end

  def test_fetch_metadata_token_timeout
    stub_request(:put, @token_url).to_timeout

    metadata = @provider.fetch_metadata
    assert_nil metadata
  end

  def test_fetch_metadata_invalid_token_json
    stub_request(:put, @token_url).to_return(status: 200, body: 'not valid json')

    metadata = @provider.fetch_metadata
    assert_nil metadata
  end

  def test_fetch_metadata_data_request_failure
    # Token succeeds but metadata request fails
    stub_request(:put, @token_url).to_return(status: 200, body: { 'access_token' => 'valid-token' }.to_json)

    stub_request(:get, "#{@metadata_url}?version=2022-03-01").to_return(status: 403)

    metadata = @provider.fetch_metadata
    assert_nil metadata
  end

  def test_fetch_metadata_minimal_response
    stub_request(:put, @token_url).to_return(status: 200, body: { 'access_token' => 'minimal-token' }.to_json)

    # Minimal valid response
    metadata_response = {
      'id' => 'i-minimal'
      # No other fields
    }

    stub_request(:get, "#{@metadata_url}?version=2022-03-01")
      .with(headers: { 'Authorization' => 'Bearer minimal-token' })
      .to_return(status: 200, body: metadata_response.to_json)

    metadata = @provider.fetch_metadata

    assert_nil metadata[:region]
    assert_nil metadata[:availability_zone]
    assert_equal 2, metadata.keys.size
  end

  def test_fetch_metadata_multiple_floating_ips
    # Test with multiple floating IPs (should use first one)
    stub_request(:put, @token_url).to_return(status: 200, body: { 'access_token' => 'multi-ip-token' }.to_json)

    metadata_response = {
      'id' => 'i-multi-ip',
      'zone' => { 'name' => 'us-south-3' },
      'vpc' => { 'id' => 'vpc-multi' },
      'primary_network_interface' => {
        'primary_ipv4_address' => '10.10.10.10',
        'floating_ips' => [
          { 'address' => '52.116.123.45' },
          { 'address' => '52.116.123.46' },
          { 'address' => '52.116.123.47' }
        ]
      }
    }

    stub_request(:get, "#{@metadata_url}?version=2022-03-01")
      .with(headers: { 'Authorization' => 'Bearer multi-ip-token' })
      .to_return(status: 200, body: metadata_response.to_json)

    metadata = @provider.fetch_metadata

    assert_equal 'us-south', metadata[:region]
    assert_equal 'us-south-3', metadata[:availability_zone]
    assert_equal 2, metadata.keys.size
  end
end
