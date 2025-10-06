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

  def test_validate_upstream_files_should_reject_malicious_command_variations
    # Test various ways someone might try to sneak in command directives
    test_cases = [
      "sources:\n  test:\n    command: 'rm -rf /'",
      "sources:\n  test:\n    type: exec\n    command: ['echo', 'test']",
      "sources:\n  test:\n    type: exec\n    # command: 'commented'\n    command: 'real'",
      "transforms:\n  test:\n    type: exec\n    command: 'transform command'"
    ]

    test_cases.each do |content|
      version_dir = File.join(@test_dir, 'test-version')
      FileUtils.mkdir_p(version_dir)
      File.write(File.join(version_dir, 'vector.yaml'), content)

      result = @vector_config.validate_upstream_files(version_dir)
      assert_equal 'vector.yaml must not contain command: directives', result,
                   "Should reject config with content: #{content}"
    end
  end

  def test_prepare_dir_should_work_with_missing_kubernetes_discovery
    # Create latest-valid-upstream with kubernetes_discovery reference
    upstream_dir = File.join(@test_dir, 'vector-config', 'latest-valid-upstream')
    FileUtils.mkdir_p(upstream_dir)
    vector_content = "sources:\n  kubernetes_discovery_test:\n    type: prometheus_scrape"
    File.write(File.join(upstream_dir, 'vector.yaml'), vector_content)

    # Remove kubernetes-discovery directories
    FileUtils.rm_rf(File.join(@test_dir, 'kubernetes-discovery'))

    # Mock latest_kubernetes_discovery to return nil
    @vector_config.stub :latest_kubernetes_discovery, nil do
      result = @vector_config.prepare_dir
      assert result

      # Should still create the directory structure
      assert File.exist?(File.join(result, 'vector.yaml'))
      assert !File.symlink?(File.join(result, 'vector.yaml'))
      # kubernetes-discovery symlink should not exist if source doesn't exist
      assert !File.exist?(File.join(result, 'kubernetes-discovery'))
    end
  end

  def test_validate_dir_should_handle_permission_errors
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

  def test_promote_dir_should_handle_current_as_file_not_directory
    config_dir = File.join(@vector_config_dir, 'new_test')
    FileUtils.mkdir_p(config_dir)

    # Create current as a file instead of directory
    current_path = File.join(@vector_config_dir, 'current')
    FileUtils.mkdir_p(@vector_config_dir)
    File.write(current_path, "I'm a file, not a directory!")

    # Should handle gracefully
    @vector_config.stub :system, true do
      result = nil
      output = capture_io do
        result = @vector_config.promote_dir(config_dir)
      end

      assert File.directory?(File.join(@vector_config_dir, 'current'))
      assert_match(/Promoting/, output.join)
      assert result
    end
  end

  def test_promote_dir_should_handle_supervisorctl_failure
    config_dir = File.join(@vector_config_dir, 'new_test')
    FileUtils.mkdir_p(config_dir)

    # Mock system call to return false (failure)
    @vector_config.stub :system, false do
      result = nil
      output = capture_io do
        # Should not raise error, just continue
        result = @vector_config.promote_dir(config_dir)
      end

      assert File.directory?(File.join(@vector_config_dir, 'current'))
      assert_match(/Promoting/, output.join)
      assert result
    end
  end

  def test_validate_upstream_files_should_work_with_just_vector_yaml
    # Create test directory with just vector.yaml
    upstream_dir = File.join(@test_dir, 'upstream')
    FileUtils.mkdir_p(upstream_dir)

    # Write only vector.yaml (valid config)
    valid_config = <<~YAML
      sources:
        test_source:
          type: file
          include: ["/var/log/test.log"]
    YAML
    File.write(File.join(upstream_dir, 'vector.yaml'), valid_config)

    # Mock successful vector validation
    original_backtick = @vector_config.method(:`)
    @vector_config.define_singleton_method(:`) do |cmd|
      original_backtick.call('true')
      "Configuration validated successfully"
    end

    # Should validate successfully with just vector.yaml
    result = @vector_config.validate_upstream_files(upstream_dir)
    assert_nil result, "Should validate successfully with just vector.yaml"
  end

  def test_validate_upstream_files_should_work_with_just_manual_vector_yaml
    # Create test directory with just manual.vector.yaml
    upstream_dir = File.join(@test_dir, 'upstream')
    FileUtils.mkdir_p(upstream_dir)

    # Write only manual.vector.yaml (valid config)
    valid_manual_config = <<~YAML
      transforms:
        test_transform:
          type: remap
          inputs: ["test_source"]
          source: '.message = "test"'
    YAML
    File.write(File.join(upstream_dir, 'manual.vector.yaml'), valid_manual_config)

    # Mock successful vector validation
    original_backtick = @vector_config.method(:`)
    @vector_config.define_singleton_method(:`) do |cmd|
      original_backtick.call('true')
      "Configuration validated successfully"
    end

    # Should validate successfully with just manual.vector.yaml
    result = @vector_config.validate_upstream_files(upstream_dir)
    assert_nil result, "Should validate successfully with just manual.vector.yaml"
  end

  def test_validate_upstream_files_should_fail_with_no_vector_configs
    # Create test directory with no vector configs
    upstream_dir = File.join(@test_dir, 'upstream')
    FileUtils.mkdir_p(upstream_dir)

    # Should fail validation when no vector configs are present
    result = @vector_config.validate_upstream_files(upstream_dir)
    assert_match(/No vector.yaml, manual.vector.yaml, or process_discovery.vector.yaml found/, result, "Should fail validation with no vector configs")
  end
end