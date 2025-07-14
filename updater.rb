#!/usr/bin/env ruby

require_relative 'engine/better_stack_client'

working_dir = File.expand_path(File.dirname(__FILE__))
client = BetterStackClient.new(working_dir)

# Main loop
loop do
  puts "Starting ping"
  client.ping
  sleep_duration = 30
  puts "Ping finished. Sleeping for #{sleep_duration} seconds..."
  $stdout.flush
  sleep sleep_duration
end
