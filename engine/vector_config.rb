require 'fileutils'
require 'time'
require_relative 'utils'
require_relative 'kubernetes_discovery'

class VectorConfig
  include Utils

  VECTOR_CONFIG_FILES = ['vector.yaml', 'manual.vector.yaml', 'process_discovery.vector.yaml'].freeze

  MINIMAL_KUBERNETES_DISCOVERY_CONFIG = <<~YAML
    ---
    sources:
      kubernetes_discovery_static_metrics:
        type: static_metrics
        namespace: ''  # Empty namespace to avoid "static_" prefix
        metrics:
          - name: collector_kubernetes_discovered_pods
            kind: absolute
            value:
              gauge:
                value: 0
            tags: {}
  YAML

  def initialize(working_dir)
    @working_dir = working_dir
    @vector_config_dir = File.join(@working_dir, "vector-config")
  end

  # Validate upstream vector.yaml file using minimal kubernetes discovery config
  # Validate upstream config files (vector.yaml, manual.vector.yaml, and/or process_discovery.vector.yaml)
  def validate_upstream_files(version_dir)
    # Check if at least one config file exists
    config_paths = VECTOR_CONFIG_FILES.map { |filename| File.join(version_dir, filename) }
    if config_paths.none? { |path| File.exist?(path) }
      return "None of: #{VECTOR_CONFIG_FILES.join(', ')} found in #{version_dir}"
    end

    # Check for command: directives in all files (security check)
    VECTOR_CONFIG_FILES.each do |filename|
      file_path = File.join(version_dir, filename)
      if File.exist?(file_path) && File.read(file_path).include?('command:')
        return "#{filename} must not contain command: directives"
      end
    end

    timestamp = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S')
    tmp_dir = "/tmp/validate-vector-config-file-#{timestamp}"

    FileUtils.rm_rf(tmp_dir) if File.exist?(tmp_dir)
    FileUtils.mkdir_p(tmp_dir)

    begin
      # Copy existing config files
      VECTOR_CONFIG_FILES.each do |filename|
        source_path = File.join(version_dir, filename)
        if File.exist?(source_path)
          FileUtils.cp(source_path, "#{tmp_dir}/#{filename}")
          puts "Copied #{filename} (#{File.size(source_path)} bytes)"
        end
      end
      FileUtils.mkdir_p("#{tmp_dir}/kubernetes-discovery")
      File.write("#{tmp_dir}/kubernetes-discovery/minimal.yaml", MINIMAL_KUBERNETES_DISCOVERY_CONFIG)

      # Build validation command with available files
      validate_files = []
      VECTOR_CONFIG_FILES.each do |filename|
        file_path = "#{tmp_dir}/#{filename}"
        validate_files << file_path if File.exist?(file_path)
      end
      validate_files << "#{tmp_dir}/kubernetes-discovery/*.yaml"

      validate_cmd = "REGION=unknown AZ=unknown vector validate #{validate_files.join(' ')} 2>&1"

      puts "Running validation command: #{validate_cmd}"
      puts "Files to validate: #{validate_files.inspect}"
      output = `#{validate_cmd}`
      return output unless $?.success?

      nil
    ensure
      FileUtils.rm_rf(tmp_dir)
    end
  end

  # Promote validated upstream files to latest-valid-upstream directory
  def promote_upstream_files(version_dir)
    latest_valid_upstream_dir = File.join(@vector_config_dir, "latest-valid-upstream")
    temp_upstream_dir = File.join(@vector_config_dir, "latest-valid-upstream.tmp.#{Time.now.utc.to_f}")

    # Copy files to temporary directory first
    FileUtils.mkdir_p(temp_upstream_dir)

    # Copy config files if they exist
    promoted_files = []
    VECTOR_CONFIG_FILES.each do |filename|
      source_path = File.join(version_dir, filename)
      if File.exist?(source_path)
        FileUtils.cp(source_path, File.join(temp_upstream_dir, filename))
        promoted_files << filename
      end
    end

    # Replace the old directory with the new one (not atomic but good enough)
    FileUtils.rm_rf(latest_valid_upstream_dir) if File.exist?(latest_valid_upstream_dir)
    FileUtils.mv(temp_upstream_dir, latest_valid_upstream_dir)

    # Report what was promoted
    puts "Promoted #{promoted_files.join(', ')} to latest-valid-upstream"
  end

  # Prepare a new vector-config directory
  def prepare_dir
    timestamp = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%6NZ')
    new_version_dir = File.join(@vector_config_dir, "new_#{timestamp}")

    begin
      FileUtils.mkdir_p(new_version_dir)

      # Copy files from latest-valid-upstream directory
      latest_valid_upstream_dir = File.join(@vector_config_dir, "latest-valid-upstream")

      unless File.exist?(latest_valid_upstream_dir)
        puts "Error: No latest-valid-upstream directory found"
        FileUtils.rm_rf(new_version_dir)
        return nil
      end

      # Copy all files from latest-valid-upstream
      FileUtils.cp_r(Dir.glob(File.join(latest_valid_upstream_dir, "*")), new_version_dir)

      # Check if vector config uses kubernetes_discovery_*
      uses_kubernetes_discovery = KubernetesDiscovery.vector_config_uses_kubernetes_discovery?(latest_valid_upstream_dir)

      if uses_kubernetes_discovery
        # Use latest actual kubernetes discovery
        kubernetes_discovery_dir = latest_kubernetes_discovery
        if kubernetes_discovery_dir && File.exist?(kubernetes_discovery_dir)
          FileUtils.ln_s(kubernetes_discovery_dir, File.join(new_version_dir, "kubernetes-discovery"))
        end
      else
        # Use 0-default when kubernetes discovery is not used
        default_kubernetes_discovery = File.join(@working_dir, "kubernetes-discovery", "0-default")
        if File.exist?(default_kubernetes_discovery)
          FileUtils.ln_s(default_kubernetes_discovery, File.join(new_version_dir, "kubernetes-discovery"))
        end
      end

      puts "Prepared vector-config directory: #{new_version_dir}"
      new_version_dir
    rescue => e
      puts "Error preparing vector-config directory: #{e.message}"
      FileUtils.rm_rf(new_version_dir) if File.exist?(new_version_dir)
      nil
    end
  end

  # Validate a vector-config directory
  def validate_dir(config_dir)
    puts "Validating vector config directory: #{config_dir}"

    # Build list of files to validate
    validate_files = []
    VECTOR_CONFIG_FILES.each do |filename|
      file_path = "#{config_dir}/#{filename}"
      validate_files << file_path if File.exist?(file_path)
    end
    validate_files << "#{config_dir}/kubernetes-discovery/*.yaml"

    validate_cmd = "REGION=unknown AZ=unknown vector validate #{validate_files.join(' ')} 2>&1"
    puts "Running validation: #{validate_cmd}"

    output = `#{validate_cmd}`
    return output unless $?.success?

    nil
  end

  # Promote a validated config directory to current
  def promote_dir(config_dir)
    puts "Promoting #{config_dir} to /vector-config/current..."

    current_link = File.join(@vector_config_dir, "current")
    backup_link = File.join(@vector_config_dir, "previous")
    temp_link = File.join(@vector_config_dir, "current.tmp.#{Time.now.utc.to_f}")

    begin
      # Create new symlink pointing to config_dir
      File.symlink(config_dir, temp_link)

      # Backup current link if it exists (might fail if current doesn't exist, that's ok)
      if File.exist?(current_link)
        begin
          File.rename(current_link, backup_link)
        rescue => e
          puts "Warning: Could not backup current link: #{e.message}"
        end
      end

      # Atomically replace current with new link
      File.rename(temp_link, current_link)

      puts "Atomically promoted #{config_dir} to current"

      # Clean up old directories after successful promotion
      cleanup_old_directories

      true
    rescue => e
      # Cleanup temp link if it exists
      FileUtils.rm_f(temp_link)

      # Try to restore backup if promotion failed and current is missing
      if !File.exist?(current_link) && File.exist?(backup_link)
        begin
          File.rename(backup_link, current_link)
          puts "Restored previous config due to promotion error"
        rescue => restore_error
          puts "Failed to restore backup: #{restore_error.message}"
        end
      end

      puts "Error promoting config: #{e.message}"
      raise
    end
  end

  def reload_vector
    puts "Reloading vector..."
    system("supervisorctl signal HUP vector")

    puts "Successfully promoted to current"
  end

  # Clean up old vector-config directories, keeping only the most recent ones
  def cleanup_old_directories(keep_count = 5)
    # Get all new_* directories
    new_dirs = Dir.glob(File.join(@vector_config_dir, "new_*")).select { |f| File.directory?(f) }

    # Sort by timestamp in directory name (newest last)
    new_dirs.sort!

    # Resolve symlinks to find directories that are currently in use
    current_link = File.join(@vector_config_dir, "current")
    previous_link = File.join(@vector_config_dir, "previous")

    in_use = []
    [current_link, previous_link].each do |link|
      if File.symlink?(link)
        target = File.readlink(link)
        # Convert relative path to absolute if needed
        target = File.absolute_path(target, @vector_config_dir) unless target.start_with?('/')
        in_use << target
      end
    end

    # Filter out directories that are currently in use
    deletable = new_dirs.reject { |dir| in_use.include?(dir) }

    # Keep only the most recent directories
    if deletable.length > keep_count
      to_delete = deletable[0...(deletable.length - keep_count)]
      to_delete.each do |dir|
        puts "Cleaning up old vector-config directory: #{File.basename(dir)}"
        FileUtils.rm_rf(dir)
      end
      puts "Cleaned up #{to_delete.length} old vector-config directories"
    end
  end
end