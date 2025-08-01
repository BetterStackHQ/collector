require 'bundler/setup'
require 'minitest/autorun'
require 'tempfile'
require 'fileutils'
require_relative '../engine/vector_enrichment_table'

class VectorEnrichmentTableTest < Minitest::Test
  def setup
    @vector_enrichment_table = VectorEnrichmentTable.new
  end

  def test_tempfile_with_content_returns_non_nil_hash
    Dir.mktmpdir do |dir|
      file_path = File.join(dir, 'docker-mappings.csv')
      File.write(file_path, "container_id,service_name\n123456,web-service")
      
      result = @vector_enrichment_table.check_for_changes(file_path)
      refute_nil result
    end
  end

  def test_same_content_returns_same_hash
    Dir.mktmpdir do |dir|
      file_path = File.join(dir, 'docker-mappings.csv')
      File.write(file_path, "pid,container_name,container_id,image_name\n1234,name,deadbeefbad0,image")
      
      result1 = @vector_enrichment_table.check_for_changes(file_path)
      result2 = @vector_enrichment_table.check_for_changes(file_path)
      
      assert_equal result1, result2
    end
  end

  def test_different_content_returns_different_hash
    Dir.mktmpdir do |dir|
      file_path = File.join(dir, 'docker-mappings.csv')
      
      # First content
      File.write(file_path, "pid,container_name,container_id,image_name\n1234,name,deadbeefbad0,image")
      result1 = @vector_enrichment_table.check_for_changes(file_path)
      
      # Different content
      File.write(file_path, "pid,container_name,container_id,image_name\n1234,name,decafcoffee9,image")
      result2 = @vector_enrichment_table.check_for_changes(file_path)
      
      refute_nil result1
      refute_nil result2
      refute_equal result1, result2
    end
  end

  def test_imaginary_path_returns_nil
    result = @vector_enrichment_table.check_for_changes('/imaginary/path.csv')
    assert_nil result
  end

  def test_empty_directory_returns_nil
    Dir.mktmpdir do |dir|
      file_path = File.join(dir, 'docker-mappings.csv')
      # Directory exists but file doesn't
      result = @vector_enrichment_table.check_for_changes(file_path)
      assert_nil result
    end
  end
end