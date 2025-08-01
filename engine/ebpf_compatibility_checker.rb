require 'json'
require 'open3'

class EbpfCompatibilityChecker
  attr_reader :system_information, :checked

  def initialize(working_dir)
    @working_dir = working_dir
    @system_information = nil
    @checked = false
    check_compatibility
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
      @system_information = { error: "ebpf.sh script not found" }
      return
    end

    begin
      stdout, stderr, status = Open3.capture3("#{ebpf_script} --json")

      if status.success?
        @system_information = JSON.parse(stdout, symbolize_names: false)
        @checked = true
      else
        puts "eBPF compatibility check failed with exit code #{status.exitstatus}"
        puts "STDERR: #{stderr}" unless stderr.empty?
        @system_information = {
          error: "eBPF check failed",
          exit_code: status.exitstatus,
          stderr: stderr,
          stdout: stdout,
        }
      end
    rescue JSON::ParserError => e
      puts "Failed to parse eBPF compatibility JSON: #{e.message}"
      @system_information = { error: "JSON parse error: #{e.message}" }
    rescue => e
      puts "Error running eBPF compatibility check: #{e.message}"
      @system_information = { error: "Exception: #{e.message}" }
    end
  end
end
