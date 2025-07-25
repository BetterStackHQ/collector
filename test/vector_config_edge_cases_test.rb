require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require_relative '../engine/vector_config'

class VectorConfigEdgeCasesTest < Minitest::Test
  def setup
    @test_dir = Dir.mktmpdir
    @vector_config = VectorConfig.new(@test_dir)
    @vector_config_dir = File.join(@test_dir, 'vector-config')
  end

  def teardown
    FileUtils.rm_rf(@test_dir)
  end

  def test_validate_upstream_file_with_malicious_command_variations
    # Test various ways someone might try to sneak in command directives
    test_cases = [
      "sources:\n  test:\n    command: 'rm -rf /'",
      "sources:\n  test:\n    type: exec\n    command : ['echo', 'test']",
      "sources:\n  test:\n    type: exec\n    COMMAND: 'uppercase'",
      "sources:\n  test:\n    type: exec\n    # command: 'commented'\n    command: 'real'",
      "transforms:\n  test:\n    type: exec\n    command: 'transform command'"
    ]
    
    test_cases.each do |content|
      vector_yaml_path = File.join(@test_dir, 'test.yaml')
      File.write(vector_yaml_path, content)
      
      result = @vector_config.validate_upstream_file(vector_yaml_path)
      assert_equal 'vector.yaml must not contain command: directives', result,
                   "Should reject config with content: #{content}"
    end
  end

  def test_prepare_dir_with_symlink_loops
    # Create a symlink loop
    vector_path = File.join(@test_dir, 'test.yaml')
    File.write(vector_path, "sources:\n  test:\n    type: file")
    
    loop_link = File.join(@test_dir, 'loop.yaml')
    FileUtils.ln_s(loop_link, loop_link) rescue nil # This will fail but that's ok
    FileUtils.ln_s(vector_path, File.join(@test_dir, 'latest-valid-vector.yaml'))
    
    # Should handle gracefully
    output = capture_io do
      result = @vector_config.prepare_dir
      assert result
    end
    
    assert_match(/Prepared vector-config directory/, output.join)
  end

  def test_prepare_dir_with_missing_kubernetes_discovery
    # Create latest-valid-vector.yaml with kubernetes_discovery reference
    vector_content = "sources:\n  kubernetes_discovery_test:\n    type: prometheus_scrape"
    vector_path = File.join(@test_dir, 'test.yaml')
    File.write(vector_path, vector_content)
    FileUtils.ln_s(vector_path, File.join(@test_dir, 'latest-valid-vector.yaml'))
    
    # Remove kubernetes-discovery directories
    FileUtils.rm_rf(File.join(@test_dir, 'kubernetes-discovery'))
    
    # Mock latest_kubernetes_discovery to return nil
    @vector_config.stub :latest_kubernetes_discovery, nil do
      output = capture_io do
        result = @vector_config.prepare_dir
        assert result
        
        # Should still create the directory structure
        assert File.symlink?(File.join(result, 'vector.yaml'))
        # kubernetes-discovery symlink should not exist if source doesn't exist
        assert !File.exist?(File.join(result, 'kubernetes-discovery'))
      end
    end
  end

  def test_validate_dir_with_permission_errors
    config_dir = File.join(@test_dir, 'test-config')
    FileUtils.mkdir_p(config_dir)
    File.write(File.join(config_dir, 'vector.yaml'), "test: config")
    FileUtils.mkdir_p(File.join(config_dir, 'kubernetes-discovery'))
    
    # Mock vector command to simulate permission error
    @vector_config.stub :`, lambda { |cmd|
      raise Errno::EACCES, "Permission denied"
    } do
      assert_raises(Errno::EACCES) do
        @vector_config.validate_dir(config_dir)
      end
    end
  end

  def test_promote_dir_with_current_as_file_not_directory
    config_dir = File.join(@vector_config_dir, 'new_test')
    FileUtils.mkdir_p(config_dir)
    
    # Create current as a file instead of directory
    current_path = File.join(@vector_config_dir, 'current')
    FileUtils.mkdir_p(@vector_config_dir)
    File.write(current_path, "I'm a file, not a directory!")
    
    # Should handle gracefully
    @vector_config.stub :system, true do
      output = capture_io do
        @vector_config.promote_dir(config_dir)
      end
      
      assert File.directory?(File.join(@vector_config_dir, 'current'))
      assert_match(/Successfully promoted to current/, output.join)
    end
  end

  def test_promote_dir_when_supervisorctl_fails
    config_dir = File.join(@vector_config_dir, 'new_test')
    FileUtils.mkdir_p(config_dir)
    
    # Mock system call to return false (failure)
    @vector_config.stub :system, false do
      output = capture_io do
        # Should not raise error, just continue
        @vector_config.promote_dir(config_dir)
      end
      
      assert File.directory?(File.join(@vector_config_dir, 'current'))
      assert_match(/Reloading vector/, output.join)
      assert_match(/Successfully promoted to current/, output.join)
    end
  end

  def test_prepare_dir_with_race_condition
    # Simulate another process creating directories at the same time
    vector_path = File.join(@test_dir, 'test.yaml')
    File.write(vector_path, "sources:\n  test:\n    type: file")
    FileUtils.ln_s(vector_path, File.join(@test_dir, 'latest-valid-vector.yaml'))
    
    call_count = 0
    original_mkdir_p = FileUtils.method(:mkdir_p)
    
    # Mock mkdir_p to simulate race condition on first call
    FileUtils.stub :mkdir_p, lambda { |path|
      call_count += 1
      if call_count == 1 && path.include?('new_')
        # Simulate another process creating the directory
        original_mkdir_p.call(path)
        raise Errno::EEXIST, "Directory already exists"
      else
        original_mkdir_p.call(path)
      end
    } do
      output = capture_io do
        result = @vector_config.prepare_dir
        # Should recover and still work
        assert_nil result
      end
      
      assert_match(/Error preparing vector-config directory/, output.join)
    end
  end

  def test_validate_upstream_file_with_very_large_config
    # Create a very large but valid config
    vector_yaml_path = File.join(@test_dir, 'test.yaml')
    
    sources = {}
    1000.times do |i|
      sources["source_#{i}"] = {
        'type' => 'file',
        'include' => ["/tmp/test_#{i}.log"]
      }
    end
    
    require 'yaml'
    File.write(vector_yaml_path, { 'sources' => sources }.to_yaml)
    
    # Mock successful validation
    @vector_config.stub :`, lambda { |cmd|
      $?.instance_variable_set(:@success, true)
      $?.define_singleton_method(:success?) { @success }
      "Configuration validated successfully"
    } do
      result = @vector_config.validate_upstream_file(vector_yaml_path)
      assert_nil result
    end
  end

  def test_concurrent_prepare_dir_calls
    # Test what happens when prepare_dir is called multiple times concurrently
    vector_path = File.join(@test_dir, 'test.yaml')
    File.write(vector_path, "sources:\n  test:\n    type: file")
    FileUtils.ln_s(vector_path, File.join(@test_dir, 'latest-valid-vector.yaml'))
    
    results = []
    threads = []
    
    5.times do
      threads << Thread.new do
        output = capture_io do
          result = @vector_config.prepare_dir
          results << result
        end
      end
    end
    
    threads.each(&:join)
    
    # All should succeed and create different directories
    successful_results = results.compact
    assert successful_results.length > 0
    assert_equal successful_results.length, successful_results.uniq.length, 
                 "Each call should create a unique directory"
  end
end