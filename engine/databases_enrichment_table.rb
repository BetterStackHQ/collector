require_relative 'base_enrichment_table'
require 'csv'

class DatabasesEnrichmentTable < BaseEnrichmentTable
  protected

  def table_name
    "Databases enrichment table"
  end

  def validate_headers
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
end