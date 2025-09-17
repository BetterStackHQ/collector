#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'webmock/minitest'
require 'json'
require 'logger'
require_relative '../../providers/oracle'

class TestOracleProvider < Minitest::Test
  def setup
    @logger = Logger.new(nil)
    @provider = Providers::Oracle.new(@logger)
    @base_url = 'http://169.254.169.254/opc/v2/instance'
  end

  def test_fetch_metadata_success
    # Mock full metadata response
    metadata_response = {
      'id' => 'ocid1.instance.oc1.iad.anuwcljt4q7f2vqcxyzabc123def456ghi789',
      'displayName' => 'my-oracle-instance',
      'shape' => 'VM.Standard.E2.1.Micro',
      'region' => 'us-ashburn-1',
      'canonicalRegionName' => 'us-ashburn-1',
      'ociAdName' => 'AD-1',
      'faultDomain' => 'FAULT-DOMAIN-2',
      'compartmentId' => 'ocid1.compartment.oc1..aaaaaaaabc123def456',
      'availabilityDomain' => 'Uocm:US-ASHBURN-AD-1',
      'metadata' => {
        'ssh_authorized_keys' => 'ssh-rsa AAAAB3...'
      },
      'vnics' => [
        {
          'vnicId' => 'ocid1.vnic.oc1.iad.abuwa',
          'privateIp' => '10.0.0.100',
          'publicIp' => '129.146.123.45',
          'macAddr' => '02:00:17:00:12:34',
          'subnetCidrBlock' => '10.0.0.0/24',
          'virtualRouterIp' => '10.0.0.1'
        }
      ]
    }

    stub_request(:get, @base_url)
      .with(headers: { 'Authorization' => 'Bearer Oracle' })
      .to_return(status: 200, body: metadata_response.to_json)

    metadata = @provider.fetch_metadata

    assert_equal 'us-ashburn-1', metadata[:region]
    assert_equal 'Uocm:US-ASHBURN-AD-1', metadata[:availability_zone]
    assert_equal 2, metadata.keys.size
  end

  def test_fetch_metadata_no_public_ip
    # Mock metadata without public IP
    metadata_response = {
      'id' => 'ocid1.instance.oc1.eu-frankfurt-1.private123',
      'displayName' => 'private-instance',
      'shape' => 'VM.Standard2.1',
      'region' => 'eu-frankfurt-1',
      'canonicalRegionName' => 'eu-frankfurt-1',
      'ociAdName' => 'AD-2',
      'compartmentId' => 'ocid1.compartment.oc1..private456',
      'availabilityDomain' => 'Uocm:EU-FRANKFURT-1-AD-2',
      'vnics' => [
        {
          'vnicId' => 'ocid1.vnic.oc1.eu-frankfurt-1.xyz',
          'privateIp' => '172.16.0.50'
          # No publicIp field
        }
      ]
    }

    stub_request(:get, @base_url)
      .with(headers: { 'Authorization' => 'Bearer Oracle' })
      .to_return(status: 200, body: metadata_response.to_json)

    metadata = @provider.fetch_metadata

    assert_equal 'eu-frankfurt-1', metadata[:region]
    assert_equal 'Uocm:EU-FRANKFURT-1-AD-2', metadata[:availability_zone]
    assert_equal 2, metadata.keys.size
  end

  def test_fetch_metadata_multiple_vnics
    # Test with multiple VNICs (should use first one)
    metadata_response = {
      'id' => 'ocid1.instance.oc1.ap-tokyo-1.multi',
      'shape' => 'VM.Standard.A1.Flex',
      'region' => 'ap-tokyo-1',
      'compartmentId' => 'ocid1.compartment.oc1..multivnic',
      'availabilityDomain' => 'Uocm:AP-TOKYO-1-AD-1',
      'vnics' => [
        {
          'vnicId' => 'ocid1.vnic.oc1.ap-tokyo-1.primary',
          'privateIp' => '192.168.1.10',
          'publicIp' => '140.238.123.45'
        },
        {
          'vnicId' => 'ocid1.vnic.oc1.ap-tokyo-1.secondary',
          'privateIp' => '192.168.2.10',
          'publicIp' => '140.238.123.46'
        }
      ]
    }

    stub_request(:get, @base_url)
      .with(headers: { 'Authorization' => 'Bearer Oracle' })
      .to_return(status: 200, body: metadata_response.to_json)

    metadata = @provider.fetch_metadata

    assert_equal 'ap-tokyo-1', metadata[:region]
    assert_equal 'Uocm:AP-TOKYO-1-AD-1', metadata[:availability_zone]
    assert_equal 2, metadata.keys.size
  end

  def test_fetch_metadata_no_vnics
    # Mock metadata without VNICs
    metadata_response = {
      'id' => 'ocid1.instance.oc1.ca-toronto-1.novnic',
      'shape' => 'BM.Standard2.52',
      'region' => 'ca-toronto-1',
      'compartmentId' => 'ocid1.compartment.oc1..novnic',
      'availabilityDomain' => 'Uocm:CA-TORONTO-1-AD-1'
      # No vnics array
    }

    stub_request(:get, @base_url)
      .with(headers: { 'Authorization' => 'Bearer Oracle' })
      .to_return(status: 200, body: metadata_response.to_json)

    metadata = @provider.fetch_metadata

    assert_equal 'ca-toronto-1', metadata[:region]
    assert_equal 'Uocm:CA-TORONTO-1-AD-1', metadata[:availability_zone]
    assert_equal 2, metadata.keys.size
  end

  def test_fetch_metadata_empty_vnics
    # Mock metadata with empty VNICs array
    metadata_response = {
      'id' => 'ocid1.instance.oc1.ap-mumbai-1.empty',
      'shape' => 'VM.Standard3.Flex',
      'region' => 'ap-mumbai-1',
      'compartmentId' => 'ocid1.compartment.oc1..empty',
      'availabilityDomain' => 'Uocm:AP-MUMBAI-1-AD-1',
      'vnics' => []  # Empty array
    }

    stub_request(:get, @base_url)
      .with(headers: { 'Authorization' => 'Bearer Oracle' })
      .to_return(status: 200, body: metadata_response.to_json)

    metadata = @provider.fetch_metadata

    assert_equal 'ap-mumbai-1', metadata[:region]
    assert_equal 'Uocm:AP-MUMBAI-1-AD-1', metadata[:availability_zone]
    assert_equal 2, metadata.keys.size
  end

  def test_fetch_metadata_network_error
    stub_request(:get, @base_url).to_return(status: 404)

    metadata = @provider.fetch_metadata
    assert_nil metadata
  end

  def test_fetch_metadata_timeout
    stub_request(:get, @base_url).to_timeout

    metadata = @provider.fetch_metadata
    assert_nil metadata
  end

  def test_fetch_metadata_invalid_json
    stub_request(:get, @base_url).to_return(status: 200, body: 'not valid json')

    metadata = @provider.fetch_metadata
    assert_nil metadata
  end

  def test_fetch_metadata_minimal_response
    # Test with minimal valid response
    metadata_response = {
      'id' => 'ocid1.instance.oc1.us-phoenix-1.minimal'
    }

    stub_request(:get, @base_url)
      .with(headers: { 'Authorization' => 'Bearer Oracle' })
      .to_return(status: 200, body: metadata_response.to_json)

    metadata = @provider.fetch_metadata

    # Minimal response has no region or availability zone
    assert_nil metadata[:region]
    assert_nil metadata[:availability_zone]
    assert_equal 2, metadata.keys.size
  end

  def test_fetch_metadata_various_regions
    # Test various Oracle Cloud regions
    regions = [
      'us-ashburn-1',
      'us-phoenix-1',
      'eu-frankfurt-1',
      'eu-amsterdam-1',
      'uk-london-1',
      'ca-toronto-1',
      'ca-montreal-1',
      'ap-tokyo-1',
      'ap-osaka-1',
      'ap-seoul-1',
      'ap-mumbai-1',
      'ap-sydney-1',
      'ap-melbourne-1',
      'sa-saopaulo-1',
      'me-jeddah-1',
      'me-dubai-1'
    ]

    regions.each do |region|
      metadata_response = {
        'id' => "ocid1.instance.oc1.#{region}.test",
        'region' => region,
        'compartmentId' => 'ocid1.compartment.oc1..test',
        'availabilityDomain' => "Uocm:#{region.upcase}-AD-1"
      }

      stub_request(:get, @base_url)
        .with(headers: { 'Authorization' => 'Bearer Oracle' })
        .to_return(status: 200, body: metadata_response.to_json)

      metadata = @provider.fetch_metadata
      assert_equal region, metadata[:region], "Failed for region: #{region}"
    end
  end
end
