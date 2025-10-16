require_relative 'utils'
require_relative 'kubernetes_discovery'
require_relative 'vector_config'
require_relative 'ebpf_compatibility_checker'
require_relative 'containers_enrichment_table'
require_relative 'databases_enrichment_table'
require_relative 'ssl_certificate_manager'
require 'net/http'
require 'fileutils'
require 'time'
require 'forwardable'

class BetterStackClient
  extend Forwardable
  include Utils

  NOT_CLEARABLE_ERRORS = ['Validation failed', 'Invalid configuration version', 'Invalid filename'].freeze

  def_delegator :@vector_config, :reload_vector

  def initialize(working_dir)
    @base_url = (ENV['BASE_URL'] || 'https://telemetry.betterstack.com').chomp('/')
    @collector_secret = ENV['COLLECTOR_SECRET']
    @working_dir = working_dir.chomp('/')

    if @collector_secret.nil? || @collector_secret.empty?
      puts "Error: COLLECTOR_SECRET environment variable is required"
      exit 1
    end

    @kubernetes_discovery = KubernetesDiscovery.new(working_dir)
    @vector_config = VectorConfig.new(working_dir)
    @ebpf_compatibility_checker = EbpfCompatibilityChecker.new(working_dir)
    @ssl_certificate_manager = SSLCertificateManager.new(nil)  # Use default /etc path for production

    containers_path = File.join(working_dir, 'enrichment', 'docker-mappings.csv')
    containers_incoming_path = File.join(working_dir, 'enrichment', 'docker-mappings.incoming.csv')
    @containers_enrichment_table = ContainersEnrichmentTable.new(containers_path, containers_incoming_path)

    databases_path = File.join(working_dir, 'enrichment', 'databases.csv')
    databases_incoming_path = File.join(working_dir, 'enrichment', 'databases.incoming.csv')
    @databases_enrichment_table = DatabasesEnrichmentTable.new(databases_path, databases_incoming_path)
  end

  def make_post_request(path, params)
    uri = URI("#{@base_url}/api#{path}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    request = Net::HTTP::Post.new(uri.path)
    request.set_form_data(params)
    http.request(request)
  end

  def cluster_collector?
    if ENV['CLUSTER_COLLECTOR'] == 'true'
      puts "CLUSTER_COLLECTOR configured in the ENV, forcing cluster collector mode"
      return true
    end

    response = make_post_request('/collector/cluster-collector', {
      collector_secret: @collector_secret,
      host: hostname,
    })

    case response.code
    when '204', '200'
      return true
    when '401', '403'
      puts 'Cluster collector check failed: unauthorized. Please check your COLLECTOR_SECRET.'
      exit 1
    when '409'
      # server returns 409 if a different collector is supposed to be cluster collector
      return false
    else
      puts "Unexpected response from cluster-collector endpoint: #{response.code}"
      return false
    end
  end

  def ping
    ping_params = {
      collector_secret: @collector_secret,
      cluster_collector: ENV['CLUSTER_COLLECTOR'] == 'true',
      host: hostname,
      collector_version: ENV['COLLECTOR_VERSION'],
      vector_version: ENV['VECTOR_VERSION'],
      beyla_version: ENV['BEYLA_VERSION'],
      cluster_agent_version: ENV['CLUSTER_AGENT_VERSION'],
    }
    ping_params[:configuration_version] = latest_version if latest_version # Only send version if one exists
    ping_params[:error] = read_error if read_error

    # Include system_information only on first ping
    if !@ebpf_compatibility_checker.reported? && @ebpf_compatibility_checker.system_information
      ping_params[:system_information] = @ebpf_compatibility_checker.system_information.to_json
    end

    response = make_post_request('/collector/ping', ping_params)

    if response.code == '204' || response.code == '200'
      @ebpf_compatibility_checker.mark_as_reported
    end

    upstream_changed = process_ping(response.code, response.body)

    # Run kubernetes discovery if latest valid vector config uses kubernetes_discovery_*
    vector_config_uses_kubernetes_discovery = @kubernetes_discovery.should_discover?
    kubernetes_discovery_changed = @kubernetes_discovery.run if vector_config_uses_kubernetes_discovery

    # Create new vector-config version if either changed
    if upstream_changed || kubernetes_discovery_changed
      puts "Upstream configuration changed - updating vector-config" if upstream_changed
      puts "Kubernetes discovery changed - updating vector-config" if kubernetes_discovery_changed

      new_config_dir = @vector_config.prepare_dir
      validate_output = @vector_config.validate_dir(new_config_dir)
      unless validate_output.nil?
        write_error("Validation failed for vector config with kubernetes_discovery\n\n#{validate_output}")
        return false
      end

      result = @vector_config.promote_dir(new_config_dir)
      clear_error

      return result
    end

    false
  end

  def enrichment_table_changed? = @containers_enrichment_table.different?

  def validate_enrichment_table
    output = @containers_enrichment_table.validate
    unless output.nil?
      write_error("Validation failed for enrichment table\n\n#{output}")
      return output
    end

    nil
  end

  def promote_enrichment_table = @containers_enrichment_table.promote

  def databases_table_changed? = @databases_enrichment_table.different?

  def validate_databases_table
    output = @databases_enrichment_table.validate
    unless output.nil?
      write_error("Validation failed for databases enrichment table\n\n#{output}")
      return output
    end

    nil
  end

  def promote_databases_table = @databases_enrichment_table.promote

  def process_ping(code, body)
    case code
    when '204'
      puts "No updates available"
      # Clear transient errors not related to the configuration on successful, no-updates ping
      clear_error if error_clearable?
      return
    when '200'
      data = JSON.parse(body)
      if data['status'] == 'new_version_available'
        new_version = data['configuration_version']
        puts "New version available: #{new_version}"

        return get_configuration(new_version)
      else
        # Status is not 'new_version_available', could be an error message or other status
        puts "No new version. Status: #{data['status']}"
        return
      end
    when '401', '403'
      puts 'Ping failed: unauthorized. Please check your COLLECTOR_SECRET.'
      exit 1
    else
      puts "Unexpected response from ping endpoint: #{code}"
      begin
        # Try to parse body for more details if it's JSON
        error_details = JSON.parse(body)
        write_error("Ping failed: #{code}. Details: #{error_details}")
      rescue JSON::ParserError
        write_error("Ping failed: #{code}. Body: #{body}")
      end
      return
    end
  rescue SocketError => e # More specific network errors
    write_error("Network error: #{e.message}")
    return
  rescue JSON::ParserError => e
    write_error("Error parsing JSON response: #{e.message}")
    return
  rescue StandardError => e
    puts "An unexpected error occurred: #{e.message}"
    puts e.backtrace.join("\n")
    write_error("Error: #{e.message}")
    return
  end

  def get_configuration(new_version)
    if new_version.include?('..')
      write_error("Invalid configuration version: '#{new_version}'")
      return
    end

    params = {
      collector_secret: @collector_secret,
      configuration_version: new_version
    }

    response = make_post_request('/collector/configuration', params)
    process_configuration(new_version, response.code, response.body)
  end

  def process_configuration(new_version, code, body)
    if code == '200'
      data = JSON.parse(body)

      puts "Downloading configuration files for version #{new_version}..."
      all_files_downloaded = true
      databases_csv_exists = false
      ssl_certificate_host_exists = false
      ssl_certificate_host_content = nil

      data['files'].each do |file_info|
        # Assuming file_info is a hash {'url': '...', 'name': '...'} or just a URL string
        file_url = @base_url + (file_info.is_a?(Hash) ? file_info['path'] : file_info)
        filename = file_info.is_a?(Hash) ? file_info['name'] : URI.decode_www_form(URI(file_url).query).to_h['file']

        # Ensure filename is safe and not an absolute path or contains '..'
        if filename.nil? || filename.empty? || filename.include?('..') || filename.start_with?('/')
          write_error("Invalid filename '#{filename}' received for version #{new_version}")
          all_files_downloaded = false
          break
        end

        # Track special files
        databases_csv_exists = true if filename == "databases.csv"
        ssl_certificate_host_exists = true if filename == "ssl_certificate_host.txt"

        path = "#{@working_dir}/versions/#{new_version}/#{filename}".gsub(%r{/+}, '/')
        puts "Downloading #{filename} to #{path}"

        begin
          download_file(file_url, path)
        rescue Utils::DownloadError => e
          write_error("Failed to download #{filename} for version #{new_version}: #{e.message}")
          all_files_downloaded = false
          break # Stop trying to download other files
        end

        # Read ssl_certificate_host content for processing
        if filename == "ssl_certificate_host.txt"
          puts "Got SSL certificate host: #{ssl_certificate_host_content}"
          ssl_certificate_host_content = File.read(path).strip rescue ''
        end
      end

      unless all_files_downloaded
        puts "Aborting update due to download failure."
        return
      end

      puts "All files downloaded. Processing configuration..."

      version_dir = File.join(@working_dir, "versions", new_version)

      # Process SSL certificate host if included
      skip_vector_validation = false
      if ssl_certificate_host_exists
        domain_changed = @ssl_certificate_manager.process_ssl_certificate_host(ssl_certificate_host_content || '')
        if domain_changed
          puts "SSL certificate domain changed, will skip Vector validation for this update cycle if certificate not ready"
          skip_vector_validation = @ssl_certificate_manager.should_skip_validation?
        end
      end

      # Validate databases.csv if it exists in this version
      if databases_csv_exists
        databases_csv_path = File.join(version_dir, 'databases.csv')

        # Get the incoming path from the databases_enrichment_table instance
        incoming_path = @databases_enrichment_table.incoming_path

        # Ensure the enrichment directory exists and copy to incoming path for validation
        FileUtils.mkdir_p(File.dirname(incoming_path))
        FileUtils.cp(databases_csv_path, incoming_path)

        databases_validate_output = @databases_enrichment_table.validate
        unless databases_validate_output.nil?
          write_error("Validation failed for databases enrichment table\n\n#{databases_validate_output}")
          # Clean up the incoming file on validation failure
          FileUtils.rm_f(incoming_path)
          return
        end
      end

      # Validate and promote vector config only if not skipping
      if skip_vector_validation
        puts "Skipping Vector validation and promotion due to pending SSL certificate"
      else
        puts "Proceeding with Vector validation"
        validate_output = @vector_config.validate_upstream_files(version_dir)
        if validate_output
          write_error("Validation failed for vector config in #{new_version}\n\n#{validate_output}")
          return
        end

        # Only promote vector config if validation passed
        @vector_config.promote_upstream_files(version_dir)
      end

      # Promote databases.csv if it was included and validated
      if databases_csv_exists
        @databases_enrichment_table.promote
        puts "Promoted databases.csv to #{@databases_enrichment_table.target_path}"
      end

      # Reset SSL manager flag for next ping cycle
      @ssl_certificate_manager.reset_change_flag if ssl_certificate_host_exists

      # Clean up version directory if we skipped vector validation
      # This ensures we'll get the config again on next ping
      if skip_vector_validation
        puts "Removing version directory to retry vector config on next ping cycle"
        FileUtils.rm_rf(version_dir)
      end

      !skip_vector_validation
    else
      write_error("Failed to fetch configuration for version #{new_version}. Response code: #{code}")
    end
  end

  def error_clearable?
    last_error = read_error
    return false if last_error.nil? # no need to clear if no error
    last_error = URI.decode_www_form_component(last_error) if last_error
    !NOT_CLEARABLE_ERRORS.any? { |error| last_error.include?(error) }
  end
end
