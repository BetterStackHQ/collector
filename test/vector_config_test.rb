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

  def test_validate_upstream_files_rejects_command_directive_in_process_discovery_yaml
    version_dir = File.join(@test_dir, 'versions', '2025-01-01T00:00:00')
    FileUtils.mkdir_p(version_dir)
    File.write(File.join(version_dir, 'process_discovery.vector.yaml'), "sources:\n  test:\n    type: exec\n    command: ['echo', 'test']")

    result = @vector_config.validate_upstream_files(version_dir)
    assert_equal 'process_discovery.vector.yaml must not contain command: directives', result
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

  def test_validate_upstream_files_accepts_process_discovery_only
    version_dir = File.join(@test_dir, 'versions', '2025-01-01T00:00:00')
    FileUtils.mkdir_p(version_dir)
    # Only create process_discovery.vector.yaml, no vector.yaml or manual.vector.yaml
    File.write(File.join(version_dir, 'process_discovery.vector.yaml'), "sources:\n  test:\n    type: file\n    include: ['/test']")

    # Mock successful vector validation
    original_backtick = @vector_config.method(:`)
    @vector_config.define_singleton_method(:`) do |cmd|
      # Run a command that succeeds to set $?.success? to true
      original_backtick.call('true')
      "Configuration validated successfully"
    end

    result = @vector_config.validate_upstream_files(version_dir)
    assert_nil result, "Should accept process_discovery.vector.yaml alone"
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

  def test_promote_upstream_files_with_process_discovery
    # Create a version directory with all three config files
    version_dir = File.join(@test_dir, 'versions', '2025-01-01T00:00:00')
    FileUtils.mkdir_p(version_dir)
    File.write(File.join(version_dir, 'vector.yaml'), "sources:\n  test:\n    type: file")
    File.write(File.join(version_dir, 'manual.vector.yaml'), "sources:\n  manual:\n    type: file")
    File.write(File.join(version_dir, 'process_discovery.vector.yaml'), "sources:\n  process:\n    type: file")

    @vector_config.promote_upstream_files(version_dir)

    # Test the actual outcome - all files copied to latest-valid-upstream
    upstream_dir = File.join(@test_dir, 'vector-config', 'latest-valid-upstream')
    assert File.exist?(File.join(upstream_dir, 'vector.yaml'))
    assert File.exist?(File.join(upstream_dir, 'manual.vector.yaml'))
    assert File.exist?(File.join(upstream_dir, 'process_discovery.vector.yaml'))
    assert_equal "sources:\n  test:\n    type: file", File.read(File.join(upstream_dir, 'vector.yaml'))
    assert_equal "sources:\n  manual:\n    type: file", File.read(File.join(upstream_dir, 'manual.vector.yaml'))
    assert_equal "sources:\n  process:\n    type: file", File.read(File.join(upstream_dir, 'process_discovery.vector.yaml'))
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
    old_current_dir = File.join(@vector_config_dir, 'old_current')
    FileUtils.mkdir_p(old_current_dir)
    File.write(File.join(old_current_dir, 'old_marker.txt'), 'old content')

    # Create current as symlink to old directory
    current_link = File.join(@vector_config_dir, 'current')
    File.symlink(old_current_dir, current_link)

    # Create a marker in new config
    File.write(File.join(config_dir, 'new_marker.txt'), 'new content')

    # Mock cleanup_old_directories to avoid side effects in test
    @vector_config.stub :cleanup_old_directories, nil do
      @vector_config.stub :system, true do
        @vector_config.promote_dir(config_dir)

        # Test actual outcomes - symlink behavior
        assert File.symlink?(current_link), "Current should be a symlink"
        assert File.exist?(config_dir), "Original config directory should still exist"

        # Check that current symlink points to new config directory
        assert_equal config_dir, File.readlink(current_link)

        # Check that content is accessible through the symlink
        assert !File.exist?(File.join(current_link, 'old_marker.txt')), "Old marker should not be accessible through current"
        assert File.exist?(File.join(current_link, 'new_marker.txt')), "New marker should be accessible through current"
      end
    end
  end

  def test_cleanup_old_directories
    # Create 10 old directories
    old_dirs = []
    10.times do |i|
      timestamp = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%6NZ')
      dir_name = File.join(@vector_config_dir, "new_2023-01-0#{i}T00:00:00.#{sprintf('%06d', i)}Z")
      FileUtils.mkdir_p(dir_name)
      File.write(File.join(dir_name, 'test.txt'), "content #{i}")
      old_dirs << dir_name
      sleep 0.001 # Ensure unique timestamps
    end

    # Create current and previous symlinks pointing to some directories
    current_dir = old_dirs[8]
    previous_dir = old_dirs[7]

    current_link = File.join(@vector_config_dir, 'current')
    previous_link = File.join(@vector_config_dir, 'previous')

    File.symlink(current_dir, current_link)
    File.symlink(previous_dir, previous_link)

    # Run cleanup with keep_count=3
    @vector_config.cleanup_old_directories(3)

    # Check results
    # Directories 0-4 should be deleted (5 oldest not in use)
    (0..4).each do |i|
      assert !File.exist?(old_dirs[i]), "Old directory #{i} should be deleted"
    end

    # Directories 5-6 should exist (kept as part of keep_count=3)
    (5..6).each do |i|
      assert File.exist?(old_dirs[i]), "Directory #{i} should be kept"
    end

    # Directories 7-8 should exist (in use as previous/current)
    assert File.exist?(old_dirs[7]), "Directory 7 should exist (previous)"
    assert File.exist?(old_dirs[8]), "Directory 8 should exist (current)"

    # Directory 9 should exist (most recent, part of keep_count)
    assert File.exist?(old_dirs[9]), "Directory 9 should be kept (most recent)"
  end

  def test_cleanup_old_directories_with_relative_symlinks
    # Create directories
    dir1 = File.join(@vector_config_dir, 'new_2023-01-01T00:00:00.000001Z')
    dir2 = File.join(@vector_config_dir, 'new_2023-01-02T00:00:00.000002Z')

    FileUtils.mkdir_p(dir1)
    FileUtils.mkdir_p(dir2)

    # Create current as relative symlink
    current_link = File.join(@vector_config_dir, 'current')
    Dir.chdir(@vector_config_dir) do
      File.symlink('new_2023-01-02T00:00:00.000002Z', 'current')
    end

    # Run cleanup with keep_count=0 (should still keep dir2 as it's in use)
    @vector_config.cleanup_old_directories(0)

    # dir2 should still exist as it's referenced by current
    assert File.exist?(dir2), "Directory referenced by current should not be deleted"

    # dir1 should be deleted
    assert !File.exist?(dir1), "Unreferenced directory should be deleted"
  end

  def test_cleanup_old_directories_ignores_non_new_directories
    # Create various directories
    new_dir = File.join(@vector_config_dir, 'new_2023-01-01T00:00:00.000001Z')
    other_dir = File.join(@vector_config_dir, 'latest-valid-upstream')
    random_dir = File.join(@vector_config_dir, 'some-other-dir')

    FileUtils.mkdir_p(new_dir)
    FileUtils.mkdir_p(other_dir)
    FileUtils.mkdir_p(random_dir)

    # Run cleanup
    @vector_config.cleanup_old_directories(0)

    # Only new_* directory should be deleted
    assert !File.exist?(new_dir), "Old new_* directory should be deleted"
    assert File.exist?(other_dir), "Non-new directory should not be deleted"
    assert File.exist?(random_dir), "Non-new directory should not be deleted"
  end
end