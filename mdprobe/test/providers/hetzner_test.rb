#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'webmock/minitest'
require 'json'
require 'logger'
require_relative '../../providers/hetzner'

class TestHetznerProvider < Minitest::Test
  def setup
    @logger = Logger.new(nil)
    @provider = Providers::Hetzner.new(@logger)
    @base_url = 'http://169.254.169.254/hetzner/v1/metadata'
  end

  def test_fetch_metadata_success
    # Mock YAML metadata response
    yaml_response = <<~YAML
      region: eu-central
      availability-zone: fsn1-dc14
    YAML

    stub_request(:get, @base_url).to_return(status: 200, body: yaml_response)

    metadata = @provider.fetch_metadata

    assert_equal 'eu-central', metadata[:region]
    assert_equal 'fsn1-dc14', metadata[:availability_zone]
    assert_equal 2, metadata.keys.size
  end

  def test_fetch_metadata_partial_response
    # Mock metadata with only region
    yaml_response = <<~YAML
      region: eu-central
    YAML

    stub_request(:get, @base_url).to_return(status: 200, body: yaml_response)

    metadata = @provider.fetch_metadata

    assert_equal 'eu-central', metadata[:region]
    assert_nil metadata[:availability_zone]
    assert_equal 2, metadata.keys.size
  end

  def test_fetch_metadata_different_zone
    # Test different availability zone
    yaml_response = <<~YAML
      region: eu-central
      availability-zone: nbg1-dc3
    YAML

    stub_request(:get, @base_url).to_return(status: 200, body: yaml_response)

    metadata = @provider.fetch_metadata

    assert_equal 'eu-central', metadata[:region]
    assert_equal 'nbg1-dc3', metadata[:availability_zone]
    assert_equal 2, metadata.keys.size
  end

  def test_fetch_metadata_minimal_response
    # Test with empty YAML response
    yaml_response = ""

    stub_request(:get, @base_url).to_return(status: 200, body: yaml_response)

    metadata = @provider.fetch_metadata

    assert_nil metadata[:region]
    assert_nil metadata[:availability_zone]
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

  def test_fetch_metadata_invalid_yaml
    stub_request(:get, @base_url).to_return(status: 200, body: "invalid: yaml: content: with: colons")

    metadata = @provider.fetch_metadata
    # Should still parse successfully as the parser is simple
    refute_nil metadata
  end

  def test_fetch_metadata_yaml_comments
    # Test with YAML containing comments
    yaml_response = <<~YAML
      # This is a comment
      region: us-east
      # Another comment
      availability-zone: ash1-dc1
    YAML

    stub_request(:get, @base_url).to_return(status: 200, body: yaml_response)

    metadata = @provider.fetch_metadata

    assert_equal 'us-east', metadata[:region]
    assert_equal 'ash1-dc1', metadata[:availability_zone]
    assert_equal 2, metadata.keys.size
  end
end
