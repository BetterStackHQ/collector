#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'webmock/minitest'
require 'json'
require 'logger'
require_relative '../../providers/azure'

class TestAzureProvider < Minitest::Test
  def setup
    @logger = Logger.new(nil)
    @provider = Providers::Azure.new(@logger)
    @base_url = 'http://169.254.169.254/metadata/instance'
  end

  def test_fetch_metadata_success
    instance_data = {
      'compute' => {
        'subscriptionId' => 'abc123-def456-ghi789',
        'vmId' => 'vm-12345',
        'vmSize' => 'Standard_D2s_v3',
        'location' => 'eastus',
        'zone' => '1'
      },
      'network' => {
        'interface' => [
          {
            'ipv4' => {
              'ipAddress' => [
                {
                  'privateIpAddress' => '10.0.0.4',
                  'publicIpAddress' => '52.168.123.45'
                }
              ]
            }
          }
        ]
      }
    }

    stub_request(:get, "#{@base_url}?api-version=2021-02-01")
      .with(headers: { 'Metadata' => 'true' })
      .to_return(status: 200, body: instance_data.to_json)

    metadata = @provider.fetch_metadata

    assert_equal 'eastus', metadata[:region]
    assert_equal '1', metadata[:availability_zone]
    assert_equal 2, metadata.keys.size
  end

  def test_fetch_metadata_with_fault_domain
    instance_data = {
      'compute' => {
        'subscriptionId' => 'xyz789',
        'vmId' => 'vm-67890',
        'vmSize' => 'Standard_B2s',
        'location' => 'westeurope',
        'platformFaultDomain' => '2'  # No zone, use fault domain
      },
      'network' => {
        'interface' => [
          {
            'ipv4' => {
              'ipAddress' => [
                {
                  'privateIpAddress' => '192.168.1.10'
                  # No public IP
                }
              ]
            }
          }
        ]
      }
    }

    stub_request(:get, "#{@base_url}?api-version=2021-02-01")
      .with(headers: { 'Metadata' => 'true' })
      .to_return(status: 200, body: instance_data.to_json)

    metadata = @provider.fetch_metadata

    assert_equal 'westeurope', metadata[:region]
    assert_equal '2', metadata[:availability_zone]  # Falls back to platformFaultDomain
    assert_equal 2, metadata.keys.size
  end

  def test_fetch_metadata_missing_network_info
    instance_data = {
      'compute' => {
        'subscriptionId' => 'sub123',
        'vmId' => 'vm-abc',
        'vmSize' => 'Standard_A1',
        'location' => 'northeurope'
      }
      # No network section
    }

    stub_request(:get, "#{@base_url}?api-version=2021-02-01")
      .with(headers: { 'Metadata' => 'true' })
      .to_return(status: 200, body: instance_data.to_json)

    metadata = @provider.fetch_metadata

    assert_equal 'northeurope', metadata[:region]
    assert_nil metadata[:availability_zone]  # No zone or fault domain
    assert_equal 2, metadata.keys.size
  end

  def test_fetch_metadata_network_error
    stub_request(:get, "#{@base_url}?api-version=2021-02-01").to_return(status: 404)

    metadata = @provider.fetch_metadata
    assert_nil metadata
  end

  def test_fetch_metadata_timeout
    stub_request(:get, "#{@base_url}?api-version=2021-02-01").to_timeout

    metadata = @provider.fetch_metadata
    assert_nil metadata
  end

  def test_fetch_metadata_invalid_json
    stub_request(:get, "#{@base_url}?api-version=2021-02-01")
      .with(headers: { 'Metadata' => 'true' })
      .to_return(status: 200, body: 'not valid json')

    metadata = @provider.fetch_metadata
    assert_nil metadata
  end
end
