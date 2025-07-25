require 'minitest/autorun'
require 'webmock/minitest'
require 'fileutils'
require 'tmpdir'
require_relative '../engine/better_stack_client'

class BetterStackClientPingTest < Minitest::Test
  def setup
    @test_dir = Dir.mktmpdir
    ENV['COLLECTOR_SECRET'] = 'test_secret'
    @client = BetterStackClient.new(@test_dir)
    
    # Create required directories
    FileUtils.mkdir_p(File.join(@test_dir, 'vector-config'))
    FileUtils.mkdir_p(File.join(@test_dir, 'kubernetes-discovery', '0-default'))
  end

  def teardown
    FileUtils.rm_rf(@test_dir)
    ENV.delete('COLLECTOR_SECRET')
  end

  def test_ping_with_kubernetes_discovery_change
    # Mock ping response with new version
    stub_request(:post, "https://telemetry.betterstack.com/api/collector/ping")
      .to_return(status: 200, body: { status: 'new_version_available', configuration_version: '2025-01-01T00:00:00' }.to_json)
    
    # Mock configuration download
    stub_request(:post, "https://telemetry.betterstack.com/api/collector/configuration")
      .to_return(status: 200, body: { files: [{ path: '/file', name: 'vector.yaml' }] }.to_json)
    
    stub_request(:get, "https://telemetry.betterstack.com/file")
      .to_return(status: 200, body: "sources:\n  kubernetes_discovery_test:\n    type: prometheus_scrape")
    
    # Mock kubernetes discovery to return true (changed)
    @client.instance_variable_get(:@kubernetes_discovery).define_singleton_method(:should_discover?) { true }
    @client.instance_variable_get(:@kubernetes_discovery).define_singleton_method(:run) { true }
    
    # Mock vector_config methods
    vector_config = @client.instance_variable_get(:@vector_config)
    vector_config.define_singleton_method(:validate_upstream_file) { |path| nil }
    vector_config.define_singleton_method(:promote_upstream_file) { |path| puts "Promoted upstream file" }
    
    new_config_dir = nil
    new_config_dir = File.join(@test_dir, 'vector-config', 'new_test')
    vector_config.define_singleton_method(:prepare_dir) do
      FileUtils.mkdir_p(new_config_dir)
      new_config_dir
    end
    
    vector_config.define_singleton_method(:validate_dir) { |dir| nil }
    vector_config.define_singleton_method(:promote_dir) { |dir| puts "Promoted directory" }
    
    output = capture_io do
      @client.ping
    end
    
    assert_match(/New version available/, output.join)
    assert_match(/Kubernetes discovery changed - updating vector-config/, output.join)
    assert_match(/Promoted directory/, output.join)
  end

  def test_ping_with_only_upstream_change
    # Mock ping response with new version
    stub_request(:post, "https://telemetry.betterstack.com/api/collector/ping")
      .to_return(status: 200, body: { status: 'new_version_available', configuration_version: '2025-01-01T00:00:00' }.to_json)
    
    # Mock configuration download
    stub_request(:post, "https://telemetry.betterstack.com/api/collector/configuration")
      .to_return(status: 200, body: { files: [{ path: '/file', name: 'vector.yaml' }] }.to_json)
    
    stub_request(:get, "https://telemetry.betterstack.com/file")
      .to_return(status: 200, body: "sources:\n  test:\n    type: file")
    
    # Mock kubernetes discovery to return false (no change)
    @client.instance_variable_get(:@kubernetes_discovery).define_singleton_method(:should_discover?) { false }
    
    # Mock vector_config methods
    vector_config = @client.instance_variable_get(:@vector_config)
    vector_config.define_singleton_method(:validate_upstream_file) { |path| nil }
    vector_config.define_singleton_method(:promote_upstream_file) { |path| puts "Promoted upstream file" }
    
    new_config_dir = nil
    new_config_dir = File.join(@test_dir, 'vector-config', 'new_test')
    vector_config.define_singleton_method(:prepare_dir) do
      FileUtils.mkdir_p(new_config_dir)
      new_config_dir
    end
    
    vector_config.define_singleton_method(:validate_dir) { |dir| nil }
    vector_config.define_singleton_method(:promote_dir) { |dir| puts "Promoted directory" }
    
    output = capture_io do
      @client.ping
    end
    
    assert_match(/New version available/, output.join)
    assert_match(/Upstream configuration changed - updating vector-config/, output.join)
    assert_match(/Promoted directory/, output.join)
  end

  def test_ping_with_validation_failure
    # Mock ping response with new version
    stub_request(:post, "https://telemetry.betterstack.com/api/collector/ping")
      .to_return(status: 200, body: { status: 'new_version_available', configuration_version: '2025-01-01T00:00:00' }.to_json)
    
    # Mock configuration download
    stub_request(:post, "https://telemetry.betterstack.com/api/collector/configuration")
      .to_return(status: 200, body: { files: [{ path: '/file', name: 'vector.yaml' }] }.to_json)
    
    stub_request(:get, "https://telemetry.betterstack.com/file")
      .to_return(status: 200, body: "sources:\n  kubernetes_discovery_test:\n    type: prometheus_scrape")
    
    # Mock kubernetes discovery
    @client.instance_variable_get(:@kubernetes_discovery).define_singleton_method(:should_discover?) { true }
    @client.instance_variable_get(:@kubernetes_discovery).define_singleton_method(:run) { true }
    
    # Mock vector_config methods
    vector_config = @client.instance_variable_get(:@vector_config)
    vector_config.define_singleton_method(:validate_upstream_file) { |path| nil }
    vector_config.define_singleton_method(:promote_upstream_file) { |path| puts "Promoted upstream file" }
    
    new_config_dir = File.join(@test_dir, 'vector-config', 'new_test')
    vector_config.define_singleton_method(:prepare_dir) do
      FileUtils.mkdir_p(new_config_dir)
      new_config_dir
    end
    
    vector_config.define_singleton_method(:validate_dir) { |dir| "Validation failed: Invalid config" }
    
    # Create error file to ensure it's written
    FileUtils.touch(File.join(@test_dir, 'errors.txt'))
    
    output = capture_io do
      @client.ping
    end
    
    assert_match(/Kubernetes discovery changed/, output.join)
    assert File.exist?(File.join(@test_dir, 'errors.txt'))
    
    error_content = File.read(File.join(@test_dir, 'errors.txt'))
    assert_match(/Validation failed for vector config with kubernetes_discovery/, error_content)
  end

  def test_ping_no_updates_clears_error
    # Create an error file
    File.write(File.join(@test_dir, 'errors.txt'), "Previous error")
    
    # Mock ping response with no updates
    stub_request(:post, "https://telemetry.betterstack.com/api/collector/ping")
      .to_return(status: 204)
    
    # Mock kubernetes discovery
    @client.instance_variable_get(:@kubernetes_discovery).define_singleton_method(:should_discover?) { false }
    
    output = capture_io do
      @client.ping
    end
    
    assert_match(/No updates available/, output.join)
    assert !File.exist?(File.join(@test_dir, 'errors.txt')), "Error file should be cleared"
  end
end