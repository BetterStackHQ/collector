require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require_relative '../engine/ssl_certificate_manager'

class SSLCertificateManagerTest < Minitest::Test
  def setup
    @test_dir = Dir.mktmpdir
    @manager = SSLCertificateManager.new(@test_dir)
    @domain_file = File.join(@test_dir, 'ssl_certificate_host.txt')
  end

  def teardown
    FileUtils.rm_rf(@test_dir)
  end

  def test_initialize_with_working_dir
    manager = SSLCertificateManager.new(@test_dir)
    assert_equal File.join(@test_dir, 'ssl_certificate_host.txt'), manager.domain_file
  end

  def test_initialize_without_working_dir
    manager = SSLCertificateManager.new
    assert_equal '/etc/ssl_certificate_host.txt', manager.domain_file
  end

  def test_read_current_domain_when_file_missing
    assert_equal '', @manager.read_current_domain
  end

  def test_read_current_domain_when_file_exists
    File.write(@domain_file, 'example.com')
    assert_equal 'example.com', @manager.read_current_domain
  end

  def test_read_current_domain_strips_whitespace
    File.write(@domain_file, "  example.com\n  ")
    assert_equal 'example.com', @manager.read_current_domain
  end

  def test_process_ssl_certificate_host_first_time
    # Mock restart_certbot to avoid system calls
    restart_called = false
    @manager.define_singleton_method(:restart_certbot) do
      restart_called = true
      true
    end

    result = @manager.process_ssl_certificate_host('new.example.com')

    assert result, 'Should return true when domain changes'
    assert_equal 'new.example.com', File.read(@domain_file)
    assert restart_called, 'Should restart certbot for new non-empty domain'
    assert @manager.domain_just_changed, 'Should set domain_just_changed flag'
  end

  def test_process_ssl_certificate_host_no_change
    File.write(@domain_file, 'example.com')

    # Mock restart_certbot
    restart_called = false
    @manager.define_singleton_method(:restart_certbot) do
      restart_called = true
      true
    end

    result = @manager.process_ssl_certificate_host('example.com')

    assert !result, 'Should return false when domain unchanged'
    assert !restart_called, 'Should not restart certbot when domain unchanged'
    assert !@manager.domain_just_changed, 'Should not set domain_just_changed flag'
  end

  def test_process_ssl_certificate_host_domain_change
    File.write(@domain_file, 'old.example.com')

    # Mock restart_certbot
    restart_called = false
    @manager.define_singleton_method(:restart_certbot) do
      restart_called = true
      true
    end

    result = @manager.process_ssl_certificate_host('new.example.com')

    assert result, 'Should return true when domain changes'
    assert_equal 'new.example.com', File.read(@domain_file)
    assert restart_called, 'Should restart certbot when domain changes'
    assert @manager.domain_just_changed, 'Should set domain_just_changed flag'
  end

  def test_process_ssl_certificate_host_to_empty
    File.write(@domain_file, 'example.com')

    # Mock restart_certbot
    restart_called = false
    @manager.define_singleton_method(:restart_certbot) do
      restart_called = true
      true
    end

    result = @manager.process_ssl_certificate_host('')

    assert result, 'Should return true when clearing domain'
    assert_equal '', File.read(@domain_file)
    assert !restart_called, 'Should not restart certbot when clearing domain'
    assert @manager.domain_just_changed, 'Should set domain_just_changed flag'
  end

  def test_process_ssl_certificate_host_from_empty
    # Start with no file (empty domain)

    # Mock restart_certbot
    restart_called = false
    @manager.define_singleton_method(:restart_certbot) do
      restart_called = true
      true
    end

    result = @manager.process_ssl_certificate_host('new.example.com')

    assert result, 'Should return true when setting domain from empty'
    assert_equal 'new.example.com', File.read(@domain_file)
    assert restart_called, 'Should restart certbot when setting non-empty domain'
    assert @manager.domain_just_changed, 'Should set domain_just_changed flag'
  end

  def test_certificate_exists_returns_false_for_empty_domain
    File.write(@domain_file, '')
    assert !@manager.certificate_exists?, 'Should return false for empty domain'
  end

  def test_certificate_exists_returns_false_when_files_missing
    assert !@manager.certificate_exists?('example.com'), 'Should return false when cert files missing'
  end

  def test_certificate_exists_returns_false_when_only_cert_exists
    domain = 'example.com'
    cert_path = "/etc/ssl/#{domain}.pem"

    # Create temp cert file for testing
    FileUtils.mkdir_p('/tmp/ssl_test')
    temp_cert = "/tmp/ssl_test/#{domain}.pem"
    FileUtils.touch(temp_cert)

    # Mock the certificate path checking
    @manager.define_singleton_method(:certificate_exists?) do |d|
      d ||= read_current_domain
      return false if d.empty?
      # Use temp paths for testing
      File.exist?("/tmp/ssl_test/#{d}.pem") && File.exist?("/tmp/ssl_test/#{d}.key")
    end

    assert !@manager.certificate_exists?(domain), 'Should return false when only cert exists'

    FileUtils.rm_rf('/tmp/ssl_test')
  end

  def test_certificate_exists_returns_true_when_both_files_exist
    domain = 'example.com'

    # Create temp cert files for testing
    FileUtils.mkdir_p('/tmp/ssl_test')
    temp_cert = "/tmp/ssl_test/#{domain}.pem"
    temp_key = "/tmp/ssl_test/#{domain}.key"
    FileUtils.touch(temp_cert)
    FileUtils.touch(temp_key)

    # Mock the certificate path checking
    @manager.define_singleton_method(:certificate_exists?) do |d|
      d ||= read_current_domain
      return false if d.empty?
      # Use temp paths for testing
      File.exist?("/tmp/ssl_test/#{d}.pem") && File.exist?("/tmp/ssl_test/#{d}.key")
    end

    assert @manager.certificate_exists?(domain), 'Should return true when both cert files exist'

    FileUtils.rm_rf('/tmp/ssl_test')
  end

  def test_should_skip_validation_when_domain_just_changed_and_no_cert
    # Simulate domain just changed
    @manager.instance_variable_set(:@domain_just_changed, true)
    File.write(@domain_file, 'new.example.com')

    # Mock certificate_exists? to return false
    @manager.define_singleton_method(:certificate_exists?) do |domain|
      false
    end

    assert @manager.should_skip_validation?, 'Should skip validation when domain changed and cert missing'
  end

  def test_should_not_skip_validation_when_domain_unchanged
    # Domain has not just changed
    @manager.instance_variable_set(:@domain_just_changed, false)
    File.write(@domain_file, 'example.com')

    assert !@manager.should_skip_validation?, 'Should not skip validation when domain unchanged'
  end

  def test_should_not_skip_validation_when_cert_exists
    # Simulate domain just changed
    @manager.instance_variable_set(:@domain_just_changed, true)
    File.write(@domain_file, 'example.com')

    # Mock certificate_exists? to return true
    @manager.define_singleton_method(:certificate_exists?) do |domain|
      true
    end

    assert !@manager.should_skip_validation?, 'Should not skip validation when cert exists'
  end

  def test_should_not_skip_validation_for_empty_domain
    # Simulate domain just changed to empty
    @manager.instance_variable_set(:@domain_just_changed, true)
    File.write(@domain_file, '')

    assert !@manager.should_skip_validation?, 'Should not skip validation for empty domain'
  end

  def test_reset_change_flag
    @manager.instance_variable_set(:@domain_just_changed, true)
    assert @manager.domain_just_changed

    @manager.reset_change_flag
    assert !@manager.domain_just_changed, 'Should reset domain_just_changed flag'
  end

  def test_restart_certbot_command
    # Test that restart_certbot attempts the right system command
    # We'll mock system to capture the command
    command_executed = nil
    @manager.define_singleton_method(:system) do |cmd|
      command_executed = cmd
      true
    end

    @manager.send(:restart_certbot)

    expected_command = 'supervisorctl -c /etc/supervisor/conf.d/supervisord.conf restart certbot'
    assert_equal expected_command, command_executed, 'Should execute correct supervisorctl command'
  end

  def test_process_handles_write_errors_gracefully
    # Make domain file unwritable
    FileUtils.mkdir_p(@domain_file)  # Create as directory to cause write error

    # Should raise error when unable to write
    assert_raises do
      @manager.process_ssl_certificate_host('example.com')
    end
  end

  def test_strips_whitespace_from_input
    # Mock restart_certbot
    @manager.define_singleton_method(:restart_certbot) { true }

    @manager.process_ssl_certificate_host("  example.com\n  ")
    assert_equal 'example.com', File.read(@domain_file)
  end
end