#!/usr/bin/env ruby

require_relative './engine/better_stack_client'
require 'fileutils'

begin
  working_dir = File.expand_path(File.dirname(__FILE__))
  client = BetterStackClient.new(working_dir)
  should_run = client.cluster_collector?
  
  if should_run
    puts "Should run cluster collector: YES"
    exit 0
  else
    puts "Should run cluster collector: NO"
    exit 1
  end
rescue => e
  puts "Error determining if cluster collector should run: #{e.message}"
  exit 2
end
