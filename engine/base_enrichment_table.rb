require 'digest'
require 'fileutils'

class BaseEnrichmentTable
  attr_reader :target_path, :incoming_path

  def initialize(target_path, incoming_path)
    @target_path = target_path
    @incoming_path = incoming_path
  end

  def different?
    directory = File.dirname(incoming_path)
    return false unless File.exist?(directory) && File.directory?(directory)
    return false unless File.exist?(incoming_path)

    current_hash = calculate_file_hash(target_path)
    new_hash = calculate_file_hash(incoming_path)

    current_hash != new_hash
  end

  def validate
    puts "Validating #{table_name} at #{incoming_path}"

    if !File.exist?(incoming_path)
      puts "#{table_name} not found at #{incoming_path}"
      return "#{table_name} not found at #{incoming_path}"
    end

    if File.size(incoming_path) == 0
      puts "#{table_name} is empty at #{incoming_path}"
      return "#{table_name} is empty at #{incoming_path}"
    end

    validate_headers
  end

  def promote
    FileUtils.mv(incoming_path, target_path)
  end

  protected

  # Subclasses must implement these methods
  def table_name
    raise NotImplementedError, "Subclasses must implement table_name"
  end

  def validate_headers
    raise NotImplementedError, "Subclasses must implement validate_headers"
  end

  private

  def calculate_file_hash(file_path)
    return nil unless File.exist?(file_path)
    Digest::MD5.file(file_path).hexdigest
  end
end