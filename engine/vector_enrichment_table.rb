require 'digest'

# Checks whether the enrichment table has changed
# Returns a hash of the file if it exists, otherwise nil
# Used by enrichment_table_watcher.rb to reload vector if the enrichment table has changed
class VectorEnrichmentTable
  def check_for_changes(path = '/enrichment/docker-mappings.csv')
    directory = File.dirname(path)
    return nil unless File.exist?(directory) && File.directory?(directory)
    return nil unless File.exist?(path)

    calculate_file_hash(path)
  end

  private

  def calculate_file_hash(file_path)
    Digest::MD5.file(file_path).hexdigest
  end
end