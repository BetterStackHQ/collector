#!/usr/bin/env ruby

require 'listen'
require_relative 'engine/better_stack_client'

working_dir = File.expand_path(File.dirname(__FILE__))
client = BetterStackClient.new(working_dir)

enrichment_path = '/enrichment'

puts "Starting enrichment table watcher on #{enrichment_path}"

# Watch for changes to the incoming CSV file
listener = Listen.to(enrichment_path, only: /\.incoming\.csv$/) do |modified, added, removed|
  (modified + added).each do |file|
    puts "Detected change in #{file}"
    
    # Check if enrichment table has changed
    if client.enrichment_table_changed?
      puts "Validating enrichment table"
      output = client.validate_enrichment_table
      
      if output.nil?
        puts "Enrichment table valid, promoting immediately"
        client.promote_enrichment_table
        puts "Enrichment table promoted"
        
        # Reload Vector with new enrichment data
        client.reload_vector
        puts "Vector reloaded with new enrichment data"
      else
        puts "Enrichment table validation failed: #{output}"
      end
    end
  end
end

listener.start

# Keep the script running
trap('INT') { listener.stop; exit }
trap('TERM') { listener.stop; exit }

$stdout.sync = true
sleep