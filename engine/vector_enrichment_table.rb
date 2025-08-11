require_relative 'base_enrichment_table'

# Checks whether the enrichment table has changed
# Returns a hash of the file if it exists, otherwise nil
# Used by enrichment_table_watcher.rb to reload vector if the enrichment table has changed
class VectorEnrichmentTable < BaseEnrichmentTable
  protected

  def table_name
    "Enrichment table"
  end

  def validate_headers
    if File.readlines(incoming_path).first.strip != "pid,container_name,container_id,image_name"
      puts "Enrichment table is not valid at #{incoming_path}"
      return "Enrichment table is not valid at #{incoming_path}"
    end

    nil
  end
end