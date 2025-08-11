require 'bundler/setup'
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../engine/databases_enrichment_table'

class DatabasesEnrichmentTableTest < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.rm_rf(@temp_dir)
  end

  def test_different_returns_false_when_incoming_does_not_exist
    target_path = File.join(@temp_dir, 'databases.csv')
    incoming_path = File.join(@temp_dir, 'databases.incoming.csv')
    
    # Create target file
    File.write(target_path, "identifier,container,service,host\n")
    
    table = DatabasesEnrichmentTable.new(target_path, incoming_path)
    assert_equal false, table.different?
  end

  def test_different_returns_false_when_files_are_identical
    target_path = File.join(@temp_dir, 'databases.csv')
    incoming_path = File.join(@temp_dir, 'databases.incoming.csv')
    
    content = "identifier,container,service,host\ndb1,container1,service1,host1\n"
    File.write(target_path, content)
    File.write(incoming_path, content)
    
    table = DatabasesEnrichmentTable.new(target_path, incoming_path)
    assert_equal false, table.different?
  end

  def test_different_returns_true_when_files_differ
    target_path = File.join(@temp_dir, 'databases.csv')
    incoming_path = File.join(@temp_dir, 'databases.incoming.csv')
    
    File.write(target_path, "identifier,container,service,host\n")
    File.write(incoming_path, "identifier,container,service,host\ndb1,container1,service1,host1\n")
    
    table = DatabasesEnrichmentTable.new(target_path, incoming_path)
    assert_equal true, table.different?
  end

  def test_validate_returns_error_when_file_does_not_exist
    target_path = File.join(@temp_dir, 'databases.csv')
    incoming_path = File.join(@temp_dir, 'databases.incoming.csv')
    
    table = DatabasesEnrichmentTable.new(target_path, incoming_path)
    error = table.validate
    
    assert_match(/not found/, error)
  end

  def test_validate_returns_error_when_file_is_empty
    target_path = File.join(@temp_dir, 'databases.csv')
    incoming_path = File.join(@temp_dir, 'databases.incoming.csv')
    
    File.write(incoming_path, "")
    
    table = DatabasesEnrichmentTable.new(target_path, incoming_path)
    error = table.validate
    
    assert_match(/empty/, error)
  end

  def test_validate_returns_error_when_headers_are_incorrect
    target_path = File.join(@temp_dir, 'databases.csv')
    incoming_path = File.join(@temp_dir, 'databases.incoming.csv')
    
    # Wrong headers
    File.write(incoming_path, "id,name,type,location\n")
    
    table = DatabasesEnrichmentTable.new(target_path, incoming_path)
    error = table.validate
    
    assert_match(/invalid headers/, error)
    assert_match(/Expected: identifier,container,service,host/, error)
  end

  def test_validate_returns_error_when_headers_are_in_wrong_order
    target_path = File.join(@temp_dir, 'databases.csv')
    incoming_path = File.join(@temp_dir, 'databases.incoming.csv')
    
    # Headers in wrong order
    File.write(incoming_path, "container,identifier,service,host\n")
    
    table = DatabasesEnrichmentTable.new(target_path, incoming_path)
    error = table.validate
    
    assert_match(/invalid headers/, error)
  end

  def test_validate_returns_nil_when_file_is_valid
    target_path = File.join(@temp_dir, 'databases.csv')
    incoming_path = File.join(@temp_dir, 'databases.incoming.csv')
    
    File.write(incoming_path, "identifier,container,service,host\ndb1,container1,service1,host1\n")
    
    table = DatabasesEnrichmentTable.new(target_path, incoming_path)
    error = table.validate
    
    assert_nil error
  end

  def test_validate_returns_nil_when_file_has_only_headers
    target_path = File.join(@temp_dir, 'databases.csv')
    incoming_path = File.join(@temp_dir, 'databases.incoming.csv')
    
    # Just headers, no data rows - this should be valid
    File.write(incoming_path, "identifier,container,service,host\n")
    
    table = DatabasesEnrichmentTable.new(target_path, incoming_path)
    error = table.validate
    
    assert_nil error
  end

  def test_validate_returns_error_for_malformed_csv
    target_path = File.join(@temp_dir, 'databases.csv')
    incoming_path = File.join(@temp_dir, 'databases.incoming.csv')
    
    # Malformed CSV with unclosed quote
    File.write(incoming_path, "identifier,container,service,host\n\"db1,container1,service1,host1\n")
    
    table = DatabasesEnrichmentTable.new(target_path, incoming_path)
    error = table.validate
    
    assert_match(/malformed/, error)
  end

  def test_promote_moves_file_from_incoming_to_target
    target_path = File.join(@temp_dir, 'databases.csv')
    incoming_path = File.join(@temp_dir, 'databases.incoming.csv')
    
    content = "identifier,container,service,host\ndb1,container1,service1,host1\n"
    File.write(incoming_path, content)
    
    table = DatabasesEnrichmentTable.new(target_path, incoming_path)
    table.promote
    
    assert File.exist?(target_path)
    assert !File.exist?(incoming_path)
    assert_equal content, File.read(target_path)
  end

  def test_promote_overwrites_existing_target_file
    target_path = File.join(@temp_dir, 'databases.csv')
    incoming_path = File.join(@temp_dir, 'databases.incoming.csv')
    
    old_content = "identifier,container,service,host\nold,old,old,old\n"
    new_content = "identifier,container,service,host\nnew,new,new,new\n"
    
    File.write(target_path, old_content)
    File.write(incoming_path, new_content)
    
    table = DatabasesEnrichmentTable.new(target_path, incoming_path)
    table.promote
    
    assert File.exist?(target_path)
    assert !File.exist?(incoming_path)
    assert_equal new_content, File.read(target_path)
  end
end
