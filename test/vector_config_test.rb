require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require 'open3'
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

  def test_validate_upstream_files_rejects_command_directive_in_vector_yaml
    version_dir = File.join(@test_dir, 'versions', '2025-01-01T00:00:00')
    FileUtils.mkdir_p(version_dir)
    File.write(File.join(version_dir, 'vector.yaml'), "sources:\n  test:\n    type: exec\n    command: ['echo', 'test']")

    result = @vector_config.validate_upstream_files(version_dir)
    assert_equal 'vector.yaml must not contain command: directives', result
  end

  def test_validate_upstream_files_returns_nil_on_success
    version_dir = File.join(@test_dir, 'versions', '2025-01-01T00:00:00')
    FileUtils.mkdir_p(version_dir)
    File.write(File.join(version_dir, 'vector.yaml'), "sources:\n  test:\n    type: file\n    include: ['/test']")

    # Mock successful vector validation
    original_backtick = @vector_config.method(:`)
    @vector_config.define_singleton_method(:`) do |cmd|
      # Run a command that succeeds to set $?.success? to true
      original_backtick.call('true')
      "Configuration validated successfully"
    end

    result = @vector_config.validate_upstream_files(version_dir)
    assert_nil result
  end

  def test_validate_upstream_files_returns_error_on_validation_failure
    version_dir = File.join(@test_dir, 'versions', '2025-01-01T00:00:00')
    FileUtils.mkdir_p(version_dir)
    File.write(File.join(version_dir, 'vector.yaml'), "sources:\n  test:\n    type: file")

    # Mock failed vector validation by actually running a command that fails
    original_backtick = @vector_config.method(:`)
    @vector_config.define_singleton_method(:`) do |cmd|
      # Run a command that will fail
      original_backtick.call('false')
      "Error: Missing required field 'include'"
    end

    result = @vector_config.validate_upstream_files(version_dir)
    assert_match(/Error: Missing required field/, result)
  end

  def test_promote_upstream_files
    # Create a version directory with vector.yaml and manual.vector.yaml
    version_dir = File.join(@test_dir, 'versions', '2025-01-01T00:00:00')
    FileUtils.mkdir_p(version_dir)
    File.write(File.join(version_dir, 'vector.yaml'), "sources:\n  test:\n    type: file")
    File.write(File.join(version_dir, 'manual.vector.yaml'), "sources:\n  manual:\n    type: file")

    @vector_config.promote_upstream_files(version_dir)

    # Test the actual outcome - files copied to latest-valid-upstream
    upstream_dir = File.join(@test_dir, 'vector-config', 'latest-valid-upstream')
    assert File.exist?(File.join(upstream_dir, 'vector.yaml'))
    assert File.exist?(File.join(upstream_dir, 'manual.vector.yaml'))
    assert_equal "sources:\n  test:\n    type: file", File.read(File.join(upstream_dir, 'vector.yaml'))
    assert_equal "sources:\n  manual:\n    type: file", File.read(File.join(upstream_dir, 'manual.vector.yaml'))
  end

  def test_prepare_dir_returns_nil_when_no_latest_valid_upstream
    # Test that prepare_dir returns nil when no latest-valid-upstream exists
    assert !File.exist?(File.join(@test_dir, 'vector-config', 'latest-valid-upstream'))
    result = @vector_config.prepare_dir
    assert_nil result
  end

  def test_prepare_dir_uses_latest_kubernetes_discovery_when_referenced
    # Create latest-valid-upstream with vector.yaml containing kubernetes_discovery_ reference
    upstream_dir = File.join(@test_dir, 'vector-config', 'latest-valid-upstream')
    FileUtils.mkdir_p(upstream_dir)
    vector_content = "sources:\n  kubernetes_discovery_test:\n    type: prometheus_scrape"
    File.write(File.join(upstream_dir, 'vector.yaml'), vector_content)

    # Create a kubernetes discovery directory
    k8s_discovery_dir = File.join(@test_dir, 'kubernetes-discovery', '2025-01-01T00:00:00')
    FileUtils.mkdir_p(k8s_discovery_dir)

    # Mock latest_kubernetes_discovery
    @vector_config.stub :latest_kubernetes_discovery, k8s_discovery_dir do
      result = @vector_config.prepare_dir

      # Test actual outcomes
      assert result, "prepare_dir should return a directory path"
      assert result.start_with?(File.join(@vector_config_dir, 'new_'))
      assert File.directory?(result)

      # Check files are correctly created
      assert File.exist?(File.join(result, 'vector.yaml'))
      assert File.symlink?(File.join(result, 'kubernetes-discovery'))

      # Verify it uses the latest kubernetes discovery
      assert_equal k8s_discovery_dir,
                   File.readlink(File.join(result, 'kubernetes-discovery'))
      # Verify vector.yaml content
      assert_equal vector_content, File.read(File.join(result, 'vector.yaml'))
    end
  end

  def test_prepare_dir_uses_default_kubernetes_discovery_when_not_referenced
    # Create latest-valid-upstream with vector.yaml without kubernetes_discovery_ reference
    upstream_dir = File.join(@test_dir, 'vector-config', 'latest-valid-upstream')
    FileUtils.mkdir_p(upstream_dir)
    vector_content = "sources:\n  test:\n    type: file"
    File.write(File.join(upstream_dir, 'vector.yaml'), vector_content)

    result = @vector_config.prepare_dir

    # Test actual outcome - should use 0-default when kubernetes_discovery not used
    assert result
    assert_equal File.join(@test_dir, 'kubernetes-discovery', '0-default'),
                 File.readlink(File.join(result, 'kubernetes-discovery'))
    assert_equal vector_content, File.read(File.join(result, 'vector.yaml'))
  end

  def test_validate_dir_returns_nil_on_success
    config_dir = File.join(@test_dir, 'test-config')
    FileUtils.mkdir_p(config_dir)
    File.write(File.join(config_dir, 'vector.yaml'), "test: config")
    FileUtils.mkdir_p(File.join(config_dir, 'kubernetes-discovery'))

    # Mock successful vector validation
    original_backtick = @vector_config.method(:`)
    @vector_config.define_singleton_method(:`) do |cmd|
      # Run a command that succeeds to set $?.success? to true
      original_backtick.call('true')
      "Configuration validated successfully"
    end

    result = @vector_config.validate_dir(config_dir)
    assert_nil result
  end

  def test_validate_dir_returns_error_message_on_failure
    config_dir = File.join(@test_dir, 'test-config')
    FileUtils.mkdir_p(config_dir)

    # Mock failed vector validation
    original_backtick = @vector_config.method(:`)
    @vector_config.define_singleton_method(:`) do |cmd|
      # Run a command that fails to set $?.success? to false
      original_backtick.call('false')
      "Error: Invalid configuration"
    end

    result = @vector_config.validate_dir(config_dir)
    assert_equal "Error: Invalid configuration", result
  end

  def test_promote_dir
    config_dir = File.join(@vector_config_dir, 'new_test')
    FileUtils.mkdir_p(config_dir)

    # Create old current directory with a marker file
    current_path = File.join(@vector_config_dir, 'current')
    FileUtils.mkdir_p(current_path)
    File.write(File.join(current_path, 'old_marker.txt'), 'old content')

    # Create a marker in new config
    File.write(File.join(config_dir, 'new_marker.txt'), 'new content')

    # Mock system call for supervisorctl
    @vector_config.stub :system, true do
      @vector_config.promote_dir(config_dir)

      # Test actual outcomes - directory movement
      assert File.directory?(current_path), "Current directory should exist"
      assert !File.exist?(config_dir), "Original config directory should be moved"

      # Check that old content was replaced with new content
      assert !File.exist?(File.join(current_path, 'old_marker.txt')), "Old marker should be gone"
      assert File.exist?(File.join(current_path, 'new_marker.txt')), "New marker should be present"
    end
  end
end