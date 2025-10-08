require 'fileutils'
require 'uri'
require 'json'
require 'socket'

module Utils
  ENRICHMENT_TABLE_PATH = "/enrichment/docker-mappings.csv"
  ENRICHMENT_TABLE_INCOMING_PATH = "/enrichment/docker-mappings.incoming.csv"
  DATABASES_TABLE_PATH = "/enrichment/databases.csv"
  DATABASES_TABLE_INCOMING_PATH = "/enrichment/databases.incoming.csv"

  # Shared and main.rb specific functions
  def latest_version
    # Assuming version directories are named like 'YYYY-MM-DDTHH:MM:SS'
    # and this function should return the name of the latest one.
    version_dirs = Dir.glob("#{@working_dir}/versions/*").select { |f| File.directory?(f) }
    return nil if version_dirs.empty?
    version_dirs.sort.last.split('/').last
  end

  def read_error
    error_file = "#{@working_dir}/errors.txt"
    return nil unless File.exist?(error_file)
    URI.encode_www_form_component(File.read(error_file).strip)
  end

  def write_error(message)
    puts "Error: #{message}"
    File.write("#{@working_dir}/errors.txt", message)
  end

  def clear_error
    error_file = "#{@working_dir}/errors.txt"
    FileUtils.rm_f(error_file) if File.exist?(error_file)
  end

  # Ensure vector config doesn't contain command: and is valid
  def validate_vector_config(version)
    config_path = "#{@working_dir}/versions/#{version}/vector.yaml"

    if File.read(config_path).include?('command:') # type: exec
      return 'vector.yaml must not contain command: directives'
    end

    output = `REGION=unknown AZ=unknown vector validate #{config_path}`
    return output unless $?.success?

    nil
  end

  def latest_database_json
    latest_ver = latest_version
    return '{}' unless latest_ver

    path = "#{@working_dir}/versions/#{latest_ver}/databases.json"

    if File.exist?(path)
      File.read(path)
    else
      '{}'
    end
  end

  def download_file(url, path)
    uri = URI(url)

    # Add hostname query parameter
    params = URI.decode_www_form(uri.query || '')
    params << ['host', hostname]
    uri.query = URI.encode_www_form(params)

    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
      request = Net::HTTP::Get.new(uri)
      response = http.request(request)

      if response.code == '200'
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, response.body)
        true
      else
        puts "Failed to download #{File.basename(path)} from #{url}. Response code: #{response.code}"
        false
      end
    end
  rescue SocketError => e
    puts "Error downloading #{File.basename(path)} from #{url}: #{e.message}"
    false
  end

  def hostname
    return ENV['HOSTNAME'] if ENV['HOSTNAME']

    # Try to get hostname from kubernetes mounted hostPath, if available
    if File.exist?('/host/proc/sys/kernel/hostname')
      return File.read('/host/proc/sys/kernel/hostname').strip
    end

    # Second, try using Socket class
    begin
      return Socket.gethostname
    rescue
      # If all else fails, return 'unknown'
      return 'unknown'
    end
  end

  # Always points to latest valid kubernetes discovery configs
  def latest_kubernetes_discovery
    versions = Dir.glob(File.join(@working_dir, "kubernetes-discovery", "*").to_s).select { |f| File.directory?(f) }
    versions.sort.last
  end
end
