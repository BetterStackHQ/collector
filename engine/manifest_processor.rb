require 'net/http'
require 'json'
require 'uri'
require 'fileutils'
require 'tempfile'

class ManifestProcessor
  def initialize
    @base_url = (ENV['BASE_URL'] || 'https://telemetry.betterstack.com').chomp('/')
    @collector_secret = ENV['COLLECTOR_SECRET']
  end

  def manifest_version
    return @manifest_version if defined?(@manifest_version)

    manifest_path = '/var/lib/better-stack/manifest.json'
    return @manifest_version = nil unless File.exist?(manifest_path)

    begin
      manifest_data = JSON.parse(File.read(manifest_path))
      @manifest_version = manifest_data['manifest_version']
    rescue JSON::ParserError, Errno::ENOENT
      @manifest_version = nil
    end
  end

  def update_manifest(new_manifest)
    puts "Updating manifest to version #{new_manifest}..."

    # Step 1: Download new manifest
    new_manifest_data = download_manifest(new_manifest)
    return false unless new_manifest_data

    # Step 2: Load current manifest and compare
    current_manifest_data = load_current_manifest
    files_to_download, files_to_delete = compare_manifests(current_manifest_data, new_manifest_data)

    puts "Files to download: #{files_to_download.size}"
    puts "Files to delete: #{files_to_delete.size}"

    # Step 3: Download files to staging area
    staged_files = download_files_to_staging(new_manifest, files_to_download)
    return false if staged_files.nil?

    # Step 4: Move files to final locations atomically
    reload_collector = false
    reload_beyla = false

    staged_files.each do |file_info|
      target_path = "/var/lib/better-stack/#{file_info[:container]}/#{file_info[:path]}"

      # Create parent directory
      FileUtils.mkdir_p(File.dirname(target_path))

      # Move file from staging to final location
      FileUtils.mv(file_info[:temp_file], target_path)
      puts "Moved #{file_info[:container]}/#{file_info[:path]} to #{target_path}"

      # Apply actions
      if file_info[:actions]&.include?('make_executable')
        File.chmod(0755, target_path)
        puts "Made executable: #{target_path}"
      end

      # Track which containers need supervisor reload
      if file_info[:actions]&.include?('reload_supervisor')
        reload_collector = true if file_info[:container] == 'collector'
        reload_beyla = true if file_info[:container] == 'beyla'
      end
    end

    # Step 5: Update manifest.json
    manifest_path = '/var/lib/better-stack/manifest.json'
    FileUtils.mkdir_p(File.dirname(manifest_path))
    File.write(manifest_path, JSON.pretty_generate(new_manifest_data))
    puts "Updated manifest.json to version #{new_manifest_data['manifest_version']}"

    # Clear memoized version so next call reads the new one
    @manifest_version = nil

    # Step 6: Delete removed files (before supervisor reload)
    files_to_delete.each do |file_info|
      file_path = "/var/lib/better-stack/#{file_info['container']}/#{file_info['path']}"
      if File.exist?(file_path)
        FileUtils.rm_f(file_path)
        puts "Deleted removed file: #{file_path}"

        # Track reload needs for deleted files too
        if file_info['actions']&.include?('reload_supervisor')
          reload_collector = true if file_info['container'] == 'collector'
          reload_beyla = true if file_info['container'] == 'beyla'
        end
      end
    end

    # Step 7: Reload supervisor(s) if needed
    if reload_collector
      puts "Reloading collector supervisor..."
      system('supervisorctl reread')
      system('supervisorctl update')
    end

    if reload_beyla
      puts "Reloading beyla supervisor..."
      system('supervisorctl -s /beyla_supervisor_socket/supervisor.sock reread')
      system('supervisorctl -s /beyla_supervisor_socket/supervisor.sock update')
    end

    puts "Manifest update completed successfully!"
    true
  rescue StandardError => e
    puts "Error updating manifest: #{e.message}"
    puts e.backtrace.join("\n")
    false
  end

  private

  def download_manifest(manifest_version)
    url = "#{@base_url}/api/collector/manifest?" \
          "collector_secret=#{URI.encode_www_form_component(@collector_secret)}&" \
          "manifest_version=#{URI.encode_www_form_component(manifest_version.to_s)}"

    response = make_http_request(url)
    return nil unless response

    begin
      data = JSON.parse(response)

      # Validate manifest structure
      unless data['manifest_version'] && data['files'].is_a?(Array)
        puts "Error: Invalid manifest structure"
        return nil
      end

      data
    rescue JSON::ParserError => e
      puts "Error: Failed to parse manifest JSON: #{e.message}"
      nil
    end
  end

  def load_current_manifest
    manifest_path = '/var/lib/better-stack/manifest.json'
    return nil unless File.exist?(manifest_path)

    begin
      JSON.parse(File.read(manifest_path))
    rescue JSON::ParserError
      nil
    end
  end

  def compare_manifests(current_manifest, new_manifest)
    files_to_download = []
    files_to_delete = []

    # Build index of current files for quick lookup
    current_files = {}
    if current_manifest && current_manifest['files']
      current_manifest['files'].each do |file|
        key = "#{file['container']}/#{file['path']}"
        current_files[key] = file
      end
    end

    # Build index of new files
    new_files = {}
    new_manifest['files'].each do |file|
      key = "#{file['container']}/#{file['path']}"
      new_files[key] = file

      # Check if file is new or version changed
      current_file = current_files[key]
      if current_file.nil? || current_file['version'] != file['version']
        files_to_download << file
      end
    end

    # Find files to delete (in current but not in new)
    current_files.each do |key, file|
      files_to_delete << file unless new_files[key]
    end

    [files_to_download, files_to_delete]
  end

  def download_files_to_staging(manifest_version, files)
    staged_files = []
    max_retries = 2

    files.each_with_index do |file, index|
      puts "[#{index + 1}/#{files.size}] Downloading: #{file['container']}/#{file['path']}"

      url = "#{@base_url}/api/collector/manifest_file?" \
            "collector_secret=#{URI.encode_www_form_component(@collector_secret)}&" \
            "manifest_version=#{URI.encode_www_form_component(manifest_version.to_s)}&" \
            "path=#{URI.encode_www_form_component(file['path'])}&" \
            "container=#{URI.encode_www_form_component(file['container'])}"

      # Retry logic for downloads
      retry_count = 0
      temp_file = nil

      loop do
        begin
          temp_file = Tempfile.new(['manifest_file', File.extname(file['path'])])
          temp_file.binmode

          content = make_http_request(url)
          if content
            temp_file.write(content)
            temp_file.close
            break
          else
            temp_file.close
            temp_file.unlink
            temp_file = nil
          end
        rescue StandardError => e
          temp_file&.close
          temp_file&.unlink
          puts "Error downloading file (attempt #{retry_count + 1}/#{max_retries + 1}): #{e.message}"
        end

        retry_count += 1
        if retry_count > max_retries
          puts "Failed to download #{file['container']}/#{file['path']} after #{max_retries + 1} attempts"
          # Clean up any previously staged files
          staged_files.each { |f| File.unlink(f[:temp_file]) if File.exist?(f[:temp_file]) }
          return nil
        end

        sleep 2
      end

      staged_files << {
        temp_file: temp_file.path,
        path: file['path'],
        container: file['container'],
        actions: file['actions']
      }
    end

    staged_files
  end

  def make_http_request(url, max_retries: 2)
    uri = URI(url)
    retry_count = 0

    loop do
      begin
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'
        http.read_timeout = 30
        http.open_timeout = 10

        request = Net::HTTP::Get.new(uri.request_uri)
        response = http.request(request)

        case response.code
        when '200'
          return response.body
        when '401', '403'
          puts "Error: Authentication failed (HTTP #{response.code}). Check COLLECTOR_SECRET."
          return nil
        when '404'
          puts "Error: Endpoint not found (HTTP #{response.code}). URL: #{url}"
          return nil
        else
          raise "HTTP #{response.code}: #{response.message}"
        end
      rescue SocketError, Timeout::Error, Errno::ECONNREFUSED, Errno::ETIMEDOUT => e
        retry_count += 1
        if retry_count > max_retries
          puts "Error: Request failed after #{max_retries + 1} attempts: #{e.message}"
          return nil
        end
        puts "Request failed (attempt #{retry_count}/#{max_retries + 1}): #{e.message}. Retrying..."
        sleep 2
      rescue StandardError => e
        puts "Error making HTTP request: #{e.message}"
        return nil
      end
    end
  end
end
