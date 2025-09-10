#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'tempfile'
require 'fileutils'
require 'stringio'
require_relative '../mdprobe'

class TestMdprobe < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    @mdprobe = Mdprobe.new
    # Silence logger for tests
    @mdprobe.instance_variable_set(:@logger, Logger.new(nil))
    # Store original methods for restoration
    @original_file_exist = File.method(:exist?)
    @original_file_read = File.method(:read)
  end

  def teardown
    FileUtils.rm_rf(@temp_dir)
    # Restore original File methods
    File.define_singleton_method(:exist?, @original_file_exist)
    File.define_singleton_method(:read, @original_file_read)
  end

  def test_output_format_with_provider
    # Test that output only contains Region and AvailabilityZone
    mock_file('/sys/class/dmi/id/board_vendor', 'Amazon EC2') do
      # Mock AWS provider to return test data
      mock_provider = Minitest::Mock.new
      mock_provider.expect(:fetch_metadata, {
        region: 'us-east-1',
        availability_zone: 'us-east-1a'
      })
      
      Providers::AWS.stub(:new, mock_provider) do
        output = capture_stdout { @mdprobe.run }
        data = JSON.parse(output)
        
        assert_equal 'us-east-1', data['Region']
        assert_equal 'us-east-1a', data['AvailabilityZone']
        # Ensure no other fields are present
        assert_equal 2, data.keys.size
      end
      
      mock_provider.verify
    end
  end

  def test_output_format_no_provider
    # No cloud provider detected
    output = capture_stdout { @mdprobe.run }
    assert_equal "{}\n", output
  end

  def test_azure_zone_modification
    # Test Azure-specific zone modification for numeric zones
    mock_file('/sys/class/dmi/id/board_vendor', 'Microsoft Corporation') do
      # Mock Azure provider to return numeric zone
      mock_provider = Minitest::Mock.new
      mock_provider.expect(:fetch_metadata, {
        region: 'eastus',
        availability_zone: '2'
      })
      
      Providers::Azure.stub(:new, mock_provider) do
        output = capture_stdout { @mdprobe.run }
        data = JSON.parse(output)
        
        assert_equal 'eastus', data['Region']
        assert_equal 'eastus-2', data['AvailabilityZone']
      end
      
      mock_provider.verify
    end
  end

  def test_unknown_values_when_nil
    # Test that nil values become 'unknown'
    mock_file('/sys/class/dmi/id/board_vendor', 'Google') do
      mock_provider = Minitest::Mock.new
      mock_provider.expect(:fetch_metadata, {
        region: nil,
        availability_zone: nil
      })
      
      Providers::GCP.stub(:new, mock_provider) do
        output = capture_stdout { @mdprobe.run }
        data = JSON.parse(output)
        
        assert_equal 'unknown', data['Region']
        assert_equal 'unknown', data['AvailabilityZone']
      end
      
      mock_provider.verify
    end
  end

  private

  def mock_file(path, content, &block)
    # Stub File.exist? to return true for our mocked path
    original_exist = File.method(:exist?)
    File.define_singleton_method(:exist?) do |p|
      p == path || original_exist.call(p)
    end
    
    # Stub File.read to return our content for the mocked path
    original_read = File.method(:read)
    File.define_singleton_method(:read) do |p|
      if p == path
        content
      else
        begin
          original_read.call(p)
        rescue
          ''
        end
      end
    end
    
    result = block.call
    
    # Restore original methods
    File.define_singleton_method(:exist?, original_exist)
    File.define_singleton_method(:read, original_read)
    
    result
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end
end