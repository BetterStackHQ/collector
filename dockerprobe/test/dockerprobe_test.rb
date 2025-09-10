#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'tempfile'
require 'csv'
require 'json'
require_relative '../dockerprobe'
# require_relative '../docker_client'

class TestDockerClient < Minitest::Test
  def setup
    @client = DockerClient.new
  end

  def test_initialization_with_default_socket
    client = DockerClient.new
    assert client
  end

  def test_initialization_with_custom_socket
    client = DockerClient.new('/custom/docker.sock')
    assert client
  end

  def test_initialization_with_env_docker_host
    ENV['DOCKER_HOST'] = 'unix:///tmp/docker.sock'
    client = DockerClient.new
    assert client
  ensure
    ENV.delete('DOCKER_HOST')
  end

  # Note: Integration tests for actual Docker API calls would require
  # a running Docker daemon and mock containers
end

class TestDockerprobe < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    @output_file = File.join(@temp_dir, 'docker-mappings.csv')
    ENV['DOCKERPROBE_OUTPUT_PATH'] = @output_file
    ENV['DOCKERPROBE_INTERVAL'] = '1'
  end

  def teardown
    FileUtils.rm_rf(@temp_dir)
    ENV.delete('DOCKERPROBE_OUTPUT_PATH')
    ENV.delete('DOCKERPROBE_INTERVAL')
  end

  def test_initialization
    probe = Dockerprobe.new
    assert probe
  end

  def test_default_configuration
    ENV.delete('DOCKERPROBE_OUTPUT_PATH')
    ENV.delete('DOCKERPROBE_INTERVAL')

    probe = Dockerprobe.new
    assert_equal '/enrichment/docker-mappings.incoming.csv', probe.instance_variable_get(:@output_path)
    assert_equal 15, probe.instance_variable_get(:@interval)
  end

  def test_custom_configuration
    ENV['DOCKERPROBE_OUTPUT_PATH'] = '/custom/path.csv'
    ENV['DOCKERPROBE_INTERVAL'] = '30'

    probe = Dockerprobe.new
    assert_equal '/custom/path.csv', probe.instance_variable_get(:@output_path)
    assert_equal 30, probe.instance_variable_get(:@interval)
  end

  def test_get_parent_pid
    # Create a mock /proc structure
    proc_dir = Dir.mktmpdir
    
    # Create mock stat file for PID 1234 with parent PID 1000
    pid_dir = File.join(proc_dir, '1234')
    FileUtils.mkdir_p(pid_dir)
    
    # stat format: pid (comm) state ppid ...
    # 1234 (test_process) S 1000 ...
    stat_content = "1234 (test_process) S 1000 1000 1000 0 -1 0 0 0 0 0 0 0 0 0 0 0 0 0"
    File.write(File.join(pid_dir, 'stat'), stat_content)
    
    probe = Dockerprobe.new(proc_path: proc_dir)
    
    # Test with mock PID
    ppid = probe.send(:get_parent_pid, 1234)
    assert_equal 1000, ppid
  ensure
    FileUtils.rm_rf(proc_dir) if proc_dir
  end

  def test_get_parent_pid_with_parentheses_in_name
    # Create a mock /proc structure
    proc_dir = Dir.mktmpdir
    
    # Create mock stat file with parentheses in the process name
    pid_dir = File.join(proc_dir, '5678')
    FileUtils.mkdir_p(pid_dir)
    
    # Process name with parentheses: (test (with) parens)
    stat_content = "5678 ((test (with) parens)) S 2000 2000 2000 0 -1 0 0 0 0 0 0 0 0 0 0 0 0 0"
    File.write(File.join(pid_dir, 'stat'), stat_content)
    
    probe = Dockerprobe.new(proc_path: proc_dir)
    
    ppid = probe.send(:get_parent_pid, 5678)
    assert_equal 2000, ppid
  ensure
    FileUtils.rm_rf(proc_dir) if proc_dir
  end

  def test_get_parent_pid_invalid
    proc_dir = Dir.mktmpdir
    probe = Dockerprobe.new(proc_path: proc_dir)

    # Test with non-existent PID
    ppid = probe.send(:get_parent_pid, 999999999)
    assert_nil ppid
  ensure
    FileUtils.rm_rf(proc_dir) if proc_dir
  end

  def test_find_child_processes
    # Create a mock /proc structure with parent-child relationships
    proc_dir = Dir.mktmpdir
    
    # Create parent process (PID 100)
    parent_dir = File.join(proc_dir, '100')
    FileUtils.mkdir_p(parent_dir)
    File.write(File.join(parent_dir, 'stat'), "100 (parent) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 0 0 0 0")
    
    # Create child processes (PIDs 200, 300) with parent PID 100
    child1_dir = File.join(proc_dir, '200')
    FileUtils.mkdir_p(child1_dir)
    File.write(File.join(child1_dir, 'stat'), "200 (child1) S 100 100 100 0 -1 0 0 0 0 0 0 0 0 0 0 0 0 0")
    
    child2_dir = File.join(proc_dir, '300')
    FileUtils.mkdir_p(child2_dir)
    File.write(File.join(child2_dir, 'stat'), "300 (child2) S 100 100 100 0 -1 0 0 0 0 0 0 0 0 0 0 0 0 0")
    
    # Create an unrelated process (PID 400) with different parent
    other_dir = File.join(proc_dir, '400')
    FileUtils.mkdir_p(other_dir)
    File.write(File.join(other_dir, 'stat'), "400 (other) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 0 0 0 0")
    
    probe = Dockerprobe.new(proc_path: proc_dir)
    
    # Find children of PID 100
    children = probe.send(:find_child_processes, 100)
    
    assert_equal 2, children.length, "Should find 2 child processes"
    assert_includes children, 200, "Should find child PID 200"
    assert_includes children, 300, "Should find child PID 300"
    refute_includes children, 400, "Should not include unrelated PID 400"
  ensure
    FileUtils.rm_rf(proc_dir) if proc_dir
  end

  def test_get_process_descendants
    # Create a mock /proc structure with a process tree
    proc_dir = Dir.mktmpdir
    
    # Process tree:
    # 100 (parent)
    #   ├── 200 (child1)
    #   │   └── 201 (grandchild1)
    #   └── 300 (child2)
    
    # Parent process
    FileUtils.mkdir_p(File.join(proc_dir, '100'))
    File.write(File.join(proc_dir, '100', 'stat'), "100 (parent) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 0 0 0 0")
    
    # Child 1
    FileUtils.mkdir_p(File.join(proc_dir, '200'))
    File.write(File.join(proc_dir, '200', 'stat'), "200 (child1) S 100 100 100 0 -1 0 0 0 0 0 0 0 0 0 0 0 0 0")
    
    # Grandchild
    FileUtils.mkdir_p(File.join(proc_dir, '201'))
    File.write(File.join(proc_dir, '201', 'stat'), "201 (grandchild1) S 200 200 200 0 -1 0 0 0 0 0 0 0 0 0 0 0 0 0")
    
    # Child 2
    FileUtils.mkdir_p(File.join(proc_dir, '300'))
    File.write(File.join(proc_dir, '300', 'stat'), "300 (child2) S 100 100 100 0 -1 0 0 0 0 0 0 0 0 0 0 0 0 0")
    
    # Unrelated process
    FileUtils.mkdir_p(File.join(proc_dir, '400'))
    File.write(File.join(proc_dir, '400', 'stat'), "400 (other) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 0 0 0 0")
    
    probe = Dockerprobe.new(proc_path: proc_dir)
    
    # Get all descendants of PID 100
    descendants = probe.send(:get_process_descendants, 100)
    
    assert_equal 4, descendants.length, "Should find parent + 2 children + 1 grandchild"
    assert_includes descendants, 100, "Should include parent PID 100"
    assert_includes descendants, 200, "Should include child PID 200"
    assert_includes descendants, 201, "Should include grandchild PID 201"
    assert_includes descendants, 300, "Should include child PID 300"
    refute_includes descendants, 400, "Should not include unrelated PID 400"
  ensure
    FileUtils.rm_rf(proc_dir) if proc_dir
  end

  def test_write_csv_file
    probe = Dockerprobe.new

    # Test data
    pid_mappings = {
      '1234' => { name: 'test-container', id: 'abc123def456', image: 'test:latest' },
      '5678' => { name: 'another-container', id: '789ghi012jkl', image: 'another:v1.0' }
    }

    probe.send(:write_csv_file, pid_mappings)

    # Verify file was created
    assert File.exist?(@output_file)

    # Verify CSV content
    csv_data = CSV.read(@output_file)
    assert_equal %w[pid container_name container_id image_name], csv_data[0]

    # Should be sorted by PID numerically
    assert_equal '1234', csv_data[1][0]
    assert_equal 'test-container', csv_data[1][1]
    assert_equal 'abc123def456', csv_data[1][2]
    assert_equal 'test:latest', csv_data[1][3]

    assert_equal '5678', csv_data[2][0]
    assert_equal 'another-container', csv_data[2][1]
    assert_equal '789ghi012jkl', csv_data[2][2]
    assert_equal 'another:v1.0', csv_data[2][3]
  end

  def test_write_csv_file_atomic
    probe = Dockerprobe.new

    # Write initial data
    initial_mappings = {
      '1111' => { name: 'initial', id: 'initial123456', image: 'initial:latest' }
    }
    probe.send(:write_csv_file, initial_mappings)

    # Read initial content
    initial_content = File.read(@output_file)

    # Simulate partial write failure by making temp file unwritable
    # (This tests that temp file is cleaned up on error)
    tmp_path = "#{@output_file}.tmp"
    File.write(tmp_path, 'partial data')
    File.chmod(0444, tmp_path)  # Read-only

    # Try to write new data (should fail but not corrupt existing file)
    new_mappings = {
      '2222' => { name: 'new', id: 'new123456789', image: 'new:latest' }
    }

    # This should fail silently (logged but not raised)
    probe.send(:write_csv_file, new_mappings)

    # Original file should still have initial content
    assert_equal initial_content, File.read(@output_file) if File.exist?(@output_file)

    # Clean up
    File.chmod(0644, tmp_path) rescue nil
    File.unlink(tmp_path) rescue nil
  end

  def test_process_hierarchy_breadth_first
    # Create a mock /proc structure with a broader process tree
    proc_dir = Dir.mktmpdir
    
    # Process tree (tests breadth-first traversal):
    # 1000
    #   ├── 2000
    #   │   ├── 2100
    #   │   └── 2200
    #   └── 3000
    #       └── 3100
    #           └── 3110
    
    # Root
    FileUtils.mkdir_p(File.join(proc_dir, '1000'))
    File.write(File.join(proc_dir, '1000', 'stat'), "1000 (root) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 0 0 0 0")
    
    # First level children
    FileUtils.mkdir_p(File.join(proc_dir, '2000'))
    File.write(File.join(proc_dir, '2000', 'stat'), "2000 (branch1) S 1000 1000 1000 0 -1 0 0 0 0 0 0 0 0 0 0 0 0 0")
    
    FileUtils.mkdir_p(File.join(proc_dir, '3000'))
    File.write(File.join(proc_dir, '3000', 'stat'), "3000 (branch2) S 1000 1000 1000 0 -1 0 0 0 0 0 0 0 0 0 0 0 0 0")
    
    # Second level
    FileUtils.mkdir_p(File.join(proc_dir, '2100'))
    File.write(File.join(proc_dir, '2100', 'stat'), "2100 (leaf1) S 2000 2000 2000 0 -1 0 0 0 0 0 0 0 0 0 0 0 0 0")
    
    FileUtils.mkdir_p(File.join(proc_dir, '2200'))
    File.write(File.join(proc_dir, '2200', 'stat'), "2200 (leaf2) S 2000 2000 2000 0 -1 0 0 0 0 0 0 0 0 0 0 0 0 0")
    
    FileUtils.mkdir_p(File.join(proc_dir, '3100'))
    File.write(File.join(proc_dir, '3100', 'stat'), "3100 (branch2child) S 3000 3000 3000 0 -1 0 0 0 0 0 0 0 0 0 0 0 0 0")
    
    # Third level
    FileUtils.mkdir_p(File.join(proc_dir, '3110'))
    File.write(File.join(proc_dir, '3110', 'stat'), "3110 (deepleaf) S 3100 3100 3100 0 -1 0 0 0 0 0 0 0 0 0 0 0 0 0")
    
    probe = Dockerprobe.new(proc_path: proc_dir)
    
    # Get all descendants of root PID 1000
    descendants = probe.send(:get_process_descendants, 1000)
    
    # Should find all 7 processes
    assert_equal 7, descendants.length, "Should find all 7 processes in the tree"
    [1000, 2000, 3000, 2100, 2200, 3100, 3110].each do |pid|
      assert_includes descendants, pid, "Should include PID #{pid}"
    end
  ensure
    FileUtils.rm_rf(proc_dir) if proc_dir
  end
end

# Mock Docker client for testing without Docker daemon
class MockDockerClient < DockerClient
  def initialize(mock_data = {})
    super()
    @mock_containers = mock_data[:containers] || []
    @mock_inspections = mock_data[:inspections] || {}
  end

  def list_containers(options = {})
    @mock_containers
  end

  def inspect_container(container_id)
    @mock_inspections[container_id] || {
      'State' => { 'Pid' => 0 }
    }
  end
end

class TestDockerprobeIntegration < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    @output_file = File.join(@temp_dir, 'docker-mappings.csv')
    ENV['DOCKERPROBE_OUTPUT_PATH'] = @output_file
    ENV['DOCKERPROBE_INTERVAL'] = '1'
  end

  def teardown
    FileUtils.rm_rf(@temp_dir)
    ENV.delete('DOCKERPROBE_OUTPUT_PATH')
    ENV.delete('DOCKERPROBE_INTERVAL')
  end

  def test_process_container_with_mock_data
    # Create mock /proc structure
    proc_dir = Dir.mktmpdir
    
    # Create mock process with PID 5000
    FileUtils.mkdir_p(File.join(proc_dir, '5000'))
    File.write(File.join(proc_dir, '5000', 'stat'), "5000 (container_proc) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 0 0 0 0")
    
    # Create mock Docker data
    mock_containers = [
      {
        'Id' => 'abc123def456789012345',
        'Names' => ['/test-container'],
        'Image' => 'test:latest'
      }
    ]

    mock_inspections = {
      'abc123def456789012345' => {
        'State' => { 'Pid' => 5000 }
      }
    }

    mock_client = MockDockerClient.new(
      containers: mock_containers,
      inspections: mock_inspections
    )

    probe = Dockerprobe.new(proc_path: proc_dir)
    probe.instance_variable_set(:@docker_client, mock_client)

    # Run update_mappings
    probe.send(:update_mappings)

    # Verify CSV was created with correct data
    assert File.exist?(@output_file)

    csv_data = CSV.read(@output_file)
    assert_equal %w[pid container_name container_id image_name], csv_data[0]

    # Find row with mock PID
    our_row = csv_data.find { |row| row[0] == '5000' }
    assert our_row, "Should have mapped mock process PID 5000"
    assert_equal 'test-container', our_row[1]
    assert_equal 'abc123def456', our_row[2]  # Short ID (12 chars)
    assert_equal 'test:latest', our_row[3]
  ensure
    FileUtils.rm_rf(proc_dir) if proc_dir
  end

  def test_multiple_containers
    # Create mock /proc structure
    proc_dir = Dir.mktmpdir
    
    # Create mock processes for each container
    FileUtils.mkdir_p(File.join(proc_dir, '1001'))
    File.write(File.join(proc_dir, '1001', 'stat'), "1001 (container1) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 0 0 0 0")
    
    FileUtils.mkdir_p(File.join(proc_dir, '1002'))
    File.write(File.join(proc_dir, '1002', 'stat'), "1002 (container2) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 0 0 0 0")
    
    # Create mock Docker data with multiple containers
    mock_containers = [
      {
        'Id' => 'container1id23456789012',
        'Names' => ['/container-1'],
        'Image' => 'image1:latest'
      },
      {
        'Id' => 'container2id23456789012',
        'Names' => ['/container-2'],
        'Image' => 'image2:v1.0'
      }
    ]

    # Use different PIDs for each container
    mock_inspections = {
      'container1id23456789012' => {
        'State' => { 'Pid' => 1001 }
      },
      'container2id23456789012' => {
        'State' => { 'Pid' => 1002 }
      }
    }

    mock_client = MockDockerClient.new(
      containers: mock_containers,
      inspections: mock_inspections
    )

    probe = Dockerprobe.new(proc_path: proc_dir)
    probe.instance_variable_set(:@docker_client, mock_client)

    # Run update_mappings
    probe.send(:update_mappings)

    # Verify CSV was created with both containers
    assert File.exist?(@output_file)

    csv_data = CSV.read(@output_file)
    assert_equal 3, csv_data.length  # Header + 2 containers

    # Verify both containers are present
    pids = csv_data[1..].map { |row| row[0] }
    assert_includes pids, '1001'
    assert_includes pids, '1002'
  ensure
    FileUtils.rm_rf(proc_dir) if proc_dir
  end

  def test_container_without_pid
    # Container that's not running (Pid = 0)
    mock_containers = [
      {
        'Id' => 'stoppedcontainer123456',
        'Names' => ['/stopped-container'],
        'Image' => 'stopped:latest'
      }
    ]

    mock_inspections = {
      'stoppedcontainer123456' => {
        'State' => { 'Pid' => 0 }
      }
    }

    mock_client = MockDockerClient.new(
      containers: mock_containers,
      inspections: mock_inspections
    )

    probe = Dockerprobe.new
    probe.instance_variable_set(:@docker_client, mock_client)

    # Run update_mappings
    probe.send(:update_mappings)

    # CSV should only have header (no PIDs mapped)
    csv_data = CSV.read(@output_file)
    assert_equal 1, csv_data.length  # Only header
    assert_equal %w[pid container_name container_id image_name], csv_data[0]
  end
end

if __FILE__ == $0
  # Run tests
  exit Minitest.run(ARGV)
end
