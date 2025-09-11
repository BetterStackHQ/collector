#!/usr/bin/env ruby

require_relative 'engine/better_stack_client'

working_dir = File.expand_path(File.dirname(__FILE__))
client = BetterStackClient.new(working_dir)

SLEEP_DURATION = 15
PING_EVERY = 2 # iterations of the loop -> every SLEEP_DURATION * PING_EVERY seconds

iteration = 1

# Main loop
loop do
  # Check for enrichment table changes more frequently
  # This reduces delay when containers are added/removed
  enrichment_table_changed = client.enrichment_table_changed?
  can_reload_vector = true
  config_changed = false # error flag so we can make sure we only reload vector if we have a valid config

  # Validate enrichment table if it has changed
  if enrichment_table_changed
    puts "[#{Time.now}] Validating enrichment table"
    output = client.validate_enrichment_table
    puts "[#{Time.now}] Enrichment table validation finished"
    if !output.nil?
      puts "[#{Time.now}] Enrichment table validation failed"
      can_reload_vector = false
    else
      puts "[#{Time.now}] Promoting enrichment table"
      client.promote_enrichment_table
      puts "[#{Time.now}] Enrichment table promoted"
    end
  end

  # Only attempt to promote config if enrichment table is valid
  if iteration % PING_EVERY == 0
    iteration = 1
    puts "Starting ping"
    config_changed = client.ping
    puts "Ping finished"
  end

  if can_reload_vector && (enrichment_table_changed || config_changed)
    client.reload_vector
  end

  $stdout.flush
  iteration += 1
  puts "Sleeping for #{SLEEP_DURATION} seconds..."
  sleep SLEEP_DURATION
end