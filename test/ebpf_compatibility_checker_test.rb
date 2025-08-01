require 'bundler/setup'
require 'minitest/autorun'
require 'tempfile'
require 'fileutils'
require_relative '../engine/ebpf_compatibility_checker'

class EbpfCompatibilityCheckerTest < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    @ebpf_script_path = File.join(@temp_dir, 'ebpf.sh')
  end

  def teardown
    FileUtils.rm_rf(@temp_dir)
  end

  def test_successful_ebpf_check
    # Create a mock ebpf.sh script that returns successful JSON
    create_mock_ebpf_script(<<~JSON)
      {
        "ebpf_supported": true,
        "kernel_version": "5.15.0-58-generic",
        "ring_buffer_supported": true,
        "bpf_filesystem_mounted": true,
        "btf_support_available": true,
        "bpf_syscall_enabled": true,
        "bpf_jit_enabled": true,
        "architecture": "x86_64",
        "distribution": "Ubuntu 22.04.1 LTS"
      }
    JSON

    checker = EbpfCompatibilityChecker.new(@temp_dir)

    assert checker.checked
    assert_equal true, checker.system_information["ebpf_supported"]
    assert_equal "5.15.0-58-generic", checker.system_information["kernel_version"]
    assert_equal true, checker.system_information["ring_buffer_supported"]
    assert_equal true, checker.system_information["bpf_filesystem_mounted"]
    assert_equal true, checker.system_information["btf_support_available"]
    assert_equal true, checker.system_information["bpf_syscall_enabled"]
    assert_equal true, checker.system_information["bpf_jit_enabled"]
    assert_equal "x86_64", checker.system_information["architecture"]
    assert_equal "Ubuntu 22.04.1 LTS", checker.system_information["distribution"]
  end

  def test_ebpf_not_supported
    create_mock_ebpf_script(<<~JSON)
      {
        "ebpf_supported": false,
        "kernel_version": "4.9.0-8-amd64",
        "ring_buffer_supported": false,
        "bpf_filesystem_mounted": false,
        "btf_support_available": false,
        "bpf_syscall_enabled": false,
        "bpf_jit_enabled": null,
        "architecture": "x86_64",
        "distribution": "Debian GNU/Linux 9 (stretch)"
      }
    JSON

    checker = EbpfCompatibilityChecker.new(@temp_dir)

    assert checker.checked
    assert_equal false, checker.system_information["ebpf_supported"]
    assert_equal "4.9.0-8-amd64", checker.system_information["kernel_version"]
    assert_equal false, checker.system_information["ring_buffer_supported"]
  end

  def test_script_not_found
    # Don't create the script
    checker = nil

    # Capture stdout to suppress the error message during test
    capture_io do
      checker = EbpfCompatibilityChecker.new(@temp_dir)
    end

    assert checker.system_information.key?(:error)
    assert_equal "ebpf.sh script not found", checker.system_information[:error]
  end

  def test_script_fails_with_exit_code
    # Create a script that exits with non-zero status
    create_failing_ebpf_script("Some error message", 1)

    checker = nil
    capture_io do
      checker = EbpfCompatibilityChecker.new(@temp_dir)
    end

    assert checker.system_information.key?(:error)
    assert_equal "eBPF check failed", checker.system_information[:error]
    assert_equal 1, checker.system_information[:exit_code]
    assert_match(/Some error message/, checker.system_information[:stderr])
  end

  def test_invalid_json_output
    # Create a script that outputs invalid JSON
    create_mock_ebpf_script("{ invalid json }")

    checker = nil
    capture_io do
      checker = EbpfCompatibilityChecker.new(@temp_dir)
    end

    assert checker.system_information.key?(:error)
    assert_match(/JSON parse error/, checker.system_information[:error])
  end

  def test_reported_status_tracking
    create_mock_ebpf_script('{"ebpf_supported": true, "kernel_version": "5.15.0"}')

    checker = EbpfCompatibilityChecker.new(@temp_dir)

    # Initially not reported
    refute checker.reported?

    # Mark as reported
    checker.mark_as_reported
    assert checker.reported?
  end

  def test_system_information_returns_nil_when_no_data
    # Create an instance with a custom data value
    checker = EbpfCompatibilityChecker.new(@temp_dir)
    checker.instance_variable_set(:@system_information, nil)

    assert_nil checker.system_information
  end

  def test_non_executable_script
    # Create script without execute permissions
    File.write(@ebpf_script_path, "#!/bin/bash\necho '{}'")
    File.chmod(0644, @ebpf_script_path)

    checker = nil
    capture_io do
      checker = EbpfCompatibilityChecker.new(@temp_dir)
    end

    assert checker.system_information.key?(:error)
    assert_match(/Permission denied|cannot execute/, checker.system_information[:error])
  end

  def test_generic_exception_handling
    # First create the script so it exists
    create_mock_ebpf_script('{"ebpf_supported": true}')

    # Mock Open3.capture3 to raise an exception
    Open3.stub :capture3, -> (*args) { raise StandardError, "Simulated error" } do
      checker = nil
      out, _ = capture_io do
        checker = EbpfCompatibilityChecker.new(@temp_dir)
      end

      assert checker.system_information.key?(:error)
      assert_match(/Exception: Simulated error/, checker.system_information[:error])
      assert_match(/Error running eBPF compatibility check/, out)
    end
  end

  def test_verifies_json_flag_is_passed
    # Create a script that outputs different content based on the flag
    File.write(@ebpf_script_path, <<~SCRIPT)
      #!/bin/sh
      if [ "$1" = "--json" ]; then
        echo '{"ebpf_supported": true, "flag": "json"}'
      else
        echo '{"ebpf_supported": false, "flag": "none"}'
      fi
    SCRIPT
    File.chmod(0755, @ebpf_script_path)

    checker = EbpfCompatibilityChecker.new(@temp_dir)

    assert checker.checked
    assert_equal "json", checker.system_information["flag"]
  end





  private

  def create_mock_ebpf_script(output)
    # If output is a Hash, convert to JSON, otherwise use as-is
    json_output = output.is_a?(Hash) ? JSON.generate(output) : output

    # Use heredoc with proper escaping
    script_content = <<~SCRIPT
      #!/bin/sh
      if [ "$1" = "--json" ]; then
        printf '%s\\n' '#{json_output.gsub("'", "'\"'\"'")}'
      else
        echo "Human readable output"
      fi
    SCRIPT

    File.write(@ebpf_script_path, script_content)
    File.chmod(0755, @ebpf_script_path)
  end

  def create_failing_ebpf_script(error_message, exit_code)
    File.write(@ebpf_script_path, <<~SCRIPT)
      #!/bin/sh
      echo "#{error_message}" >&2
      exit #{exit_code}
    SCRIPT
    File.chmod(0755, @ebpf_script_path)
  end
end
