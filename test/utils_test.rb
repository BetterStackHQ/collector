require 'bundler/setup'
require 'minitest/autorun'
require 'webmock/minitest'
require 'net/http'
require_relative '../engine/utils'

def override_backtick_command(override_command, result, status, &block)
  original_backtick = Kernel.method(:`)

  begin
    Kernel.send(:define_method, :`) do |command|
      if command == override_command
        fork { exit status }
        Process.wait
        result
      else
        original_backtick.call(command)
      end
    end

    yield block
  ensure
    Kernel.send(:define_method, :`) do |command|
      original_backtick.call(command)
    end
  end
end

class UtilsTest < Minitest::Test
  include Utils

  def setup
    # Create a temporary working directory for tests
    @test_dir = File.join(Dir.pwd, 'engine', 'test_tmp')
    @working_dir = @test_dir
    FileUtils.mkdir_p(@test_dir)
    FileUtils.mkdir_p(File.join(@test_dir, 'versions'))
  end

  def teardown
    # Clean up temporary test directory
    FileUtils.rm_rf(@test_dir) if File.exist?(@test_dir)
  end

  def test_latest_version
    # Create test version directories with different dates
    versions = ['2022-01-01T00:00:00', '2022-02-01T00:00:00', '2021-12-01T00:00:00']
    versions.each do |version|
      FileUtils.mkdir_p(File.join(@working_dir, 'versions', version))
    end

    assert_equal '2022-02-01T00:00:00', latest_version
  end

  def test_latest_version_no_versions
    # Test with no version directories
    assert_nil latest_version
  end

  def test_read_error
    # Test reading error from file
    error_message = "Test error message"
    File.write(File.join(@working_dir, 'errors.txt'), error_message)

    assert_equal URI.encode_www_form_component(error_message), read_error
  end

  def test_read_error_no_file
    # Test when error file doesn't exist
    assert_nil read_error
  end

  def test_write_error
    # Test writing error to file
    error_message = "Test error message"
    write_error(error_message)

    assert_equal error_message, File.read(File.join(@working_dir, 'errors.txt'))
  end

  def test_validate_vector_config
    version = "test_version"
    config_dir = File.join(@working_dir, 'versions', version)
    config_path = File.join(config_dir, 'vector.yaml')
    FileUtils.mkdir_p(config_dir)

    # Test case 1: Valid configuration
    File.write(config_path, "valid: config\nsinks:\n  console:\n    type: console")

    override_backtick_command "REGION=unknown AZ=unknown vector validate #{config_path}", "Validated", 0 do
      assert_nil validate_vector_config(version), "Should return nil for valid config"
    end

    # Test case 2: Config with security issue (command:)
    File.write(config_path, "sinks:\n  dangerous:\n    type: exec\n    command: /bin/sh")

    assert_equal "vector.yaml must not contain command: directives", validate_vector_config(version)

    # Test case 3: Config with validation failure
    File.write(config_path, "invalid: config\nbroken_yaml")

    failed_validation_output = "Failed to load [\"#{config_path}\"]\n----------------------------------------------------------------------------------------------------------\nx could not find expected ':' at line 3 column 1, while scanning a simple key at line 2 column 1\n\n"
    override_backtick_command "REGION=unknown AZ=unknown vector validate #{config_path}", failed_validation_output, 78 do
      result = validate_vector_config(version)
      assert result.is_a?(String), "Should return error message string when vector validate returns false"
      assert_match(/Failed to load/, result, "Should contain validation error message")
    end
  end


  def test_download_file
    # Test successful download
    url = 'https://example.com/file.txt'
    path = File.join(@working_dir, 'downloaded_file.txt')
    content = 'file content'

    stub_request(:get, url)
      .with(query: hash_including("host"))
      .to_return(body: content, status: 200)

    assert download_file(url, path)
    assert File.exist?(path)
    assert_equal content, File.read(path)
  end

  def test_download_file_failure
    # Test download failure
    url = 'https://example.com/file.txt'
    path = File.join(@working_dir, 'downloaded_file.txt')

    stub_request(:get, url)
      .with(query: hash_including("host"))
      .to_return(status: 404)

    refute download_file(url, path)
    refute File.exist?(path)
  end

  def test_download_file_network_error
    # Test network error
    url = 'https://example.com/file.txt'
    path = File.join(@working_dir, 'downloaded_file.txt')

    stub_request(:get, url)
      .with(query: hash_including("host"))
      .to_raise(SocketError.new("getaddrinfo: nodename nor servname provided, or not known"))

    refute download_file(url, path)
    refute File.exist?(path)
  end

  def test_latest_database_json_with_file
    # Create test version directory with databases.json
    version = '2022-02-01T00:00:00'
    FileUtils.mkdir_p(File.join(@working_dir, 'versions', version))

    # Create test databases.json
    db_json_content = '{"databases":[{"name":"test-db","host":"localhost"}]}'
    FileUtils.mkdir_p(File.join(@working_dir, 'versions', version))
    File.write(File.join(@working_dir, 'versions', version, 'databases.json'), db_json_content)

    assert_equal db_json_content, latest_database_json
  end

  def test_latest_database_json_no_file
    # Create test version directory without databases.json
    version = '2022-02-01T00:00:00'
    FileUtils.mkdir_p(File.join(@working_dir, 'versions', version))

    assert_equal '{}', latest_database_json
  end

  def test_latest_database_json_no_versions
    # Test with no version directories
    assert_equal '{}', latest_database_json
  end

  def test_latest_kubernetes_discovery_returns_latest_full_path
    discovery_dir = File.join(@working_dir, 'kubernetes-discovery')
    %w[2024-01-01T00:00:00 2024-03-01T00:00:00 2024-02-15T12:30:00].each do |version|
      FileUtils.mkdir_p(File.join(discovery_dir, version))
    end

    expected_path = File.join(discovery_dir, '2024-03-01T00:00:00')
    assert_equal expected_path, latest_kubernetes_discovery
  end

  def test_hostname
    # Pretend hostname is not available to test other fallback mechanisms
    original_hostname = ENV['HOSTNAME']
    ENV['HOSTNAME'] = nil

    # Test fallback to Socket.gethostname when host files not available
    # Mock Socket.gethostname to return a known value
    original_method = Socket.method(:gethostname)
    Socket.define_singleton_method(:gethostname) { "test-hostname" }

    # Test when host files are not accessible (common test environment case)
    assert_equal "test-hostname", hostname

    # Restore original method
    Socket.define_singleton_method(:gethostname, original_method)

    # Create a mock file to test hostname from file
    host_proc_dir = File.join(@test_dir, 'host', 'proc', 'sys', 'kernel')
    FileUtils.mkdir_p(host_proc_dir)
    File.write(File.join(host_proc_dir, 'hostname'), "host-from-proc\n")

    # Mock File.exist? to pretend we have access to host files
    original_exist = File.method(:exist?)
    File.define_singleton_method(:exist?) do |path|
      if path == '/host/proc/sys/kernel/hostname'
        true
      else
        original_exist.call(path)
      end
    end

    # Mock File.read to return our test content
    original_read = File.method(:read)
    File.define_singleton_method(:read) do |path, *args|
      if path == '/host/proc/sys/kernel/hostname'
        "host-from-proc\n"
      else
        original_read.call(path, *args)
      end
    end

    # Test reading from host proc
    assert_equal "host-from-proc", hostname

    # Restore original methods
    File.define_singleton_method(:exist?, original_exist)
    File.define_singleton_method(:read, original_read)

    # Despite all the previous setup, if HOSTNAME is set, it should be used
    ENV['HOSTNAME'] = 'host-from-env'
    assert_equal "host-from-env", hostname

    # Restore original env var
    ENV['HOSTNAME'] = original_hostname
  end
end
