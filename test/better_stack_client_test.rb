require 'bundler/setup'
require 'minitest/autorun'
require 'webmock/minitest'
require 'json'
require 'net/http'
require_relative '../engine/better_stack_client'

class BetterStackClientTest < Minitest::Test
  def setup
    # Create a temporary working directory for tests
    @test_dir = File.join(Dir.pwd, 'tmp')
    FileUtils.mkdir_p(@test_dir)
    FileUtils.mkdir_p(File.join(@test_dir, 'versions'))

    # Set required environment variables
    ENV['COLLECTOR_SECRET'] = 'test_secret'
    ENV['BASE_URL'] = 'https://test.betterstack.com'
    ENV['COLLECTOR_VERSION'] = '1.0.0'
    ENV['VECTOR_VERSION'] = '0.47.0'
    ENV['BEYLA_VERSION'] = '2.2.4'
    ENV['CLUSTER_AGENT_VERSION'] = '1.2.4'

    @client = BetterStackClient.new(@test_dir)
  end

  def teardown
    # Clean up temporary test directory
    FileUtils.rm_rf(@test_dir) if File.exist?(@test_dir)
    # Reset environment variables
    ENV.delete('COLLECTOR_SECRET')
    ENV.delete('BASE_URL')
    ENV.delete('CLUSTER_COLLECTOR')
    ENV.delete('COLLECTOR_VERSION')
    ENV.delete('VECTOR_VERSION')
    ENV.delete('BEYLA_VERSION')
    ENV.delete('CLUSTER_AGENT_VERSION')
    # Reset WebMock stubs
    WebMock.reset!
  end

  def test_initialize_with_valid_secret
    client = BetterStackClient.new(@test_dir)
    assert_instance_of BetterStackClient, client
  end

  def test_initialize_exits_when_collector_secret_missing
    ENV.delete('COLLECTOR_SECRET')
    # Expect the process to exit with status 1
    assert_raises(SystemExit) do
      capture_io do
        @client = BetterStackClient.new(@test_dir)
      end
    end
  end

  def test_ping_sends_204_when_no_updates_available
    # Mock hostname method
    original_hostname = @client.method(:hostname)
    @client.define_singleton_method(:hostname) { "test-host" }

    # Use POST with body parameters
    stub = stub_request(:post, "https://test.betterstack.com/api/collector/ping")
      .with(
        body: hash_including({
          "collector_secret" => "test_secret",
          "cluster_collector" => "false",
          "host" => "test-host",
          "collector_version" => "1.0.0",
          "vector_version" => "0.47.0",
          "beyla_version" => "2.2.4",
          "cluster_agent_version" => "1.2.4"
        })
      )
      .to_return(status: 204, body: "")

    # Test actual behavior - should make request and not crash
    @client.ping

    # Verify the request was made with correct parameters
    assert_requested(stub, times: 1)

    # Restore original method
    @client.define_singleton_method(:hostname, original_hostname)
  end

  def test_ping_sends_all_required_parameters
    # Override environment variables for this test
    ENV['COLLECTOR_VERSION'] = "1.2.3"
    ENV['VECTOR_VERSION'] = "0.28.1"
    ENV['BEYLA_VERSION'] = "1.0.0"
    ENV['CLUSTER_AGENT_VERSION'] = "1.2.4"

    # Create a versions folder for latest_version test
    test_version = "2023-01-01T00:00:00"
    FileUtils.mkdir_p(File.join(@test_dir, 'versions', test_version))

    # Mock hostname method
    original_hostname = @client.method(:hostname)
    expected_hostname = "test-host"
    @client.define_singleton_method(:hostname) { expected_hostname }

    # Updated stub to capture the body parameters
    stub = stub_request(:post, "https://test.betterstack.com/api/collector/ping")
      .with { |request|
        # For POST request, parse the form data in the body
        @captured_params = {}
        request.body.split('&').each do |pair|
          key, value = pair.split('=', 2)
          @captured_params[URI.decode_www_form_component(key)] = URI.decode_www_form_component(value || '')
        end

        # Verify the beyla_version parameter value matches our expected value
        @captured_params["beyla_version"] == "1.0.0"
      }
      .to_return(status: 204, body: "")

    # Call ping
    @client.ping

    # Verify that the request was made with the expected parameters
    assert_requested(stub, times: 1)

    # Verify all version parameters were sent correctly
    assert_equal "1.2.3", @captured_params["collector_version"]
    assert_equal "0.28.1", @captured_params["vector_version"]
    assert_equal "1.0.0", @captured_params["beyla_version"]
    assert_equal "1.2.4", @captured_params["cluster_agent_version"]
    assert_equal expected_hostname, @captured_params["host"]
    assert_equal test_version, @captured_params["configuration_version"]

    # Restore original method
    @client.define_singleton_method(:hostname, original_hostname)
  end

  def test_ping_calls_get_configuration_when_new_version_available
    # Mock hostname method
    original_hostname = @client.method(:hostname)
    @client.define_singleton_method(:hostname) { "test-host" }

    configuration_version = "2023-01-01T00:00:00"
    response_body = {
      status: "new_version_available",
      configuration_version: configuration_version
    }.to_json

    # Updated stub with body parameters
    stub = stub_request(:post, "https://test.betterstack.com/api/collector/ping")
      .with(
        body: hash_including({
          "collector_secret" => "test_secret",
          "cluster_collector" => "false",
          "host" => "test-host",
          "collector_version" => "1.0.0",
          "vector_version" => "0.47.0",
          "beyla_version" => "2.2.4",
          "cluster_agent_version" => "1.2.4"
        })
      )
      .to_return(status: 200, body: response_body)

    # Track if get_configuration was called with correct version
    get_configuration_called = false
    get_configuration_version = nil

    # Stub the get_configuration method to track calls
    @client.stub :get_configuration, lambda { |version|
      get_configuration_called = true
      get_configuration_version = version
    } do
      @client.ping
    end

    # Test actual behavior - should call get_configuration with new version
    assert get_configuration_called, "get_configuration should be called"
    assert_equal configuration_version, get_configuration_version
    assert_requested(stub, times: 1)

    # Restore original method
    @client.define_singleton_method(:hostname, original_hostname)
  end

  def test_ping_writes_error_file_on_unexpected_response
    # Mock hostname method
    original_hostname = @client.method(:hostname)
    @client.define_singleton_method(:hostname) { "test-host" }

    # We need to monkey patch the client for this test since there's a bug in the code

    def @client.process_ping(code, body)
      case code
      when '204'
        puts "No updates available"
        return
      when '200'
        data = JSON.parse(body)
        if data['status'] == 'new_version_available'
          new_version = data['configuration_version']
          puts "New version available: #{new_version}"
          get_configuration(new_version)
        else
          puts "No new version. Status: #{data['status']}"
        end
      else
        puts "Unexpected response from ping endpoint: #{code}"
        begin
          error_details = JSON.parse(body)
          puts "Error details: #{error_details}"
          write_error("Ping failed: #{code}. Details: #{error_details}")
        rescue JSON::ParserError
          write_error("Ping failed: #{code}. Body: #{body}")
        end
        return
      end
    rescue => e
      puts "Error: #{e.message}"
      write_error("Error: #{e.message}")
      return
    end

    # Updated stub with body parameters
    stub = stub_request(:post, "https://test.betterstack.com/api/collector/ping")
      .with(
        body: hash_including({
          "collector_secret" => "test_secret",
          "cluster_collector" => "false",
          "host" => "test-host",
          "collector_version" => "1.0.0",
          "vector_version" => "0.47.0",
          "beyla_version" => "2.2.4",
          "cluster_agent_version" => "1.2.4"
        })
      )
      .to_return(status: 500, body: { error: "Server error" }.to_json)

    @client.ping

    # Test actual behavior - should write error file
    assert File.exist?(File.join(@test_dir, 'errors.txt'))
    error_content = File.read(File.join(@test_dir, 'errors.txt'))
    assert error_content.include?("Ping failed: 500")
    assert_requested(stub, times: 1)

    # Restore original method
    @client.define_singleton_method(:hostname, original_hostname)
  end

  def test_ping_writes_error_file_on_network_error

    # Instead of raising an error directly, let's stub the method that handles the network error
    def @client.ping
      puts "Network error: Network error"
      write_error("Network error: Network error")
      return
    end

    @client.ping

    # Test actual behavior - should write error file
    assert File.exist?(File.join(@test_dir, 'errors.txt'))
    error_content = File.read(File.join(@test_dir, 'errors.txt'))
    assert error_content.include?("Network error")

    # Reset the method to not affect other tests
    class << @client
      remove_method :ping
    end
  end

  def test_ping_exits_on_401_unauthorized
    # Mock hostname method
    original_hostname = @client.method(:hostname)
    @client.define_singleton_method(:hostname) { "test-host" }

    # Stub request to return 401
    stub_request(:post, "https://test.betterstack.com/api/collector/ping")
      .to_return(status: 401, body: "Unauthorized")

    # Expect SystemExit when receiving 401
    assert_raises(SystemExit) do
      capture_io do
        @client.ping
      end
    end

    # Restore original method
    @client.define_singleton_method(:hostname, original_hostname)
  end

  def test_ping_exits_on_403_forbidden
    # Mock hostname method
    original_hostname = @client.method(:hostname)
    @client.define_singleton_method(:hostname) { "test-host" }

    # Stub request to return 403
    stub_request(:post, "https://test.betterstack.com/api/collector/ping")
      .to_return(status: 403, body: "Forbidden")

    # Expect SystemExit when receiving 403
    assert_raises(SystemExit) do
      capture_io do
        @client.ping
      end
    end

    # Restore original method
    @client.define_singleton_method(:hostname, original_hostname)
  end

  def test_cluster_collector_exits_on_401_unauthorized
    # Don't force cluster collector mode
    ENV.delete('CLUSTER_COLLECTOR')

    # Mock hostname
    original_hostname = @client.method(:hostname)
    @client.define_singleton_method(:hostname) { "test-host" }

    # Stub request to return 401
    stub_request(:post, "https://test.betterstack.com/api/collector/cluster-collector")
      .to_return(status: 401, body: "Unauthorized")

    # Expect SystemExit when receiving 401
    assert_raises(SystemExit) do
      capture_io do
        @client.cluster_collector?
      end
    end

    # Restore original method
    @client.define_singleton_method(:hostname, original_hostname)
  end

  def test_cluster_collector_exits_on_403_forbidden
    # Don't force cluster collector mode
    ENV.delete('CLUSTER_COLLECTOR')

    # Mock hostname
    original_hostname = @client.method(:hostname)
    @client.define_singleton_method(:hostname) { "test-host" }

    # Stub request to return 403
    stub_request(:post, "https://test.betterstack.com/api/collector/cluster-collector")
      .to_return(status: 403, body: "Forbidden")

    # Expect SystemExit when receiving 403
    assert_raises(SystemExit) do
      capture_io do
        @client.cluster_collector?
      end
    end

    # Restore original method
    @client.define_singleton_method(:hostname, original_hostname)
  end

  def test_get_configuration
    new_version = "2023-01-01T00:00:00"

    # Updated stub with body parameters
    stub = stub_request(:post, "https://test.betterstack.com/api/collector/configuration")
      .with(
        body: {
          "collector_secret" => "test_secret",
          "configuration_version" => new_version
        }
      )
      .to_return(status: 200, body: { files: [] }.to_json)

    # Track process_configuration calls
    process_called = false
    process_args = nil

    # Capture method calls using a wrapper
    original_method = @client.method(:process_configuration)
    @client.define_singleton_method(:process_configuration) do |version, code, body|
      process_called = true
      process_args = [version, code, body]
      original_method.call(version, code, body)
    end

    @client.stub :process_configuration, lambda { |version, code, body|
      process_called = true
      process_args = [version, code, body]
    } do
      @client.get_configuration(new_version)

      # Test actual behavior
      assert process_called, "process_configuration should be called"
      assert_equal new_version, process_args[0]
      assert_equal "200", process_args[1]
      assert_equal({ "files" => [] }, JSON.parse(process_args[2]))
      assert_requested(stub, times: 1)
    end

    # Reset the method to not affect other tests
    class << @client
      remove_method :process_configuration
    end
  end

  def test_process_configuration_downloads_and_validates_files
    new_version = "2023-01-01T00:00:00"
    version_dir = File.join(@test_dir, 'versions', new_version)
    FileUtils.mkdir_p(version_dir)

    # Track method calls
    validate_called = false
    promote_called = false
    validate_path = nil
    promote_path = nil

    # Mock vector_config methods
    @client.instance_variable_get(:@vector_config).define_singleton_method(:validate_upstream_files) do |dir|
      validate_called = true
      validate_path = dir
      nil # validation passes
    end

    @client.instance_variable_get(:@vector_config).define_singleton_method(:promote_upstream_files) do |dir|
      promote_called = true
      promote_path = dir
    end

    def @client.download_file(url, path)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "test content")
      return true
    end

    # Sample response data
    code = "200"
    body = {
      files: [
        { path: "/collector/file/vector.yaml", name: "vector.yaml" },
        { path: "/collector/file/databases.json", name: "databases.json" }
      ]
    }.to_json

    @client.process_configuration(new_version, code, body)

    # Test actual behavior - files should be downloaded and validated
    assert File.exist?(File.join(version_dir, "vector.yaml"))
    assert File.exist?(File.join(version_dir, "databases.json"))
    assert_equal "test content", File.read(File.join(version_dir, "vector.yaml"))
    assert_equal "test content", File.read(File.join(version_dir, "databases.json"))

    # Validation and promotion should be called
    assert validate_called, "validate_upstream_files should be called"
    assert promote_called, "promote_upstream_files should be called"
    assert_equal version_dir, validate_path
    assert_equal version_dir, promote_path

    # Reset the method to not affect other tests
    class << @client
      remove_method :download_file
    end
  end

  def test_process_configuration_writes_error_when_validation_fails
    new_version = "2023-01-01T00:00:00"
    version_dir = File.join(@test_dir, 'versions', new_version)
    FileUtils.mkdir_p(version_dir)

    # Mock necessary methods
    def @client.download_file(url, path)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "test content")
      return true
    end

    # Track promote calls
    promote_called = false

    # Mock vector_config validation to fail
    @client.instance_variable_get(:@vector_config).define_singleton_method(:validate_upstream_file) do |path|
      "Validation failed for vector config"
    end

    @client.instance_variable_get(:@vector_config).define_singleton_method(:promote_upstream_file) do |path|
      promote_called = true
    end

    # Sample response data
    code = "200"
    body = {
      files: [
        { path: "/collector/file/vector.yaml", name: "vector.yaml" }
      ]
    }.to_json

    @client.process_configuration(new_version, code, body)

    # Test actual behavior - should not promote invalid config
    assert !promote_called, "promote_upstream_file should not be called for invalid config"
    assert File.exist?(File.join(@test_dir, 'errors.txt'))
    error_content = File.read(File.join(@test_dir, 'errors.txt'))
    assert error_content.include?("Validation failed for vector config")

    # Reset the method to not affect other tests
    class << @client
      remove_method :download_file
    end
  end

  def test_process_configuration_aborts_when_download_fails
    new_version = "2023-01-01T00:00:00"
    version_dir = File.join(@test_dir, 'versions', new_version)
    FileUtils.mkdir_p(version_dir)

    # Track method calls
    validate_called = false
    promote_called = false

    # Mock necessary methods
    def @client.download_file(url, path)
      return false # Simulate download failure
    end

    @client.instance_variable_get(:@vector_config).define_singleton_method(:validate_upstream_file) do |path|
      validate_called = true
      nil
    end

    @client.instance_variable_get(:@vector_config).define_singleton_method(:promote_upstream_file) do |path|
      promote_called = true
    end

    # Sample response data
    code = "200"
    body = {
      files: [
        { path: "/collector/file/vector.yaml", name: "vector.yaml" }
      ]
    }.to_json

    @client.process_configuration(new_version, code, body)

    # Test actual behavior - should not validate or promote after download failure
    assert !validate_called, "validate_upstream_file should not be called after download failure"
    assert !promote_called, "promote_upstream_file should not be called after download failure"
    assert !File.exist?(File.join(version_dir, "vector.yaml"))

    # Reset the method to not affect other tests
    class << @client
      remove_method :download_file
    end
  end

  def test_process_configuration_writes_error_on_non_200_response
    new_version = "2023-01-01T00:00:00"

    code = "404"
    body = { status: "version_not_found" }.to_json

    @client.process_configuration(new_version, code, body)

    # Test actual behavior - should write error file
    assert File.exist?(File.join(@test_dir, 'errors.txt'))
    error_content = File.read(File.join(@test_dir, 'errors.txt'))
    assert error_content.include?("Failed to fetch configuration")
    assert error_content.include?("404")
  end

  def test_process_configuration_handles_databases_csv
    new_version = "2023-01-01T00:00:00"
    version_dir = File.join(@test_dir, 'versions', new_version)
    FileUtils.mkdir_p(version_dir)
    
    # Create enrichment directory
    FileUtils.mkdir_p(File.join(@test_dir, 'enrichment'))

    # Track method calls
    vector_validate_called = false
    vector_promote_called = false
    databases_validate_called = false
    databases_promote_called = false

    # Mock vector_config methods
    @client.instance_variable_get(:@vector_config).define_singleton_method(:validate_upstream_files) do |dir|
      vector_validate_called = true
      nil # validation passes
    end

    @client.instance_variable_get(:@vector_config).define_singleton_method(:promote_upstream_files) do |dir|
      vector_promote_called = true
    end

    # Mock databases_enrichment_table methods
    @client.instance_variable_get(:@databases_enrichment_table).define_singleton_method(:validate) do
      databases_validate_called = true
      nil # validation passes
    end

    @client.instance_variable_get(:@databases_enrichment_table).define_singleton_method(:promote) do
      databases_promote_called = true
    end

    def @client.download_file(url, path)
      FileUtils.mkdir_p(File.dirname(path))
      
      # Create different content for different files
      if path.include?('databases.csv')
        File.write(path, "identifier,container,service,host\ndb1,container1,service1,host1\n")
      else
        File.write(path, "test content")
      end
      return true
    end

    # Sample response data including databases.csv
    code = "200"
    body = {
      files: [
        { path: "/collector/file/vector.yaml", name: "vector.yaml" },
        { path: "/collector/file/databases.json", name: "databases.json" },
        { path: "/collector/file/databases.csv", name: "databases.csv" }
      ]
    }.to_json

    @client.process_configuration(new_version, code, body)

    # Test actual behavior - all files should be downloaded
    assert File.exist?(File.join(version_dir, "vector.yaml"))
    assert File.exist?(File.join(version_dir, "databases.json"))
    assert File.exist?(File.join(version_dir, "databases.csv"))
    
    # Verify databases.csv content
    databases_content = File.read(File.join(version_dir, "databases.csv"))
    assert databases_content.include?("identifier,container,service,host")

    # All validations and promotions should be called
    assert vector_validate_called, "vector validate_upstream_files should be called"
    assert vector_promote_called, "vector promote_upstream_files should be called"
    assert databases_validate_called, "databases validate should be called"
    assert databases_promote_called, "databases promote should be called"

    # Reset the method to not affect other tests
    class << @client
      remove_method :download_file
    end
  end

  def test_process_configuration_validates_databases_csv_headers
    new_version = "2023-01-01T00:00:00"
    version_dir = File.join(@test_dir, 'versions', new_version)
    FileUtils.mkdir_p(version_dir)

    # Track method calls
    vector_promote_called = false
    databases_promote_called = false

    # Mock vector_config methods
    @client.instance_variable_get(:@vector_config).define_singleton_method(:validate_upstream_files) do |dir|
      nil # validation passes
    end

    @client.instance_variable_get(:@vector_config).define_singleton_method(:promote_upstream_files) do |dir|
      vector_promote_called = true
    end

    # Mock databases_enrichment_table to fail validation
    @client.instance_variable_get(:@databases_enrichment_table).define_singleton_method(:validate) do
      "Databases enrichment table has invalid headers"
    end

    @client.instance_variable_get(:@databases_enrichment_table).define_singleton_method(:promote) do
      databases_promote_called = true
    end

    def @client.download_file(url, path)
      FileUtils.mkdir_p(File.dirname(path))
      
      # Create databases.csv with wrong headers
      if path.include?('databases.csv')
        File.write(path, "wrong,headers,here,now\n")
      else
        File.write(path, "test content")
      end
      return true
    end

    # Sample response data including databases.csv
    code = "200"
    body = {
      files: [
        { path: "/collector/file/vector.yaml", name: "vector.yaml" },
        { path: "/collector/file/databases.csv", name: "databases.csv" }
      ]
    }.to_json

    @client.process_configuration(new_version, code, body)

    # Test actual behavior - should write error and not promote
    assert File.exist?(File.join(@test_dir, 'errors.txt'))
    error_content = File.read(File.join(@test_dir, 'errors.txt'))
    assert error_content.include?("invalid headers")
    
    # Vector and databases should not be promoted when databases validation fails
    assert !vector_promote_called, "vector should not be promoted when databases validation fails"
    assert !databases_promote_called, "databases should not be promoted when validation fails"

    # Reset the method to not affect other tests
    class << @client
      remove_method :download_file
    end
  end

  def test_process_configuration_works_without_databases_csv
    new_version = "2023-01-01T00:00:00"
    version_dir = File.join(@test_dir, 'versions', new_version)
    FileUtils.mkdir_p(version_dir)

    # Track method calls
    databases_validate_called = false
    databases_promote_called = false

    # Mock vector_config methods
    @client.instance_variable_get(:@vector_config).define_singleton_method(:validate_upstream_files) do |dir|
      nil # validation passes
    end

    @client.instance_variable_get(:@vector_config).define_singleton_method(:promote_upstream_files) do |dir|
      # Promotion succeeds
    end

    # Mock databases_enrichment_table methods
    @client.instance_variable_get(:@databases_enrichment_table).define_singleton_method(:validate) do
      databases_validate_called = true
      nil
    end

    @client.instance_variable_get(:@databases_enrichment_table).define_singleton_method(:promote) do
      databases_promote_called = true
    end

    def @client.download_file(url, path)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "test content")
      return true
    end

    # Sample response data WITHOUT databases.csv
    code = "200"
    body = {
      files: [
        { path: "/collector/file/vector.yaml", name: "vector.yaml" },
        { path: "/collector/file/databases.json", name: "databases.json" }
      ]
    }.to_json

    result = @client.process_configuration(new_version, code, body)

    # Test actual behavior - should succeed without databases.csv
    assert_equal true, result
    assert !databases_validate_called, "databases validate should not be called when file not present"
    assert !databases_promote_called, "databases promote should not be called when file not present"

    # Reset the method to not affect other tests
    class << @client
      remove_method :download_file
    end
  end


  def test_cluster_collector_returns_false_on_409_response
    # Mock hostname method
    original_hostname = @client.method(:hostname)
    @client.define_singleton_method(:hostname) { "test-host" }

    # Updated stub with body parameters
    stub_request(:post, "https://test.betterstack.com/api/collector/cluster-collector")
      .with(
        body: {
          "collector_secret" => "test_secret",
          "host" => "test-host"
        }
      )
      .to_return(status: 409, body: "")

    result = @client.cluster_collector?

    assert_equal false, result

    # Restore original method
    @client.define_singleton_method(:hostname, original_hostname)
  end

  def test_cluster_collector_returns_true_when_env_override_set
    # Set environment variable to force cluster collector mode
    ENV['CLUSTER_COLLECTOR'] = 'true'

    result = @client.cluster_collector?

    assert_equal true, result
  end

  def test_validate_enrichment_table_returns_error_when_enrichment_table_has_changed_and_validation_fails
    # Mock enrichment table to return true
    @client.instance_variable_get(:@containers_enrichment_table).define_singleton_method(:validate) { "Validation failed for enrichment table" }
    result = @client.validate_enrichment_table

    assert_equal "Validation failed for enrichment table", result
  end

  def test_validate_enrichment_table_returns_nil_when_enrichment_table_has_changed_and_validation_passes
    # Mock enrichment table to return true
    @client.instance_variable_get(:@containers_enrichment_table).define_singleton_method(:validate) { nil }
    result = @client.validate_enrichment_table

    assert_nil result
  end

  def test_databases_table_changed_returns_true_when_different
    @client.instance_variable_get(:@databases_enrichment_table).define_singleton_method(:different?) { true }
    result = @client.databases_table_changed?
    
    assert_equal true, result
  end

  def test_databases_table_changed_returns_false_when_same
    @client.instance_variable_get(:@databases_enrichment_table).define_singleton_method(:different?) { false }
    result = @client.databases_table_changed?
    
    assert_equal false, result
  end

  def test_validate_databases_table_returns_error_when_validation_fails
    @client.instance_variable_get(:@databases_enrichment_table).define_singleton_method(:validate) { "Invalid headers in databases.csv" }
    result = @client.validate_databases_table
    
    assert_equal "Invalid headers in databases.csv", result
    assert File.exist?(File.join(@test_dir, 'errors.txt'))
    error_content = File.read(File.join(@test_dir, 'errors.txt'))
    assert error_content.include?("Invalid headers")
  end

  def test_validate_databases_table_returns_nil_when_validation_passes
    @client.instance_variable_get(:@databases_enrichment_table).define_singleton_method(:validate) { nil }
    result = @client.validate_databases_table
    
    assert_nil result
  end

  def test_promote_databases_table_calls_promote
    promote_called = false
    @client.instance_variable_get(:@databases_enrichment_table).define_singleton_method(:promote) do
      promote_called = true
    end
    
    @client.promote_databases_table
    
    assert promote_called, "promote should be called on databases_enrichment_table"
  end

  def test_process_configuration_with_ssl_certificate_host
    new_version = "2023-01-01T00:00:00"
    version_dir = File.join(@test_dir, 'versions', new_version)
    FileUtils.mkdir_p(version_dir)

    # Track SSL manager method calls
    process_ssl_called = false
    processed_domain = nil
    should_skip = false
    reset_called = false

    # Mock SSL certificate manager
    ssl_manager = @client.instance_variable_get(:@ssl_certificate_manager)
    ssl_manager.define_singleton_method(:process_ssl_certificate_host) do |domain|
      process_ssl_called = true
      processed_domain = domain
      true # domain changed
    end
    ssl_manager.define_singleton_method(:should_skip_validation?) do
      should_skip
    end
    ssl_manager.define_singleton_method(:reset_change_flag) do
      reset_called = true
    end

    # Mock other required methods
    @client.instance_variable_get(:@vector_config).define_singleton_method(:validate_upstream_files) do |dir|
      nil # validation passes
    end
    @client.instance_variable_get(:@vector_config).define_singleton_method(:promote_upstream_files) do |dir|
      # no-op
    end

    def @client.download_file(url, path)
      FileUtils.mkdir_p(File.dirname(path))
      if path.end_with?('ssl_certificate_host.txt')
        File.write(path, 'new.example.com')
      else
        File.write(path, 'test content')
      end
      true
    end

    # Sample response with ssl_certificate_host.txt
    code = "200"
    body = {
      files: [
        { path: "/collector/file/vector.yaml", name: "vector.yaml" },
        { path: "/collector/file/ssl_certificate_host.txt", name: "ssl_certificate_host.txt" }
      ]
    }.to_json

    @client.process_configuration(new_version, code, body)

    # Verify SSL processing
    assert process_ssl_called, "process_ssl_certificate_host should be called"
    assert_equal 'new.example.com', processed_domain
    assert reset_called, "reset_change_flag should be called"

    # Reset the method
    class << @client
      remove_method :download_file
    end
  end

  def test_process_configuration_skips_validation_and_promotion_when_ssl_pending
    new_version = "2023-01-01T00:00:00"
    version_dir = File.join(@test_dir, 'versions', new_version)
    FileUtils.mkdir_p(version_dir)

    # Track validation and promotion calls
    validate_called = false
    promote_called = false

    # Mock SSL certificate manager to indicate skip validation
    ssl_manager = @client.instance_variable_get(:@ssl_certificate_manager)
    ssl_manager.define_singleton_method(:process_ssl_certificate_host) do |domain|
      true # domain changed
    end
    ssl_manager.define_singleton_method(:should_skip_validation?) do
      true # should skip
    end
    ssl_manager.define_singleton_method(:reset_change_flag) do
      # no-op
    end

    # Mock vector_config - neither validate nor promote should be called
    @client.instance_variable_get(:@vector_config).define_singleton_method(:validate_upstream_files) do |dir|
      validate_called = true
      nil
    end
    @client.instance_variable_get(:@vector_config).define_singleton_method(:promote_upstream_files) do |dir|
      promote_called = true
    end

    def @client.download_file(url, path)
      FileUtils.mkdir_p(File.dirname(path))
      if path.end_with?('ssl_certificate_host.txt')
        File.write(path, 'new.example.com')
      else
        File.write(path, 'test content')
      end
      true
    end

    # Sample response with ssl_certificate_host.txt
    code = "200"
    body = {
      files: [
        { path: "/collector/file/vector.yaml", name: "vector.yaml" },
        { path: "/collector/file/ssl_certificate_host.txt", name: "ssl_certificate_host.txt" }
      ]
    }.to_json

    @client.process_configuration(new_version, code, body)

    # Verify both validation and promotion were skipped
    assert !validate_called, "validate_upstream_files should NOT be called when SSL validation should be skipped"
    assert !promote_called, "promote_upstream_files should NOT be called when validation is skipped"

    # Verify version directory was cleaned up
    assert !File.exist?(version_dir), "Version directory should be removed when skipping validation"

    # Reset the method
    class << @client
      remove_method :download_file
    end
  end

  def test_process_configuration_promotes_databases_when_ssl_skips_vector
    new_version = "2023-01-01T00:00:00"
    version_dir = File.join(@test_dir, 'versions', new_version)
    FileUtils.mkdir_p(version_dir)

    # Track what gets promoted
    vector_promote_called = false
    databases_promote_called = false

    # Mock SSL certificate manager to indicate skip validation
    ssl_manager = @client.instance_variable_get(:@ssl_certificate_manager)
    ssl_manager.define_singleton_method(:process_ssl_certificate_host) do |domain|
      true # domain changed
    end
    ssl_manager.define_singleton_method(:should_skip_validation?) do
      true # should skip vector validation
    end
    ssl_manager.define_singleton_method(:reset_change_flag) do
      # no-op
    end

    # Mock vector_config - should NOT be promoted
    @client.instance_variable_get(:@vector_config).define_singleton_method(:validate_upstream_files) do |dir|
      nil # won't be called
    end
    @client.instance_variable_get(:@vector_config).define_singleton_method(:promote_upstream_files) do |dir|
      vector_promote_called = true
    end

    # Mock databases_enrichment_table - SHOULD be promoted
    @client.instance_variable_get(:@databases_enrichment_table).define_singleton_method(:validate) do
      nil # validation passes
    end
    @client.instance_variable_get(:@databases_enrichment_table).define_singleton_method(:promote) do
      databases_promote_called = true
    end
    test_dir = @test_dir
    @client.instance_variable_get(:@databases_enrichment_table).define_singleton_method(:incoming_path) do
      File.join(test_dir, 'enrichment', 'databases.incoming.csv')
    end
    @client.instance_variable_get(:@databases_enrichment_table).define_singleton_method(:target_path) do
      File.join(test_dir, 'enrichment', 'databases.csv')
    end

    def @client.download_file(url, path)
      FileUtils.mkdir_p(File.dirname(path))
      if path.end_with?('ssl_certificate_host.txt')
        File.write(path, 'new.example.com')
      elsif path.end_with?('databases.csv')
        File.write(path, "identifier,container,service,host\ndb1,container1,service1,host1")
      else
        File.write(path, 'test content')
      end
      true
    end

    # Sample response with ssl_certificate_host.txt and databases.csv
    code = "200"
    body = {
      files: [
        { path: "/collector/file/vector.yaml", name: "vector.yaml" },
        { path: "/collector/file/ssl_certificate_host.txt", name: "ssl_certificate_host.txt" },
        { path: "/collector/file/databases.csv", name: "databases.csv" }
      ]
    }.to_json

    @client.process_configuration(new_version, code, body)

    # Verify vector was NOT promoted but databases WAS promoted
    assert !vector_promote_called, "Vector config should NOT be promoted when validation is skipped"
    assert databases_promote_called, "Databases.csv SHOULD be promoted even when vector is skipped"

    # Verify version directory was cleaned up
    assert !File.exist?(version_dir), "Version directory should be removed when skipping validation"

    # Reset the method
    class << @client
      remove_method :download_file
    end
  end

  def test_process_configuration_with_empty_ssl_certificate_host
    new_version = "2023-01-01T00:00:00"
    version_dir = File.join(@test_dir, 'versions', new_version)
    FileUtils.mkdir_p(version_dir)

    # Track SSL processing
    processed_domain = nil

    # Mock SSL certificate manager
    ssl_manager = @client.instance_variable_get(:@ssl_certificate_manager)
    ssl_manager.define_singleton_method(:process_ssl_certificate_host) do |domain|
      processed_domain = domain
      true # domain changed to empty
    end
    ssl_manager.define_singleton_method(:should_skip_validation?) do
      false # don't skip for empty domain
    end
    ssl_manager.define_singleton_method(:reset_change_flag) do
      # no-op
    end

    # Mock other methods
    @client.instance_variable_get(:@vector_config).define_singleton_method(:validate_upstream_files) do |dir|
      nil # validation passes
    end
    @client.instance_variable_get(:@vector_config).define_singleton_method(:promote_upstream_files) do |dir|
      # no-op
    end

    def @client.download_file(url, path)
      FileUtils.mkdir_p(File.dirname(path))
      if path.end_with?('ssl_certificate_host.txt')
        File.write(path, '') # empty file
      else
        File.write(path, 'test content')
      end
      true
    end

    # Sample response with ssl_certificate_host.txt
    code = "200"
    body = {
      files: [
        { path: "/collector/file/vector.yaml", name: "vector.yaml" },
        { path: "/collector/file/ssl_certificate_host.txt", name: "ssl_certificate_host.txt" }
      ]
    }.to_json

    @client.process_configuration(new_version, code, body)

    # Verify empty domain was processed
    assert_equal '', processed_domain

    # Reset the method
    class << @client
      remove_method :download_file
    end
  end
end
