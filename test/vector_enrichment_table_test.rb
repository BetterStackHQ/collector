require 'bundler/setup'
require 'minitest/autorun'
require 'tempfile'
require 'fileutils'
require_relative '../engine/vector_enrichment_table'

class VectorEnrichmentTableTest < Minitest::Test
  def test_same_content_returns_false
    Dir.mktmpdir do |dir|
      target_path = File.join(dir, 'docker-mappings.csv')
      incoming_path = File.join(dir, 'docker-mappings.incoming.csv')
      File.write(target_path, "pid,container_name,container_id,image_name\n1234,name,deadbeefbad0,image")
      File.write(incoming_path, "pid,container_name,container_id,image_name\n1234,name,deadbeefbad0,image")

      enrichment_table = VectorEnrichmentTable.new(target_path, incoming_path)
      
      refute enrichment_table.different?
    end
  end

  def test_different_content_returns_different_hash
    Dir.mktmpdir do |dir|
      target_path = File.join(dir, 'docker-mappings.csv')
      incoming_path = File.join(dir, 'docker-mappings.incoming.csv')
      enrichment_table = VectorEnrichmentTable.new(target_path, incoming_path)

      File.write(target_path, "pid,container_name,container_id,image_name\n1234,name,deadbeefbad0,image")
      File.write(incoming_path, "pid,container_name,container_id,image_name\n1234,name,decafcoffee9,image")
      
      assert enrichment_table.different?
    end
  end

  def test_imaginary_path_returns_nil
    result = VectorEnrichmentTable.new('/imaginary/path.csv', '/imaginary/path.incoming.csv').different?
    refute result
  end

  def test_empty_directory_returns_nil
    Dir.mktmpdir do |dir|
      target_path = File.join(dir, 'docker-mappings.csv')
      incoming_path = File.join(dir, 'docker-mappings.incoming.csv')
      enrichment_table = VectorEnrichmentTable.new(target_path, incoming_path)

      refute enrichment_table.different?
    end
  end

  def test_validate_file_not_found
    Dir.mktmpdir do |dir|
      target_path = File.join(dir, 'docker-mappings.csv')
      incoming_path = File.join(dir, 'docker-mappings.incoming.csv')
      enrichment_table = VectorEnrichmentTable.new(target_path, incoming_path)

      assert_equal "Enrichment table not found at #{incoming_path}", enrichment_table.validate
    end
  end

  def test_validate_empty_file
    Dir.mktmpdir do |dir|
      target_path = File.join(dir, 'docker-mappings.csv')
      incoming_path = File.join(dir, 'docker-mappings.incoming.csv')
      enrichment_table = VectorEnrichmentTable.new(target_path, incoming_path)

      File.write(incoming_path, '')

      result = enrichment_table.validate
      assert_equal "Enrichment table is empty at #{incoming_path}", result
    end
  end

  def test_validate_invalid_header
    Dir.mktmpdir do |dir|
      target_path = File.join(dir, 'docker-mappings.csv')
      incoming_path = File.join(dir, 'docker-mappings.incoming.csv')
      enrichment_table = VectorEnrichmentTable.new(target_path, incoming_path)

      File.write(incoming_path, "wrong,header,format\n")
      
      result = enrichment_table.validate
      assert_equal "Enrichment table is not valid at #{incoming_path}", result
    end
  end

  def test_validate_valid_file
    Dir.mktmpdir do |dir|
      target_path = File.join(dir, 'docker-mappings.csv')
      incoming_path = File.join(dir, 'docker-mappings.incoming.csv')
      enrichment_table = VectorEnrichmentTable.new(target_path, incoming_path)

      File.write(incoming_path, "pid,container_name,container_id,image_name\n123,test-container,abc123,test-image\n")
      
      result = enrichment_table.validate
      assert_nil result
    end
  end

  def test_validate_with_whitespace_header
    Dir.mktmpdir do |dir|
      target_path = File.join(dir, 'docker-mappings.csv')
      incoming_path = File.join(dir, 'docker-mappings.incoming.csv')
      enrichment_table = VectorEnrichmentTable.new(target_path, incoming_path)

      File.write(incoming_path, "  pid,container_name,container_id,image_name  \n123,test-container,abc123,test-image\n")
      
      result = enrichment_table.validate
      assert_nil result
    end
  end

  def test_validate_with_only_header
    Dir.mktmpdir do |dir|
      target_path = File.join(dir, 'docker-mappings.csv')
      incoming_path = File.join(dir, 'docker-mappings.incoming.csv')
      enrichment_table = VectorEnrichmentTable.new(target_path, incoming_path)

      File.write(incoming_path, "pid,container_name,container_id,image_name\n")
      
      result = enrichment_table.validate
      assert_nil result
    end
  end

  def test_validate_with_extra_columns_in_header
    Dir.mktmpdir do |dir|
      target_path = File.join(dir, 'docker-mappings.csv')
      incoming_path = File.join(dir, 'docker-mappings.incoming.csv')
      enrichment_table = VectorEnrichmentTable.new(target_path, incoming_path)

      File.write(incoming_path, "pid,container_name,container_id,image_name,extra\n")
      
      result = enrichment_table.validate
      assert_equal "Enrichment table is not valid at #{incoming_path}", result
    end
  end

  def test_validate_with_missing_columns_in_header
    Dir.mktmpdir do |dir|
      target_path = File.join(dir, 'docker-mappings.csv')
      incoming_path = File.join(dir, 'docker-mappings.incoming.csv')
      enrichment_table = VectorEnrichmentTable.new(target_path, incoming_path)

      File.write(incoming_path, "pid,container_name,container_id\n")
      
      result = enrichment_table.validate
      assert_equal "Enrichment table is not valid at #{incoming_path}", result
    end
  end

  def test_promote
    Dir.mktmpdir do |dir|
      target_path = File.join(dir, 'docker-mappings.csv')
      incoming_path = File.join(dir, 'docker-mappings.incoming.csv')
      content = "pid,container_name,container_id,image_name\n123,test-container,abc123,test-image\n"
      File.write(incoming_path, content)
      enrichment_table = VectorEnrichmentTable.new(target_path, incoming_path)

      enrichment_table.promote

      assert File.exist?(target_path)
      assert_equal content, File.read(target_path)
      assert !File.exist?(incoming_path)
    end
  end
end
