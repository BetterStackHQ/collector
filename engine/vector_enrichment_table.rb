require 'digest'

# Checks whether the enrichment table has changed
# Returns a hash of the file if it exists, otherwise nil
# Used by enrichment_table_watcher.rb to reload vector if the enrichment table has changed
class VectorEnrichmentTable
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
    puts "Validating enrichment table at #{incoming_path}"

    if !File.exist?(incoming_path)
      puts "Enrichment table not found at #{incoming_path}"
      return "Enrichment table not found at #{incoming_path}"
    end

    if File.size(incoming_path) == 0
      puts "Enrichment table is empty at #{incoming_path}"
      return "Enrichment table is empty at #{incoming_path}"
    end

    if File.readlines(incoming_path).first.strip != "pid,container_name,container_id,image_name"
      puts "Enrichment table is not valid at #{incoming_path}"
      return "Enrichment table is not valid at #{incoming_path}"
    end

    nil
  end

  def promote
    FileUtils.mv(incoming_path, target_path)
  end

  private

  attr_reader :target_path, :incoming_path

  def calculate_file_hash(file_path)
    Digest::MD5.file(file_path).hexdigest
  end
end
