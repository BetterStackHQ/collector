#!/usr/bin/env ruby

require_relative 'engine/vector_enrichment_table'

vector_enrichment_table = VectorEnrichmentTable.new

SLEEP_DURATION = 15
last_hash = nil

# Checks whether the enrichment table has changed, and reloads vector if it has
loop do
  puts "Checking enrichment table for changes"
  new_hash = vector_enrichment_table.check_for_changes
  if new_hash != last_hash && !new_hash.nil?
    if last_hash.nil?
      puts "First run, no previous hash - storing hash"
    else
      puts "Enrichment table changed! Reloading vector..."
      system("supervisorctl signal HUP vector")
    end

    last_hash = new_hash
  end

  puts "Enrichment table checked. Sleeping for #{SLEEP_DURATION} seconds..."
  $stdout.flush
  sleep SLEEP_DURATION
end