require 'fileutils'

class SSLCertificateManager
  DOMAIN_FILE = '/etc/ssl_certificate_host.txt'

  def initialize(working_dir = nil)
    @working_dir = working_dir
    @domain_file = working_dir ? File.join(working_dir, 'ssl_certificate_host.txt') : DOMAIN_FILE
    @previous_domain = nil
    @domain_just_changed = false
  end

  attr_reader :domain_file, :domain_just_changed

  # Process an incoming SSL certificate host configuration
  # Returns true if domain changed, false otherwise
  def process_ssl_certificate_host(domain_string)
    domain_string = domain_string.to_s.strip
    current_domain = read_current_domain

    # Check if domain has changed
    if current_domain != domain_string
      write_domain(domain_string)
      @previous_domain = current_domain
      @domain_just_changed = true

      # If domain changed and is non-empty, restart certbot
      if !domain_string.empty?
        restart_certbot
      end

      return true
    end

    # Domain hasn't changed
    @domain_just_changed = false
    false
  end

  # Check if we should skip vector validation due to pending certificate
  def should_skip_validation?
    return false unless @domain_just_changed

    current_domain = read_current_domain
    return false if current_domain.empty?

    # Skip validation if certificate doesn't exist yet
    !certificate_exists?(current_domain)
  end

  # Reset the "just changed" flag after a ping cycle
  def reset_change_flag
    @domain_just_changed = false
  end

  # Check if a certificate exists for the given domain
  def certificate_exists?(domain = nil)
    domain ||= read_current_domain
    return false if domain.empty?

    cert_path = "/etc/ssl/#{domain}.pem"
    key_path = "/etc/ssl/#{domain}.key"

    File.exist?(cert_path) && File.exist?(key_path)
  end

  # Read the current domain from file
  def read_current_domain
    return '' unless File.exist?(@domain_file)
    File.read(@domain_file).strip
  rescue => e
    puts "Error reading SSL certificate host file: #{e.message}"
    ''
  end

  private

  # Write domain to the well-known location
  def write_domain(domain_string)
    FileUtils.mkdir_p(File.dirname(@domain_file))
    File.write(@domain_file, domain_string)
    puts "Updated SSL certificate host: #{domain_string.empty? ? '(empty)' : domain_string}"
  rescue => e
    puts "Error writing SSL certificate host file: #{e.message}"
    raise
  end

  # Restart certbot via supervisorctl
  def restart_certbot
    puts "Restarting certbot to handle domain change..."
    result = system('supervisorctl -c /etc/supervisor/conf.d/supervisord.conf restart certbot')
    if result
      puts "Certbot restarted successfully"
    else
      puts "Warning: Failed to restart certbot"
    end
    result
  rescue => e
    puts "Error restarting certbot: #{e.message}"
    false
  end
end
