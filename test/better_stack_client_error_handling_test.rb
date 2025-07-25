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
  end

  def test_ping_network_errors
    # Test various network errors
    [
      SocketError.new("getaddrinfo: Name or service not known"),
      Errno::ECONNREFUSED.new("Connection refused"),
      Errno::ETIMEDOUT.new("Connection timed out"),
      Net::OpenTimeout.new("execution expired"),
      Net::ReadTimeout.new("Net::ReadTimeout")
    ].each do |error|
      stub_request(:post, "https://telemetry.betterstack.com/api/collector/ping")
        .to_raise(error)
      
      output = capture_io do
        @client.ping
      end
      
      # Should handle error gracefully and write to errors.txt
      assert File.exist?(File.join(@test_dir, 'errors.txt'))
      error_content = File.read(File.join(@test_dir, 'errors.txt'))
      assert error_content.include?(error.class.name) || error_content.include?(error.message)
      
      # Clean up for next iteration
      File.delete(File.join(@test_dir, 'errors.txt'))
    end
  end

  def test_process_configuration_partial_download_failure
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
      puts "Downloading #{File.basename(path)} to #{path}"
      FileUtils.mkdir_p(File.dirname(path))
      
      if download_count == 2
        # Fail on second file
        false
      else
        File.write(path, "test content #{download_count}")
        true
      end
    end
    
    output = capture_io do
      result = @client.process_configuration(new_version, "200", { 'files' => files }.to_json)
      assert_nil result
    end
    
    assert_match(/Failed to download databases.json/, output.join)
    assert_match(/Aborting update due to download failure/, output.join)
    
    # Should have error file
    assert File.exist?(File.join(@test_dir, 'errors.txt'))
  end

  def test_process_configuration_with_invalid_json_response
    new_version = "2025-01-01T00:00:00"
    
    invalid_json_responses = [
      "not json at all",
      "{ invalid json }",
      '{ "files": "not an array" }',
      '{ "files": [{"no_path": true}] }'
    ]
    
    invalid_json_responses.each do |body|
      output = capture_io do
        @client.process_configuration(new_version, "200", body)
      end
      
      # Should handle gracefully
      assert File.exist?(File.join(@test_dir, 'errors.txt')) ||
             output.join.include?("Error") ||
             output.join.include?("Failed")
      
      # Clean up
      FileUtils.rm_f(File.join(@test_dir, 'errors.txt'))
    end
  end

  def test_process_configuration_with_path_traversal_attempt
    new_version = "2025-01-01T00:00:00"
    
    # Try various path traversal attempts
    malicious_files = [
      { 'path' => '/file', 'name' => '../../../etc/passwd' },
      { 'path' => '/file', 'name' => '/etc/passwd' },
      { 'path' => '/file', 'name' => '..\\..\\windows\\system32\\config\\sam' },
      { 'path' => '/file', 'name' => '' },
      { 'path' => '/file', 'name' => nil }
    ]
    
    malicious_files.each do |file_info|
      output = capture_io do
        @client.process_configuration(new_version, "200", { 'files' => [file_info] }.to_json)
      end
      
      assert_match(/Invalid filename|Failed/, output.join)
      assert File.exist?(File.join(@test_dir, 'errors.txt'))
      
      # Should not create files outside version directory
      assert !File.exist?('/etc/passwd.download')
      assert !File.exist?(File.join(@test_dir, '../passwd'))
      
      # Clean up
      FileUtils.rm_f(File.join(@test_dir, 'errors.txt'))
    end
  end

  def test_ping_with_nil_configuration_version
    # Mock ping response with nil configuration_version
    stub_request(:post, "https://telemetry.betterstack.com/api/collector/ping")
      .to_return(status: 200, body: { 
        'status' => 'new_version_available',
        'configuration_version' => nil 
      }.to_json)
    
    output = capture_io do
      @client.ping
    end
    
    # Should handle gracefully
    assert_match(/New version available/, output.join)
    # Should not crash trying to download with nil version
  end

  def test_cluster_collector_with_network_error
    stub_request(:post, "https://telemetry.betterstack.com/api/collector/cluster-collector")
      .to_raise(Errno::ENETUNREACH.new("Network is unreachable"))
    
    output = capture_io do
      result = @client.cluster_collector?
      assert_equal false, result
    end
    
    # Should return false on network error, not crash
    assert_match(/Unexpected response from cluster-collector endpoint/, output.join)
  end

  def test_write_error_with_filesystem_issues
    # Make errors.txt directory to cause write failure
    FileUtils.mkdir_p(File.join(@test_dir, 'errors.txt'))
    
    # Should not crash when unable to write error
    assert_nothing_raised do
      @client.send(:write_error, "Test error message")
    end
  end

  def test_clear_error_with_missing_file
    # Try to clear non-existent error file
    assert_nothing_raised do
      @client.send(:clear_error)
    end
  end

  def test_concurrent_ping_calls
    # Test multiple concurrent pings
    stub_request(:post, "https://telemetry.betterstack.com/api/collector/ping")
      .to_return(status: 204)
    
    threads = []
    5.times do
      threads << Thread.new do
        @client.ping
      end
    end
    
    # Should all complete without errors
    assert_nothing_raised do
      threads.each(&:join)
    end
  end
end