require_relative 'base_enrichment_table'

# Checks whether the containers enrichment table has changed
# Returns a hash of the file if it exists, otherwise nil
# Used by enrichment_table_watcher.rb to reload vector if the enrichment table has changed
class ContainersEnrichmentTable < BaseEnrichmentTable
  protected

  def table_name
    "Containers enrichment table"
  end

  def validate_headers
    if File.readlines(incoming_path).first.strip != "pid,container_name,container_id,image_name"
      puts "Containers enrichment table is not valid at #{incoming_path}"
      return "Containers enrichment table is not valid at #{incoming_path}"
    end

    nil
  end
end