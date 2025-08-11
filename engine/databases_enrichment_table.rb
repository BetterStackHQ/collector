require 'digest'
require 'csv'

class DatabasesEnrichmentTable
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
    puts "Validating databases enrichment table at #{incoming_path}"

    if !File.exist?(incoming_path)
      puts "Databases enrichment table not found at #{incoming_path}"
      return "Databases enrichment table not found at #{incoming_path}"
    end

    if File.size(incoming_path) == 0
      puts "Databases enrichment table is empty at #{incoming_path}"
      return "Databases enrichment table is empty at #{incoming_path}"
    end

    begin
      csv_content = CSV.read(incoming_path, headers: true)
      expected_headers = ["identifier", "container", "service", "host"]
      
      if csv_content.headers != expected_headers
        actual_headers = csv_content.headers ? csv_content.headers.join(",") : "none"
        puts "Databases enrichment table has invalid headers. Expected: #{expected_headers.join(",")}, Got: #{actual_headers}"
        return "Databases enrichment table has invalid headers. Expected: #{expected_headers.join(",")}, Got: #{actual_headers}"
      end
    rescue CSV::MalformedCSVError => e
      puts "Databases enrichment table is malformed: #{e.message}"
      return "Databases enrichment table is malformed: #{e.message}"
    end

    nil
  end

  def promote
    FileUtils.mv(incoming_path, target_path)
  end

  private

  def calculate_file_hash(file_path)
    return nil unless File.exist?(file_path)
    Digest::MD5.file(file_path).hexdigest
  end
end
