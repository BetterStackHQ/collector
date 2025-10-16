require 'minitest/autorun'
require 'webmock/minitest'
require 'fileutils'
require 'tmpdir'
require_relative '../engine/better_stack_client'

class BetterStackClientErrorHandlingTest < Minitest::Test
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

  def test_ping_propagates_network_errors
    # The ping method doesn't handle network errors, they propagate
    stub_request(:post, "https://telemetry.betterstack.com/api/collector/ping")
      .to_raise(SocketError.new("getaddrinfo: Name or service not known"))

    assert_raises(SocketError) do
      @client.ping
    end
  end

  def test_process_configuration_stops_on_first_download_failure
    new_version = "2025-01-01T00:00:00"
    version_dir = File.join(@test_dir, 'versions', new_version)

    # Mock successful first file download, fail on second
    files = [
      { 'path' => '/file1', 'name' => 'vector.yaml' },
      { 'path' => '/file2', 'name' => 'databases.json' },
      { 'path' => '/file3', 'name' => 'other.yaml' }
    ]

    download_count = 0
    @client.define_singleton_method(:download_file) do |url, path|
      download_count += 1
      FileUtils.mkdir_p(File.dirname(path))

      if download_count == 2
        # Fail on second file
        raise Utils::DownloadError, "Failed to download databases.json from https://example.com/databases.json after 2 retries. Response code: 404"
      else
        File.write(path, "test content #{download_count}")
        true
      end
    end

    result = @client.process_configuration(new_version, "200", { 'files' => files }.to_json)

    # Test actual behavior
    assert_nil result
    # First file should exist
    assert File.exist?(File.join(version_dir, 'vector.yaml'))
    # Second and third files should not exist
    assert !File.exist?(File.join(version_dir, 'databases.json'))
    assert !File.exist?(File.join(version_dir, 'other.yaml'))
    # Should have error file
    assert File.exist?(File.join(@test_dir, 'errors.txt'))
  end

  def test_process_configuration_raises_on_invalid_json
    new_version = "2025-01-01T00:00:00"

    # The method expects valid JSON, it will raise on invalid JSON
    assert_raises(JSON::ParserError) do
      @client.process_configuration(new_version, "200", "not json at all")
    end
  end

  def test_process_configuration_rejects_path_traversal_filenames
    new_version = "2025-01-01T00:00:00"
    version_dir = File.join(@test_dir, 'versions', new_version)

    # Try various path traversal attempts
    malicious_files = [
      { 'path' => '/file', 'name' => '../../../etc/passwd' },
      { 'path' => '/file', 'name' => '/etc/passwd' },
      { 'path' => '/file', 'name' => '..\\..\\windows\\system32\\config\\sam' },
      { 'path' => '/file', 'name' => '' },
      { 'path' => '/file', 'name' => nil }
    ]

    malicious_files.each do |file_info|
      @client.process_configuration(new_version, "200", { 'files' => [file_info] }.to_json)

      # Test actual behavior - should reject malicious paths
      assert File.exist?(File.join(@test_dir, 'errors.txt'))

      # Should not create files outside version directory
      assert !File.exist?('/etc/passwd.download')
      assert !File.exist?(File.join(@test_dir, '../passwd'))

      # Verify no files created in version directory with path traversal
      if Dir.exist?(version_dir)
        files_in_version = Dir.glob(File.join(version_dir, '*'))
        files_in_version.each do |file|
          basename = File.basename(file)
          assert !basename.include?('..'), "Should not create files with .. in name"
          assert !basename.include?('/'), "Should not create files with / in name"
        end
      end

      # Clean up
      FileUtils.rm_f(File.join(@test_dir, 'errors.txt'))
    end
  end

  def test_ping_handles_nil_configuration_version_gracefully
    # Mock ping response with nil configuration_version
    stub_request(:post, "https://telemetry.betterstack.com/api/collector/ping")
      .to_return(status: 200, body: {
        'status' => 'new_version_available',
        'configuration_version' => nil
      }.to_json)

    # Track if get_configuration was called
    get_configuration_called = false
    @client.stub :get_configuration, lambda { |version|
      get_configuration_called = true
    } do
      # Should not crash
      @client.ping
    end

    # Should attempt to get configuration even with nil version
    assert get_configuration_called
  end

  def test_cluster_collector_propagates_network_errors
    stub_request(:post, "https://telemetry.betterstack.com/api/collector/cluster-collector")
      .to_raise(Errno::ENETUNREACH.new("Network is unreachable"))

    # The method doesn't handle network errors, they propagate
    assert_raises(Errno::ENETUNREACH) do
      @client.cluster_collector?
    end
  end

  def test_clear_error_succeeds_when_file_missing
    # Try to clear non-existent error file - should not crash
    @client.send(:clear_error)
  end

end