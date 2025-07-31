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

  def test_null_values_in_json
    create_mock_ebpf_script(<<~JSON)
      {
        "ebpf_supported": true,
        "kernel_version": "5.15.0",
        "ring_buffer_supported": true,
        "bpf_filesystem_mounted": true,
        "btf_support_available": true,
        "bpf_syscall_enabled": null,
        "bpf_jit_enabled": null,
        "architecture": "x86_64",
        "distribution": "Custom Linux"
      }
    JSON

    checker = EbpfCompatibilityChecker.new(@temp_dir)

    assert checker.checked
    assert_nil checker.system_information["bpf_syscall_enabled"]
    assert_nil checker.system_information["bpf_jit_enabled"]
  end

  def test_special_characters_in_distribution_name
    create_mock_ebpf_script(<<~JSON)
      {
        "ebpf_supported": true,
        "kernel_version": "5.15.0",
        "ring_buffer_supported": true,
        "bpf_filesystem_mounted": true,
        "btf_support_available": true,
        "bpf_syscall_enabled": true,
        "bpf_jit_enabled": true,
        "architecture": "x86_64",
        "distribution": "Ubuntu 22.04.1 LTS \\"Jammy Jellyfish\\""
      }
    JSON

    checker = EbpfCompatibilityChecker.new(@temp_dir)

    assert checker.checked
    assert_equal 'Ubuntu 22.04.1 LTS "Jammy Jellyfish"', checker.system_information["distribution"]
  end

  def test_empty_json_output
    create_mock_ebpf_script('{}')

    checker = EbpfCompatibilityChecker.new(@temp_dir)

    assert checker.checked
    assert_equal({}, checker.system_information)
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

  def test_checked_flag_remains_false_on_all_errors
    test_cases = [
      # Script not found
      -> { FileUtils.rm_f(@ebpf_script_path) },
      # Script fails
      -> { create_failing_ebpf_script("Error", 1) },
      # Invalid JSON
      -> { create_mock_ebpf_script("invalid json") }
    ]

    test_cases.each_with_index do |setup, index|
      setup.call
      checker = nil
      capture_io do
        checker = EbpfCompatibilityChecker.new(@temp_dir)
      end

      refute checker.checked, "Expected checked to be false for test case #{index}"
      assert checker.system_information.key?(:error), "Expected error for test case #{index}"
    end
  end

  def test_very_large_json_output
    # Create a large JSON with many fields
    large_data = {
      "ebpf_supported" => true,
      "kernel_version" => "5.15.0",
      "additional_data" => "x" * 10000
    }
    create_mock_ebpf_script(JSON.generate(large_data))

    checker = EbpfCompatibilityChecker.new(@temp_dir)

    assert checker.checked
    assert_equal true, checker.system_information["ebpf_supported"]
    assert_equal 10000, checker.system_information["additional_data"].length
  end

  def test_json_with_missing_fields
    create_mock_ebpf_script(<<~JSON)
      {
        "ebpf_supported": true,
        "kernel_version": "5.15.0"
      }
    JSON

    checker = EbpfCompatibilityChecker.new(@temp_dir)

    assert checker.checked
    assert_equal true, checker.system_information["ebpf_supported"]
    assert_equal "5.15.0", checker.system_information["kernel_version"]
    # Verify missing fields are not present
    assert_nil checker.system_information["ring_buffer_supported"]
    assert_nil checker.system_information["architecture"]
  end

  def test_verifies_json_flag_is_passed
    # Create a script that outputs different content based on the flag
    File.write(@ebpf_script_path, <<~SCRIPT)
      #!/bin/bash
      if [ "$1" == "--json" ]; then
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

  def test_stdout_messages_are_printed
    # Test various error scenarios and verify stdout messages
    test_cases = [
      {
        setup: -> { FileUtils.rm_f(@ebpf_script_path) },
        expected_output: /eBPF compatibility check script not found/
      },
      {
        setup: -> { create_failing_ebpf_script("Test error", 42) },
        expected_output: /eBPF compatibility check failed with exit code 42/
      },
      {
        setup: -> { create_mock_ebpf_script("not valid json") },
        expected_output: /Failed to parse eBPF compatibility JSON/
      }
    ]

    test_cases.each do |test_case|
      test_case[:setup].call
      out, _ = capture_io do
        EbpfCompatibilityChecker.new(@temp_dir)
      end

      assert_match test_case[:expected_output], out
    end
  end

  def test_various_malformed_json_inputs
    malformed_json_cases = [
      # Missing closing brace
      '{"ebpf_supported": true',
      # Extra comma
      '{"ebpf_supported": true,}',
      # Single quotes instead of double
      "{'ebpf_supported': true}",
      # Unquoted keys
      '{ebpf_supported: true}',
      # Trailing text after valid JSON
      '{"ebpf_supported": true} extra text',
      # NaN value
      '{"value": NaN}',
      # Undefined value
      '{"value": undefined}',
      # Mixed array/object
      '[{"ebpf_supported": true]',
      # Unicode escape issues
      '{"text": "\\u000"}',
      # Nested errors
      '{"data": {"nested": [1, 2, }]}',
      # Empty string
      '',
      # Just whitespace
      '   \n\t   '
    ]

    malformed_json_cases.each_with_index do |json_input, index|
      create_mock_ebpf_script(json_input)

      checker = nil
      out, _ = capture_io do
        checker = EbpfCompatibilityChecker.new(@temp_dir)
      end

      refute checker.checked, "Expected checked=false for malformed JSON case #{index}: #{json_input.inspect}"
      assert checker.system_information.key?(:error), "Expected error for case #{index}"
      assert_match(/JSON parse error/, checker.system_information[:error], "Case #{index}: #{json_input.inspect}")
      assert_match(/Failed to parse eBPF compatibility JSON/, out, "Expected stdout message for case #{index}")
    end
  end

  def test_valid_json_but_wrong_type
    # These parse as valid JSON but aren't objects/hashes
    wrong_type_cases = [
      # Array instead of object
      ['["ebpf_supported", true]', Array],
      # Number instead of object
      ['42', Integer],
      # String instead of object
      ['"not an object"', String],
      # Boolean instead of object
      ['true', TrueClass],
      # Null
      ['null', NilClass]
    ]

    wrong_type_cases.each_with_index do |(json_input, expected_class), index|
      create_mock_ebpf_script(json_input)

      checker = EbpfCompatibilityChecker.new(@temp_dir)

      # The current implementation accepts any valid JSON
      assert checker.checked, "Expected successful parse for case #{index}: #{json_input.inspect}"
      assert_instance_of expected_class, checker.system_information,
                        "Expected #{expected_class} for case #{index}"
    end
  end

  def test_json_edge_cases_that_should_work
    valid_edge_cases = [
      # Empty object
      [{}, {}],
      # Unicode in strings
      [{"text" => "Hello 👋 World"}, {"text" => "Hello 👋 World"}],
      # Very long strings
      [{"long" => "a" * 1000}, {"long" => "a" * 1000}],
      # Nested structures
      [{"nested" => {"deep" => {"structure" => true}}},
       {"nested" => {"deep" => {"structure" => true}}}],
      # Arrays in values
      [{"list" => [1, 2, 3, "four"]}, {"list" => [1, 2, 3, "four"]}],
      # Numbers of various types
      [{"int" => 42, "float" => 3.14, "exp" => 1.23e-10},
       {"int" => 42, "float" => 3.14, "exp" => 1.23e-10}],
      # Boolean values
      [{"yes" => true, "no" => false}, {"yes" => true, "no" => false}],
      # Null values
      [{"nothing" => nil}, {"nothing" => nil}],
      # Mixed types
      [{"mixed" => [1, "two", true, nil, {"nested" => "value"}]},
       {"mixed" => [1, "two", true, nil, {"nested" => "value"}]}]
    ]

    valid_edge_cases.each_with_index do |(input_hash, expected_hash), index|
      create_mock_ebpf_script(input_hash)

      checker = EbpfCompatibilityChecker.new(@temp_dir)

      assert checker.checked, "Expected checked=true for valid edge case #{index}"
      assert_equal expected_hash, checker.system_information, "Case #{index} failed"
    end
  end

  private

  def create_mock_ebpf_script(output)
    # If output is a Hash, convert to JSON, otherwise use as-is
    json_output = output.is_a?(Hash) ? JSON.generate(output) : output

    # Use heredoc with proper escaping
    script_content = <<~SCRIPT
      #!/bin/bash
      if [ "$1" == "--json" ]; then
        cat << 'EOF'
#{json_output}
EOF
      else
        echo "Human readable output"
      fi
    SCRIPT

    File.write(@ebpf_script_path, script_content)
    File.chmod(0755, @ebpf_script_path)
  end

  def create_failing_ebpf_script(error_message, exit_code)
    File.write(@ebpf_script_path, <<~SCRIPT)
      #!/bin/bash
      echo "#{error_message}" >&2
      exit #{exit_code}
    SCRIPT
    File.chmod(0755, @ebpf_script_path)
  end
end
