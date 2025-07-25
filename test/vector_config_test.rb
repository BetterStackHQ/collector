require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require_relative '../engine/vector_config'

class VectorConfigTest < Minitest::Test
  def setup
    @test_dir = Dir.mktmpdir
    @vector_config = VectorConfig.new(@test_dir)
    @vector_config_dir = File.join(@test_dir, 'vector-config')
    
    # Create test directories
    FileUtils.mkdir_p(File.join(@test_dir, 'versions', '0-default'))
    FileUtils.mkdir_p(File.join(@test_dir, 'kubernetes-discovery', '0-default'))
    FileUtils.mkdir_p(File.join(@test_dir, 'kubernetes-discovery', '2025-01-01T00:00:00'))
    
    # Create test files
    File.write(File.join(@test_dir, 'versions', '0-default', 'vector.yaml'), "test: config")
    File.write(File.join(@test_dir, 'kubernetes-discovery', '0-default', 'dummy.yaml'), "sources: {}")
    File.write(File.join(@test_dir, 'kubernetes-discovery', '2025-01-01T00:00:00', 'test.yaml'), "sources: {}")
  end

  def teardown
    FileUtils.rm_rf(@test_dir)
  end

  def test_validate_upstream_file_with_command_directive
    vector_yaml_path = File.join(@test_dir, 'test.yaml')
    File.write(vector_yaml_path, "sources:\n  test:\n    type: exec\n    command: ['echo', 'test']")
    
    result = @vector_config.validate_upstream_file(vector_yaml_path)
    assert_equal 'vector.yaml must not contain command: directives', result
  end

  def test_validate_upstream_file_success
    vector_yaml_path = File.join(@test_dir, 'test.yaml')
    File.write(vector_yaml_path, "sources:\n  test:\n    type: file\n    include: ['/test']")
    
    # Mock successful vector validation
    @vector_config.stub :`, lambda { |cmd| 
      $?.instance_variable_set(:@success, true)
      $?.define_singleton_method(:success?) { @success }
      "Configuration validated successfully"
    } do
      result = @vector_config.validate_upstream_file(vector_yaml_path)
      assert_nil result
    end
  end

  def test_validate_upstream_file_failure
    vector_yaml_path = File.join(@test_dir, 'test.yaml')
    File.write(vector_yaml_path, "sources:\n  test:\n    type: file")
    
    # Mock failed vector validation
    @vector_config.stub :`, lambda { |cmd|
      $?.instance_variable_set(:@success, false)
      $?.define_singleton_method(:success?) { @success }
      "Error: Missing required field 'include'"
    } do
      result = @vector_config.validate_upstream_file(vector_yaml_path)
      assert_match(/Error: Missing required field/, result)
    end
  end

  def test_promote_upstream_file
    vector_yaml_path = File.join(@test_dir, 'test.yaml')
    File.write(vector_yaml_path, "test: config")
    
    output = capture_io do
      @vector_config.promote_upstream_file(vector_yaml_path)
    end
    
    assert File.symlink?(File.join(@test_dir, 'latest-valid-vector.yaml'))
    assert_equal vector_yaml_path, File.readlink(File.join(@test_dir, 'latest-valid-vector.yaml'))
    assert_match(/Updated latest-valid-vector.yaml symlink/, output.join)
  end

  def test_prepare_dir_no_latest_valid_vector
    output = capture_io do
      result = @vector_config.prepare_dir
      assert_nil result
    end
    
    assert_match(/Error: No latest-valid-vector.yaml found/, output.join)
  end

  def test_prepare_dir_with_kubernetes_discovery_usage
    # Create latest-valid-vector.yaml with kubernetes_discovery_ reference
    vector_content = "sources:\n  kubernetes_discovery_test:\n    type: prometheus_scrape"
    vector_path = File.join(@test_dir, 'test.yaml')
    File.write(vector_path, vector_content)
    FileUtils.ln_s(vector_path, File.join(@test_dir, 'latest-valid-vector.yaml'))
    
    # Mock latest_kubernetes_discovery
    @vector_config.stub :latest_kubernetes_discovery, File.join(@test_dir, 'kubernetes-discovery', '2025-01-01T00:00:00') do
      output = capture_io do
        result = @vector_config.prepare_dir
        assert result
        assert result.start_with?(File.join(@vector_config_dir, 'new_'))
        
        # Check symlinks created
        assert File.symlink?(File.join(result, 'vector.yaml'))
        assert File.symlink?(File.join(result, 'kubernetes-discovery'))
        
        # Should use latest kubernetes discovery
        assert_equal File.join(@test_dir, 'kubernetes-discovery', '2025-01-01T00:00:00'),
                     File.readlink(File.join(result, 'kubernetes-discovery'))
      end
      
      assert_match(/Prepared vector-config directory/, output.join)
    end
  end

  def test_prepare_dir_without_kubernetes_discovery_usage
    # Create latest-valid-vector.yaml without kubernetes_discovery_ reference
    vector_content = "sources:\n  test:\n    type: file"
    vector_path = File.join(@test_dir, 'test.yaml')
    File.write(vector_path, vector_content)
    FileUtils.ln_s(vector_path, File.join(@test_dir, 'latest-valid-vector.yaml'))
    
    output = capture_io do
      result = @vector_config.prepare_dir
      assert result
      
      # Should use 0-default kubernetes discovery
      assert_equal File.join(@test_dir, 'kubernetes-discovery', '0-default'),
                   File.readlink(File.join(result, 'kubernetes-discovery'))
    end
  end

  def test_validate_dir_success
    config_dir = File.join(@test_dir, 'test-config')
    FileUtils.mkdir_p(config_dir)
    File.write(File.join(config_dir, 'vector.yaml'), "test: config")
    FileUtils.mkdir_p(File.join(config_dir, 'kubernetes-discovery'))
    
    # Mock successful vector validation
    @vector_config.stub :`, lambda { |cmd|
      $?.instance_variable_set(:@success, true)
      $?.define_singleton_method(:success?) { @success }
      "Configuration validated successfully"
    } do
      output = capture_io do
        result = @vector_config.validate_dir(config_dir)
        assert_nil result
      end
      
      assert_match(/Validating vector config directory/, output.join)
    end
  end

  def test_validate_dir_failure
    config_dir = File.join(@test_dir, 'test-config')
    FileUtils.mkdir_p(config_dir)
    
    # Mock failed vector validation
    @vector_config.stub :`, lambda { |cmd|
      $?.instance_variable_set(:@success, false)
      $?.define_singleton_method(:success?) { @success }
      "Error: Invalid configuration"
    } do
      result = @vector_config.validate_dir(config_dir)
      assert_equal "Error: Invalid configuration", result
    end
  end

  def test_promote_dir
    config_dir = File.join(@vector_config_dir, 'new_test')
    FileUtils.mkdir_p(config_dir)
    
    # Create old current directory
    old_current = File.join(@vector_config_dir, 'current')
    FileUtils.mkdir_p(old_current)
    
    # Mock system call for supervisorctl
    @vector_config.stub :system, true do
      output = capture_io do
        @vector_config.promote_dir(config_dir)
      end
      
      assert File.directory?(File.join(@vector_config_dir, 'current'))
      assert !File.directory?(old_current)
      assert_match(/Promoting.*to \/vector-config\/current/, output.join)
      assert_match(/Reloading vector/, output.join)
      assert_match(/Successfully promoted to current/, output.join)
    end
  end
end