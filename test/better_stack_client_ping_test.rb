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
    WebMock.reset!
  end

  def test_ping_updates_vector_config_when_kubernetes_discovery_changes
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

    # Track method calls
    validate_upstream_called = false
    promote_upstream_called = false
    prepare_dir_called = false
    validate_dir_called = false
    promote_dir_called = false

    # Mock vector_config methods
    vector_config = @client.instance_variable_get(:@vector_config)
    vector_config.define_singleton_method(:validate_upstream_file) { |path|
      validate_upstream_called = true
      nil
    }
    vector_config.define_singleton_method(:promote_upstream_file) { |path|
      promote_upstream_called = true
    }

    new_config_dir = File.join(@test_dir, 'vector-config', 'new_test')
    vector_config.define_singleton_method(:prepare_dir) do
      prepare_dir_called = true
      FileUtils.mkdir_p(new_config_dir)
      new_config_dir
    end

    vector_config.define_singleton_method(:validate_dir) { |dir|
      validate_dir_called = true
      nil
    }
    vector_config.define_singleton_method(:promote_dir) { |dir|
      promote_dir_called = true
    }

    @client.ping

    # Test actual behavior - should prepare, validate and promote new config
    assert validate_upstream_called, "Should validate upstream file"
    assert promote_upstream_called, "Should promote upstream file"
    assert prepare_dir_called, "Should prepare new directory when kubernetes discovery changes"
    assert validate_dir_called, "Should validate new directory"
    assert promote_dir_called, "Should promote new directory"
  end

  def test_ping_updates_vector_config_when_only_upstream_changes
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
    @client.instance_variable_get(:@kubernetes_discovery).define_singleton_method(:run) { false }

    # Track method calls
    validate_upstream_called = false
    promote_upstream_called = false
    prepare_dir_called = false
    validate_dir_called = false
    promote_dir_called = false

    # Mock vector_config methods
    vector_config = @client.instance_variable_get(:@vector_config)
    vector_config.define_singleton_method(:validate_upstream_file) { |path|
      validate_upstream_called = true
      nil
    }
    vector_config.define_singleton_method(:promote_upstream_file) { |path|
      promote_upstream_called = true
    }

    new_config_dir = File.join(@test_dir, 'vector-config', 'new_test')
    vector_config.define_singleton_method(:prepare_dir) do
      prepare_dir_called = true
      FileUtils.mkdir_p(new_config_dir)
      new_config_dir
    end

    vector_config.define_singleton_method(:validate_dir) { |dir|
      validate_dir_called = true
      nil
    }
    vector_config.define_singleton_method(:promote_dir) { |dir|
      promote_dir_called = true
    }

    @client.ping

    # Test actual behavior - should still update vector-config even without kubernetes discovery change
    assert validate_upstream_called, "Should validate upstream file"
    assert promote_upstream_called, "Should promote upstream file"
    assert prepare_dir_called, "Should prepare new directory for upstream change"
    assert validate_dir_called, "Should validate new directory"
    assert promote_dir_called, "Should promote new directory"
  end

  def test_ping_writes_error_when_vector_config_validation_fails
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

    # Track method calls
    promote_dir_called = false

    # Mock vector_config methods
    vector_config = @client.instance_variable_get(:@vector_config)
    vector_config.define_singleton_method(:validate_upstream_file) { |path| nil }
    vector_config.define_singleton_method(:promote_upstream_file) { |path| }

    new_config_dir = File.join(@test_dir, 'vector-config', 'new_test')
    vector_config.define_singleton_method(:prepare_dir) do
      FileUtils.mkdir_p(new_config_dir)
      new_config_dir
    end

    vector_config.define_singleton_method(:validate_dir) { |dir| "Validation failed: Invalid config" }
    vector_config.define_singleton_method(:promote_dir) { |dir|
      promote_dir_called = true
    }

    @client.ping

    # Test actual behavior - should not promote invalid config
    assert !promote_dir_called, "Should not promote directory when validation fails"
    assert File.exist?(File.join(@test_dir, 'errors.txt'))

    error_content = File.read(File.join(@test_dir, 'errors.txt'))
    assert error_content.include?("Validation failed for vector config with kubernetes_discovery")
  end

  def test_ping_clears_error_file_when_no_updates
    # Create an error file
    File.write(File.join(@test_dir, 'errors.txt'), "Previous error")

    # Mock ping response with no updates
    stub = stub_request(:post, "https://telemetry.betterstack.com/api/collector/ping")
      .to_return(status: 204)

    # Mock kubernetes discovery
    @client.instance_variable_get(:@kubernetes_discovery).define_singleton_method(:should_discover?) { false }

    @client.ping

    # Test actual behavior - should clear error file when no updates
    assert_requested(stub, times: 1)
    assert !File.exist?(File.join(@test_dir, 'errors.txt')), "Error file should be cleared"
  end
end