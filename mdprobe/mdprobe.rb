#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'logger'

# Load all metadata providers
Dir[File.join(__dir__, 'providers', '*.rb')].each { |file| require file }

# Main class for cloud metadata detection
class Mdprobe
  METADATA_SERVICE_TIMEOUT = 5  # seconds

  def initialize
    @logger = Logger.new(STDERR)
    @logger.level = ENV['DEBUG'] ? Logger::DEBUG : Logger::WARN
    @logger.formatter = proc { |severity, datetime, _, msg| "#{datetime.strftime('%Y-%m-%d %H:%M:%S')} [#{severity}] #{msg}\n" }
  end

  def run
    metadata = get_instance_metadata

    if metadata.nil?
      puts '{}'
    else
      # Only output Region and AvailabilityZone
      output = {
        Region: metadata[:region] || 'unknown',
        AvailabilityZone: metadata[:availability_zone] || 'unknown'
      }
      puts output.to_json
    end
  rescue => e
    @logger.error "Failed to get instance metadata: #{e.message}"
    @logger.debug e.backtrace.join("\n") if ENV['DEBUG']
    puts '{}'
  end

  private

  def get_instance_metadata
    provider = detect_cloud_provider
    @logger.info "Detected cloud provider: #{provider || 'unknown'}"

    return nil unless provider

    # Instantiate the appropriate provider class
    provider_class = case provider
    when :aws
      Providers::AWS
    when :gcp
      Providers::GCP
    when :azure
      Providers::Azure
    when :digital_ocean
      Providers::DigitalOcean
    when :hetzner
      Providers::Hetzner
    when :alibaba
      Providers::Alibaba
    when :scaleway
      Providers::Scaleway
    when :ibm
      Providers::IBM
    when :oracle
      Providers::Oracle
    else
      return nil
    end

    return if provider_class.nil?
    provider_instance = provider_class.new(@logger)
    metadata = provider_instance.fetch_metadata

    # Apply Azure-specific zone modification if needed
    if provider == :azure && metadata && metadata[:availability_zone] =~ /^\d+$/
      metadata[:availability_zone] = "#{metadata[:region]}-#{metadata[:availability_zone]}"
    end

    metadata
  end

  def detect_cloud_provider
    # Check AWS Xen instances
    if File.exist?('/sys/hypervisor/uuid')
      uuid = File.read('/sys/hypervisor/uuid').strip.downcase rescue ''
      return :aws if uuid.start_with?('ec2')
    end

    # Check board vendor
    if File.exist?('/sys/class/dmi/id/board_vendor')
      vendor = File.read('/sys/class/dmi/id/board_vendor').strip rescue ''
      case vendor
      when 'Amazon EC2'
        return :aws
      when 'Google'
        return :gcp
      when 'Microsoft Corporation'
        return :azure
      when 'DigitalOcean'
        return :digital_ocean
      end
    end

    # Check sys vendor
    if File.exist?('/sys/class/dmi/id/sys_vendor')
      vendor = File.read('/sys/class/dmi/id/sys_vendor').strip rescue ''
      case vendor
      when 'Hetzner'
        return :hetzner
      when 'Alibaba Cloud'
        return :alibaba
      when 'Scaleway'
        return :scaleway
      end
    end

    # Check chassis vendor for IBM
    if File.exist?('/sys/class/dmi/id/chassis_vendor')
      vendor = File.read('/sys/class/dmi/id/chassis_vendor').strip rescue ''
      return :ibm if vendor.start_with?('IBM:Cloud Compute Server')
    end

    # Check chassis asset tag for Oracle
    if File.exist?('/sys/class/dmi/id/chassis_asset_tag')
      tag = File.read('/sys/class/dmi/id/chassis_asset_tag').strip rescue ''
      return :oracle if tag == 'OracleCloud.com'
    end

    nil
  end
end

# Run if executed directly
if __FILE__ == $0
  Mdprobe.new.run
end
