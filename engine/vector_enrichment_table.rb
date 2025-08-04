require 'digest'

# Checks whether the enrichment table has changed
# Returns a hash of the file if it exists, otherwise nil
# Used by enrichment_table_watcher.rb to reload vector if the enrichment table has changed
class VectorEnrichmentTable
  def initialize(path)
    @path = path
    @last_hash = nil
  end

  def different?
    directory = File.dirname(path)
    return false unless File.exist?(directory) && File.directory?(directory)
    return false unless File.exist?(path)

    new_hash = calculate_file_hash(path)
    if @last_hash.nil?
      @last_hash = new_hash
      return true
    end

    @last_hash != new_hash
  end

  def validate
    puts "Validating enrichment table at #{path}"

    if !File.exist?(path)
      puts "Enrichment table not found at #{path}"
      return "Enrichment table not found at #{path}"
    end

    if File.size(path) == 0
      puts "Enrichment table is empty at #{path}"
      return "Enrichment table is empty at #{path}"
    end

    if File.readlines(path).first.strip != "pid,container_name,container_id,image_name"
      puts "Enrichment table is not valid at #{path}"
      return "Enrichment table is not valid at #{path}"
    end

    nil
  end

  private
  
  attr_reader :path

  def calculate_file_hash(file_path)
    Digest::MD5.file(file_path).hexdigest
  end
end
