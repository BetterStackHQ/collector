require 'json'
require 'open3'

class EbpfCompatibilityChecker
  attr_reader :data, :checked

  def initialize(working_dir)
    @working_dir = working_dir
    @data = nil
    @checked = false
    check_compatibility
  end

  def system_information
    return nil unless @data
    @data
  end

  def mark_as_reported
    @reported = true
  end

  def reported?
    @reported || false
  end

  private

  def check_compatibility
    ebpf_script = File.join(@working_dir, 'ebpf.sh')
    
    unless File.exist?(ebpf_script)
      puts "eBPF compatibility check script not found at #{ebpf_script}"
      @data = { error: "ebpf.sh script not found" }
      return
    end

    begin
      stdout, stderr, status = Open3.capture3("#{ebpf_script} --json")
      
      if status.success?
        @data = JSON.parse(stdout, symbolize_names: false)
        @checked = true
      else
        puts "eBPF compatibility check failed with exit code #{status.exitstatus}"
        puts "STDERR: #{stderr}" unless stderr.empty?
        @data = { 
          error: "eBPF check failed",
          exit_code: status.exitstatus,
          stderr: stderr
        }
      end
    rescue JSON::ParserError => e
      puts "Failed to parse eBPF compatibility JSON: #{e.message}"
      @data = { error: "JSON parse error: #{e.message}" }
    rescue => e
      puts "Error running eBPF compatibility check: #{e.message}"
      @data = { error: "Exception: #{e.message}" }
    end
  end
end