require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require 'json'
require_relative '../engine/kubernetes_discovery'

class KubernetesDiscoveryTest < Minitest::Test
  def setup
    @test_dir = Dir.mktmpdir
    @discovery = KubernetesDiscovery.new(@test_dir)
    
    # Create kubernetes-discovery directory structure
    FileUtils.mkdir_p(File.join(@test_dir, 'kubernetes-discovery', '0-default'))
    File.write(File.join(@test_dir, 'kubernetes-discovery', '0-default', 'dummy.yaml'), "sources: {}")
    
    # Set NODE_NAME for tests
    ENV['HOSTNAME'] = 'test-node'
  end

  def teardown
    FileUtils.rm_rf(@test_dir)
    ENV.delete('HOSTNAME')
  end

  def test_should_discover_with_kubernetes_discovery_usage
    # Create latest-valid-vector.yaml with kubernetes_discovery_ reference
    vector_path = File.join(@test_dir, 'latest-valid-vector.yaml')
    File.write(vector_path, "sources:\n  kubernetes_discovery_test:\n    type: prometheus_scrape")
    
    assert @discovery.should_discover?
  end

  def test_should_discover_without_kubernetes_discovery_usage
    # Create latest-valid-vector.yaml without kubernetes_discovery_ reference
    vector_path = File.join(@test_dir, 'latest-valid-vector.yaml')
    File.write(vector_path, "sources:\n  test:\n    type: file")
    
    assert !@discovery.should_discover?
  end

  def test_should_discover_no_vector_yaml
    assert !@discovery.should_discover?
  end

  def test_run_not_in_kubernetes
    # Mock not in kubernetes environment
    @discovery.stub :in_kubernetes?, false do
      @discovery.stub :should_discover?, true do
        output = capture_io do
          result = @discovery.run
          assert_equal false, result
        end
        
        assert_match(/Not running in Kubernetes environment/, output.join)
      end
    end
  end

  def test_run_rate_limit
    # Mock should_discover and in_kubernetes
    @discovery.stub :should_discover?, true do
      @discovery.stub :in_kubernetes?, true do
        # Run once to set last_run_time
        @discovery.instance_variable_set(:@last_run_time, Time.now)
        
        output = capture_io do
          result = @discovery.run
          assert_equal false, result
        end
        
        assert_match(/Skipping kubernetes discovery - last run.*ago/, output.join)
      end
    end
  end

  def test_cleanup_old_versions
    # Create multiple version directories
    base_dir = File.join(@test_dir, 'kubernetes-discovery')
    versions = []
    10.times do |i|
      version = "2025-01-0#{i}T00:00:00"
      versions << version
      FileUtils.mkdir_p(File.join(base_dir, version))
    end
    
    output = capture_io do
      @discovery.cleanup_old_versions(5)
    end
    
    # Should keep only 5 latest versions
    remaining = Dir.glob(File.join(base_dir, '*')).select { |f| File.directory?(f) }
    remaining_names = remaining.map { |f| File.basename(f) }.sort
    
    assert_equal 6, remaining.length # 5 versions + 0-default
    assert remaining_names.include?('0-default')
    assert_match(/Cleaning up old kubernetes-discovery version/, output.join)
  end

  def test_get_workload_from_pod_direct_owner
    pod = {
      'metadata' => {
        'ownerReferences' => [{
          'kind' => 'DaemonSet',
          'name' => 'test-daemonset'
        }]
      }
    }
    
    result = @discovery.send(:get_workload_from_pod, pod, 'default')
    assert_equal 'daemonset/test-daemonset', result
  end

  def test_get_workload_from_pod_replicaset_to_deployment
    pod = {
      'metadata' => {
        'ownerReferences' => [{
          'kind' => 'ReplicaSet',
          'name' => 'test-deployment-abc123'
        }]
      }
    }
    
    replicaset = {
      'metadata' => {
        'ownerReferences' => [{
          'kind' => 'Deployment',
          'name' => 'test-deployment'
        }]
      }
    }
    
    # Mock kubernetes_request for ReplicaSet lookup
    @discovery.stub :kubernetes_request, replicaset do
      result = @discovery.send(:get_workload_from_pod, pod, 'default')
      assert_equal 'deployment/test-deployment', result
    end
  end

  def test_get_workload_from_pod_no_owner
    pod = {
      'metadata' => {
        'ownerReferences' => []
      }
    }
    
    result = @discovery.send(:get_workload_from_pod, pod, 'default')
    assert_nil result
  end

  def test_generate_config
    endpoint_info = {
      name: 'test-namespace_test-pod',
      endpoint: 'http://10.0.0.1:9090/metrics',
      namespace: 'test-namespace',
      pod: 'test-pod',
      service: 'test-service',
      pod_ip: '10.0.0.1',
      workload: 'deployment/test-app'
    }
    
    result = @discovery.send(:generate_config, endpoint_info)
    
    assert result[:filename]
    assert result[:filename].start_with?('test-namespace_test-pod-')
    assert result[:filename].end_with?('.yaml')
    
    config = result[:content]
    assert_equal 'prometheus_scrape', config['sources']['kubernetes_discovery_test-namespace_test-pod']['type']
    assert_equal ['http://10.0.0.1:9090/metrics'], config['sources']['kubernetes_discovery_test-namespace_test-pod']['endpoints']
    assert_equal 30, config['sources']['kubernetes_discovery_test-namespace_test-pod']['scrape_interval_secs']
    
    labels = config['sources']['kubernetes_discovery_test-namespace_test-pod']['labels']
    assert_equal 'test-namespace', labels['namespace']
    assert_equal 'test-pod', labels['pod']
    assert_equal '10.0.0.1', labels['pod_ip']
    assert_equal 'test-service', labels['service']
    assert_equal 'deployment/test-app', labels['workload']
  end

  def test_generate_config_without_service_and_workload
    endpoint_info = {
      name: 'test-namespace_test-pod',
      endpoint: 'http://10.0.0.1:9090/metrics',
      namespace: 'test-namespace',
      pod: 'test-pod',
      service: nil,
      pod_ip: '10.0.0.1',
      workload: nil
    }
    
    result = @discovery.send(:generate_config, endpoint_info)
    config = result[:content]
    labels = config['sources']['kubernetes_discovery_test-namespace_test-pod']['labels']
    
    assert !labels.key?('service')
    assert !labels.key?('workload')
  end

  def test_configs_identical_true
    dir1 = File.join(@test_dir, 'dir1')
    dir2 = File.join(@test_dir, 'dir2')
    FileUtils.mkdir_p(dir1)
    FileUtils.mkdir_p(dir2)
    
    # Create identical files
    File.write(File.join(dir1, 'test.yaml'), "content: same")
    File.write(File.join(dir2, 'test.yaml'), "content: same")
    
    assert @discovery.send(:configs_identical?, dir1, dir2)
  end

  def test_configs_identical_false_different_files
    dir1 = File.join(@test_dir, 'dir1')
    dir2 = File.join(@test_dir, 'dir2')
    FileUtils.mkdir_p(dir1)
    FileUtils.mkdir_p(dir2)
    
    # Create different files
    File.write(File.join(dir1, 'test1.yaml'), "content: 1")
    File.write(File.join(dir2, 'test2.yaml'), "content: 2")
    
    assert !@discovery.send(:configs_identical?, dir1, dir2)
  end

  def test_configs_identical_false_different_content
    dir1 = File.join(@test_dir, 'dir1')
    dir2 = File.join(@test_dir, 'dir2')
    FileUtils.mkdir_p(dir1)
    FileUtils.mkdir_p(dir2)
    
    # Create files with different content
    File.write(File.join(dir1, 'test.yaml'), "content: 1")
    File.write(File.join(dir2, 'test.yaml'), "content: 2")
    
    assert !@discovery.send(:configs_identical?, dir1, dir2)
  end
end