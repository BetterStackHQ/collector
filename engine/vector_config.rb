require 'fileutils'
require 'time'
require_relative 'utils'

class VectorConfig
  include Utils
  MINIMAL_KUBERNETES_DISCOVERY_CONFIG = <<~YAML
    ---
    sources:
      kubernetes_discovery_prometheus_scrape_minimal_dummy_config:
        type: file
        include:
          - /dev/null
  YAML

  def initialize(working_dir)
    @working_dir = working_dir
    @vector_config_dir = "#{@working_dir}/vector-config"
  end

  # Validate upstream vector.yaml file using minimal kubernetes discovery config
  def validate_upstream_file(vector_yaml_path)
    # Check for command: directives (security check)
    if File.read(vector_yaml_path).include?('command:')
      return 'vector.yaml must not contain command: directives'
    end

    timestamp = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S')
    tmp_dir = "/tmp/validate-vector-config-file-#{timestamp}"

    FileUtils.rm_rf(tmp_dir) if File.exist?(tmp_dir)
    FileUtils.mkdir_p(tmp_dir)

    begin
      FileUtils.cp(vector_yaml_path, "#{tmp_dir}/vector.yaml")
      FileUtils.mkdir_p("#{tmp_dir}/kubernetes-discovery")
      File.write("#{tmp_dir}/kubernetes-discovery/minimal.yaml", MINIMAL_KUBERNETES_DISCOVERY_CONFIG)

      output = `REGION=unknown AZ=unknown vector validate #{tmp_dir}/vector.yaml #{tmp_dir}/kubernetes-discovery/\*.yaml 2>&1`
      return output unless $?.success?

      nil
    ensure
      FileUtils.rm_rf(tmp_dir)
    end
  end

  # Promote new vector.yaml to latest-valid-vector.yaml
  def promote_upstream_file(vector_yaml_path)
    last_valid_path = "#{@working_dir}/latest-valid-vector.yaml"
    
    # Remove old symlink and create new one
    FileUtils.rm_f(last_valid_path)
    FileUtils.ln_s(vector_yaml_path, last_valid_path)
    
    puts "Updated latest-valid-vector.yaml symlink"
  end

  # Prepare a new vector-config directory
  def prepare_dir
    timestamp = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%6NZ')
    new_version_dir = "#{@vector_config_dir}/new_#{timestamp}"
    
    begin
      FileUtils.mkdir_p(new_version_dir)
      
      # Always use latest-valid-vector.yaml
      last_valid_vector = "#{@working_dir}/latest-valid-vector.yaml"
      unless File.exist?(last_valid_vector)
        puts "Error: No latest-valid-vector.yaml found"
        FileUtils.rm_rf(new_version_dir)
        return nil
      end
      
      FileUtils.ln_s(last_valid_vector, "#{new_version_dir}/vector.yaml")
      
      # Use latest actual kubernetes discovery
      kubernetes_discovery_dir = latest_kubernetes_discovery
      if kubernetes_discovery_dir && File.exist?(kubernetes_discovery_dir)
        FileUtils.ln_s(kubernetes_discovery_dir, "#{new_version_dir}/kubernetes-discovery")
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
    
    output = `REGION=unknown AZ=unknown vector validate #{config_dir}/vector.yaml #{config_dir}/kubernetes-discovery/\*.yaml 2>&1`
    return output unless $?.success?
    
    nil
  end

  # Promote a validated config directory to current
  def promote_dir(config_dir)
    puts "Promoting #{config_dir} to current..."
    
    # Atomically replace previous vector-config
    FileUtils.mv(config_dir, "#{@vector_config_dir}/current", force: true)
    
    puts "Reloading vector..."
    system("supervisorctl signal HUP vector")
    
    puts "Successfully promoted to current"
  end
end