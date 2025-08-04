#!/usr/bin/env ruby

require_relative 'engine/better_stack_client'

working_dir = File.expand_path(File.dirname(__FILE__))
client = BetterStackClient.new(working_dir)

SLEEP_DURATION = 15
PING_EVERY = 2 # iterations of the loop -> every SLEEP_DURATION * PING_EVERY seconds

iteration = 1

# Main loop
loop do
  enrichment_table_changed = client.enrichment_table_changed?
  can_continue = true
  config_changed = false # error flag so we can make sure we only reload vector if we have a valid config

  # Validate enrichment table if it has changed
  if enrichment_table_changed
    puts "Validating enrichment table"
    output = client.validate_enrichment_table
    puts "Enrichment table validation finished"
    if !output.nil?
      puts "Enrichment table validation failed"
      can_continue = false
    end
  end

  # Only attempt to promote config if enrichment table is valid
  if can_continue && iteration % PING_EVERY == 0
    iteration = 1
    puts "Starting ping"
    config_changed = client.ping
    puts "Ping finished"
  end

  if can_continue && (enrichment_table_changed || config_changed)
    client.reload_vector
  end

  $stdout.flush
  iteration += 1
  puts "Sleeping for #{SLEEP_DURATION} seconds..."
  sleep SLEEP_DURATION
end