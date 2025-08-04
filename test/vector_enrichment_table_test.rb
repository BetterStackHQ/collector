require 'bundler/setup'
require 'minitest/autorun'
require 'tempfile'
require 'fileutils'
require_relative '../engine/vector_enrichment_table'

class VectorEnrichmentTableTest < Minitest::Test
  def test_first_run_returns_true
    Dir.mktmpdir do |dir|
      file_path = File.join(dir, 'docker-mappings.csv')
      File.write(file_path, "container_id,service_name\n123456,web-service")
      assert VectorEnrichmentTable.new(file_path).different?
    end
  end

  def test_same_content_returns_false
    Dir.mktmpdir do |dir|
      file_path = File.join(dir, 'docker-mappings.csv')
      File.write(file_path, "pid,container_name,container_id,image_name\n1234,name,deadbeefbad0,image")

      vector_config = VectorEnrichmentTable.new(file_path)
      
      result1 = vector_config.different?
      result2 = vector_config.different?
      
      assert result1 # first run fills @last_hash and returns true
      refute result2 # second run returns false because @last_hash is set and content is the same
    end
  end

  def test_different_content_returns_different_hash
    Dir.mktmpdir do |dir|
      file_path = File.join(dir, 'docker-mappings.csv')
      vector_config = VectorEnrichmentTable.new(file_path)
      
      # First content
      File.write(file_path, "pid,container_name,container_id,image_name\n1234,name,deadbeefbad0,image")
      result1 = vector_config.different? # true, @last_hash not set
      
      # Different content
      File.write(file_path, "pid,container_name,container_id,image_name\n1234,name,decafcoffee9,image")
      result2 = vector_config.different? # true, @last_hash is set and content is different
      
      assert result1 # first run fills @last_hash and returns true
      assert result2 # second run returns true because @last_hash is set and content is different
    end
  end

  def test_imaginary_path_returns_nil
    result = VectorEnrichmentTable.new('/imaginary/path.csv').different?
    refute result # returns false because the file doesn't exist
  end

  def test_empty_directory_returns_nil
    Dir.mktmpdir do |dir|
      file_path = File.join(dir, 'docker-mappings.csv')
      # Directory exists but file doesn't
      result = VectorEnrichmentTable.new(file_path).different?
      refute result # returns false because the file doesn't exist
    end
  end

  def test_validate_enrichment_table_file_not_found
    Dir.mktmpdir do |dir|
      enrichment_path = File.join(dir, 'enrichment_table.csv')
      result = VectorEnrichmentTable.new(enrichment_path).validate_enrichment_table
      assert_equal "Enrichment table not found at #{enrichment_path}", result
    end
  end

  def test_validate_enrichment_table_empty_file
    Dir.mktmpdir do |dir|
      enrichment_path = File.join(dir, 'enrichment_table.csv')
      File.write(enrichment_path, '')

      result = VectorEnrichmentTable.new(enrichment_path).validate_enrichment_table
      assert_equal "Enrichment table is empty at #{enrichment_path}", result
    end
  end

  def test_validate_enrichment_table_invalid_header
    Dir.mktmpdir do |dir|
      enrichment_path = File.join(dir, 'enrichment_table.csv')
      File.write(enrichment_path, "wrong,header,format\n")
      
      result = VectorEnrichmentTable.new(enrichment_path).validate_enrichment_table
      assert_equal "Enrichment table is not valid at #{enrichment_path}", result
    end
  end

  def test_validate_enrichment_table_valid_file
    Dir.mktmpdir do |dir|
      enrichment_path = File.join(dir, 'enrichment_table.csv')
      File.write(enrichment_path, "pid,container_name,container_id,image_name\n123,test-container,abc123,test-image\n")
      
      result = VectorEnrichmentTable.new(enrichment_path).validate_enrichment_table
      assert_nil result
    end
  end

  def test_validate_enrichment_table_with_whitespace_header
    Dir.mktmpdir do |dir|
      enrichment_path = File.join(dir, 'enrichment_table.csv')
      File.write(enrichment_path, "  pid,container_name,container_id,image_name  \n123,test-container,abc123,test-image\n")
      
      result = VectorEnrichmentTable.new(enrichment_path).validate_enrichment_table
      assert_nil result
    end
  end

  def test_validate_enrichment_table_with_only_header
    Dir.mktmpdir do |dir|
      enrichment_path = File.join(dir, 'enrichment_table.csv')
      File.write(enrichment_path, "pid,container_name,container_id,image_name\n")
      
      result = VectorEnrichmentTable.new(enrichment_path).validate_enrichment_table
      assert_nil result
    end
  end

  def test_validate_enrichment_table_with_extra_columns_in_header
    Dir.mktmpdir do |dir|
      enrichment_path = File.join(dir, 'enrichment_table.csv')
      File.write(enrichment_path, "pid,container_name,container_id,image_name,extra\n")
      
      result = VectorEnrichmentTable.new(enrichment_path).validate_enrichment_table
      assert_equal "Enrichment table is not valid at #{enrichment_path}", result
    end
  end

  def test_validate_enrichment_table_with_missing_columns_in_header
    Dir.mktmpdir do |dir|
      enrichment_path = File.join(dir, 'enrichment_table.csv')
      File.write(enrichment_path, "pid,container_name,container_id\n")
      
      result = VectorEnrichmentTable.new(enrichment_path).validate_enrichment_table
      assert_equal "Enrichment table is not valid at #{enrichment_path}", result
    end
  end
end
