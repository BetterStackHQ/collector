#!/usr/bin/env ruby
# frozen_string_literal: true

# Produces a CSV file associating process IDs to container IDs and names.
# This CSV file is formatted as:
#
# pid,container_name,container_id,image_name
# 1115,better-stack-collector,59e2ea91d8af,betterstack/collector:latest
# 1020,your-container-replica-name-1,0dbc098bc64d,your-repository/your-image:latest
#
# This file is shared from the Beyla container to the Collector container via the docker-metadata volume mounted at /enrichment.
# Vector uses this file to enrich logs, metrics, and traces with container metadata.

require 'csv'
require 'json'
require 'fileutils'
require 'logger'

# Load Docker API client
require_relative 'docker_client'

class Dockerprobe
  DEFAULT_OUTPUT_PATH = '/enrichment/docker-mappings.incoming.csv'
  DEFAULT_INTERVAL = 15  # seconds; in line with the default tick rate of Beyla collection
  SHORT_CONTAINER_ID_LEN = 12  # length of the short container ID (e.g. 0dbc098bc64d)
  CSV_HEADERS = %w[pid container_name container_id image_name]
  DEFAULT_PROC_PATH = '/proc'

  attr_reader :proc_path

  def initialize(proc_path: nil)
    @output_path = ENV['DOCKERPROBE_OUTPUT_PATH'] || DEFAULT_OUTPUT_PATH
    @interval = (ENV['DOCKERPROBE_INTERVAL'] || DEFAULT_INTERVAL).to_i
    @docker_client = DockerClient.new
    @logger = Logger.new(STDOUT)
    @logger.level = ENV['DEBUG'] ? Logger::DEBUG : Logger::INFO
    @logger.formatter = proc { |severity, datetime, _, msg| "#{datetime.strftime('%Y-%m-%d %H:%M:%S')} [#{severity}] #{msg}\n" }
    @running = true
    @proc_path = proc_path || DEFAULT_PROC_PATH
  end

  def run
    @logger.info "Starting dockerprobe..."
    @logger.info "Output path: #{@output_path}"
    @logger.info "Update interval: #{@interval} seconds"

    # Ensure output directory exists
    dir = File.dirname(@output_path)
    FileUtils.mkdir_p(dir) unless File.directory?(dir)

    # Set up signal handlers for graceful shutdown
    %w[INT TERM].each do |signal|
      Signal.trap(signal) do
        @logger.info "Received #{signal} signal, shutting down..."
        @running = false
      end
    end

    # Initial update
    update_mappings

    # Main loop
    while @running
      sleep @interval
      break unless @running
      update_mappings
    end

    @logger.info "Graceful shutdown complete"
  rescue => e
    @logger.error "Fatal error in dockerprobe: #{e.message}"
    @logger.error e.backtrace.join("\n") if ENV['DEBUG']
    exit 1
  end

  private

  def update_mappings
    containers = list_running_containers
    pid_mappings = {}

    containers.each do |container|
      process_container(container, pid_mappings)
    rescue => e
      @logger.error "Failed to process container #{container['Id'][0...SHORT_CONTAINER_ID_LEN]}: #{e.message}"
      @logger.debug e.backtrace.join("\n") if ENV['DEBUG']
    end

    write_csv_file(pid_mappings)

    # Flush output after each update cycle
    STDOUT.flush
  rescue => e
    @logger.error "updateMappings error: #{e.message}"
    @logger.debug e.backtrace.join("\n") if ENV['DEBUG']
    STDOUT.flush  # Also flush on error
  end

  def list_running_containers
    @docker_client.list_containers(all: false)
  end

  def process_container(container, pid_mappings)
    # Get detailed container info
    inspect = @docker_client.inspect_container(container['Id'])

    pid = inspect['State']['Pid']
    return if pid.nil? || pid <= 0

    # Container info to store
    container_info = {
      name: container['Names'].first.to_s.sub(/^\//, ''),  # Remove the leading slash
      id: container['Id'][0...SHORT_CONTAINER_ID_LEN],
      image: container['Image']
    }

    # Get all descendant PIDs
    pids = get_process_descendants(pid)

    # Map each PID to this container
    pids.each do |p|
      pid_mappings[p.to_s] = container_info
    end

    @logger.info "Mapped #{pids.length} PIDs to container #{container_info[:name]}"
  end

  def get_process_descendants(root_pid)
    descendants = [root_pid]
    to_check = [root_pid]

    until to_check.empty?
      current_pid = to_check.shift # FIFO queue

      children = find_child_processes(current_pid)
      children.each do |child_pid|
        unless descendants.include?(child_pid)
          descendants << child_pid
          to_check << child_pid
        end
      end
    end

    descendants
  end

  def find_child_processes(parent_pid)
    children = []

    # Scan proc directory for processes
    return [] unless File.directory?(@proc_path)

    Dir.entries(@proc_path).each do |entry|
      next unless entry =~ /^\d+$/

      pid = entry.to_i
      ppid = get_parent_pid(pid)

      children << pid if ppid == parent_pid
    rescue => e
      # Ignore processes that disappear or can't be read
      @logger.debug "Error reading process #{pid}: #{e.message}" if ENV['DEBUG']
    end

    children
  rescue => e
    @logger.debug "Error scanning #{@proc_path}: #{e.message}" if ENV['DEBUG']
    []
  end

  def get_parent_pid(pid)
    stat_file = File.join(@proc_path, pid.to_s, 'stat')
    return nil unless File.exist?(stat_file)

    stat_data = File.read(stat_file)

    # The stat file format is: pid (comm) state ppid ...
    # We need to handle the case where comm contains parentheses
    last_paren = stat_data.rindex(')')
    return nil unless last_paren

    # Fields after the last parenthesis
    fields = stat_data[(last_paren + 1)..].split
    return nil if fields.length < 2

    # Parent PID is the second field after the command name
    fields[1].to_i
  rescue => e
    @logger.debug "Error reading parent PID for #{pid}: #{e.message}" if ENV['DEBUG']
    nil
  end

  def write_csv_file(pid_mappings)
    tmp_path = "#{@output_path}.tmp"

    # Sort PIDs numerically for stable ordering
    sorted_pids = pid_mappings.keys.sort_by(&:to_i)

    CSV.open(tmp_path, 'w') do |csv|
      # Write header
      csv << CSV_HEADERS

      # Write mappings
      sorted_pids.each do |pid|
        info = pid_mappings[pid]
        csv << [pid, info[:name], info[:id], info[:image]]
      end
    end

    # Atomic rename
    File.rename(tmp_path, @output_path)

    @logger.info "Updated PID mappings file with #{pid_mappings.length} entries"
  rescue => e
    @logger.error "Failed to write PID mappings: #{e.message}"
    @logger.debug e.backtrace.join("\n") if ENV['DEBUG']

    # Clean up the temp file if it exists
    File.unlink(tmp_path) if File.exist?(tmp_path)
  end
end

# Run if executed directly
if __FILE__ == $0
  Dockerprobe.new.run
end
