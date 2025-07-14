require_relative 'utils'
require 'net/http'

class BetterStackClient
  include Utils

  def initialize(working_dir)
    @base_url = (ENV['BASE_URL'] || 'https://telemetry.betterstack.com').chomp('/')
    @collector_secret = ENV['COLLECTOR_SECRET']
    @working_dir = working_dir.chomp('/')

    if @collector_secret.nil? || @collector_secret.empty?
      puts "Error: COLLECTOR_SECRET environment variable is required"
      exit 1
    end
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

    response = make_post_request('/collector/ping', ping_params)
    process_ping(response.code, response.body)
  end

  def process_ping(code, body)
    case code
    when '204'
      puts "No updates available"
      clear_error
      return
    when '200'
      data = JSON.parse(body)
      if data['status'] == 'new_version_available'
        new_version = data['configuration_version']
        puts "New version available: #{new_version}"

        get_configuration(new_version)
      else
        # Status is not 'new_version_available', could be an error message or other status
        puts "No new version. Status: #{data['status']}"
        clear_error
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

        path = "#{@working_dir}/versions/#{new_version}/#{filename}".gsub(/\/+/, '/')
        puts "Downloading #{filename} to #{path}"

        unless download_file(file_url, path)
          write_error("Failed to download #{filename} for version #{new_version}")
          all_files_downloaded = false
          break # Stop trying to download other files
        end
      end

      unless all_files_downloaded
        puts "Aborting update due to download failure."
        return
      end

      puts "All files downloaded. Validating configuration..."

      # Validate vector config
      validate_output = validate_vector_config(new_version)
      unless validate_output.nil?
        write_error("Invalid vector config #{new_version}/vector.yaml\n\n#{validate_output}")
        return # Exit this iteration
      end

      promote_version(new_version)
    else
      write_error("Failed to fetch configuration for version #{new_version}. Response code: #{code}")
      return
    end
  end

  def promote_version(new_version)
    # Update symlink and cleanup
    puts "Configuration validated. Updating symlink..."
    update_vector_symlink(new_version)
    clear_error
    puts "Successfully updated to version #{new_version}"
  end
end
