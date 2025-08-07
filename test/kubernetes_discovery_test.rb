require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require 'json'
require_relative '../engine/kubernetes_discovery'

class KubernetesDiscoveryTest < Minitest::Test
  def setup
    @test_dir = Dir.mktmpdir

    # Set NODE_NAME for tests BEFORE creating the discovery object
    ENV['HOSTNAME'] = 'test-node'

    # Now create the discovery object which will read ENV['HOSTNAME']
    @discovery = KubernetesDiscovery.new(@test_dir)

    # Create kubernetes-discovery directory structure
    FileUtils.mkdir_p(File.join(@test_dir, 'kubernetes-discovery', '0-default'))
    File.write(File.join(@test_dir, 'kubernetes-discovery', '0-default', 'dummy.yaml'), "sources: {}")
  end

  def teardown
    FileUtils.rm_rf(@test_dir)
    ENV.delete('HOSTNAME')
  end

  def test_should_discover_with_kubernetes_discovery_usage
    # Create latest-valid-upstream directory with vector.yaml containing kubernetes_discovery_ reference
    upstream_dir = File.join(@test_dir, 'vector-config', 'latest-valid-upstream')
    FileUtils.mkdir_p(upstream_dir)
    File.write(File.join(upstream_dir, 'vector.yaml'), "sources:\n  kubernetes_discovery_test:\n    type: prometheus_scrape")

    assert @discovery.should_discover?
  end

  def test_should_not_discover_without_kubernetes_discovery_usage
    # Create latest-valid-upstream directory with vector.yaml without kubernetes_discovery_ reference
    upstream_dir = File.join(@test_dir, 'vector-config', 'latest-valid-upstream')
    FileUtils.mkdir_p(upstream_dir)
    File.write(File.join(upstream_dir, 'vector.yaml'), "sources:\n  test:\n    type: file")

    assert !@discovery.should_discover?
  end

  def test_should_not_discover_when_no_vector_yaml_exists
    assert !@discovery.should_discover?
  end

  def test_run_returns_false_when_not_in_kubernetes
    # Mock not in kubernetes environment
    discover_and_update_called = false

    @discovery.stub :in_kubernetes?, false do
      @discovery.stub :should_discover?, true do
        @discovery.stub :discover_and_update, -> {
          discover_and_update_called = true
          true
        } do
          result = @discovery.run
          assert_equal false, result
          assert !discover_and_update_called, "discover_and_update should not be called when not in kubernetes"
        end
      end
    end
  end

  def test_run_returns_false_when_rate_limited
    # Mock should_discover and in_kubernetes
    discover_and_update_called = false

    @discovery.stub :should_discover?, true do
      @discovery.stub :in_kubernetes?, true do
        @discovery.stub :discover_and_update, -> {
          discover_and_update_called = true
          true
        } do
          # Set last_run_time to simulate recent run
          @discovery.instance_variable_set(:@last_run_time, Time.now)

          # Should skip due to rate limiting
          result = @discovery.run
          assert_equal false, result
          assert !discover_and_update_called, "discover_and_update should not be called when rate limited"
        end
      end
    end
  end

  def test_cleanup_old_versions_keeps_only_specified_number
    # Create multiple version directories
    base_dir = File.join(@test_dir, 'kubernetes-discovery')
    versions = []
    10.times do |i|
      version = "2025-01-0#{i}T00:00:00"
      versions << version
      FileUtils.mkdir_p(File.join(base_dir, version))
    end

    @discovery.cleanup_old_versions(5)

    # Test actual outcome - should keep only 5 latest versions + 0-default
    remaining = Dir.glob(File.join(base_dir, '*')).select { |f| File.directory?(f) }
    remaining_names = remaining.map { |f| File.basename(f) }.sort

    assert_equal 6, remaining.length # 5 versions + 0-default
    assert remaining_names.include?('0-default')

    # Verify oldest versions were deleted
    assert !File.exist?(File.join(base_dir, '2025-01-00T00:00:00'))
    assert !File.exist?(File.join(base_dir, '2025-01-01T00:00:00'))
    assert !File.exist?(File.join(base_dir, '2025-01-02T00:00:00'))
    assert !File.exist?(File.join(base_dir, '2025-01-03T00:00:00'))
    assert !File.exist?(File.join(base_dir, '2025-01-04T00:00:00'))
  end

  def test_get_workload_info_returns_direct_owner_type
    pod = {
      'metadata' => {
        'ownerReferences' => [{
          'kind' => 'DaemonSet',
          'name' => 'test-daemonset'
        }]
      }
    }

    result = @discovery.send(:get_workload_info, pod, 'default')
    assert_equal 'test-daemonset', result[:daemonset]
    assert_nil result[:deployment]
    assert_nil result[:statefulset]
    assert_nil result[:replicaset]
  end

  def test_get_workload_info_follows_replicaset_to_deployment
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
      result = @discovery.send(:get_workload_info, pod, 'default')
      assert_equal 'test-deployment', result[:deployment]
      assert_equal 'test-deployment-abc123', result[:replicaset]
      assert_nil result[:statefulset]
      assert_nil result[:daemonset]
    end
  end

  def test_get_workload_info_returns_empty_hash_when_no_owner
    pod = {
      'metadata' => {
        'ownerReferences' => []
      }
    }

    result = @discovery.send(:get_workload_info, pod, 'default')
    assert_nil result[:deployment]
    assert_nil result[:statefulset]
    assert_nil result[:daemonset]
    assert_nil result[:replicaset]
  end

  def test_generate_config_creates_prometheus_scrape_source
    endpoint_info = {
      name: 'test-namespace_test-pod',
      endpoint: 'http://10.0.0.1:9090/metrics',
      namespace: 'test-namespace',
      pod: 'test-pod',
      service: 'test-service',
      node_name: 'test-node',
      pod_uid: 'abc123',
      deployment_name: 'test-app'
    }

    result = @discovery.send(:generate_config, endpoint_info)

    assert result[:filename]
    assert result[:filename].start_with?('test-namespace_test-pod-')
    assert result[:filename].end_with?('.yaml')

    config = result[:content]
    source_name = 'prometheus_scrape_test-namespace_test-pod'
    transform_name = 'kubernetes_discovery_test-namespace_test-pod'

    # Check source
    assert_equal 'prometheus_scrape', config['sources'][source_name]['type']
    assert_equal ['http://10.0.0.1:9090/metrics'], config['sources'][source_name]['endpoints']
    assert_equal 30, config['sources'][source_name]['scrape_interval_secs']
    assert_equal 'instance', config['sources'][source_name]['instance_tag']

    # Check transform
    assert_equal 'remap', config['transforms'][transform_name]['type']
    assert_equal [source_name], config['transforms'][transform_name]['inputs']

    # Check remap source includes k8s labels
    remap_source = config['transforms'][transform_name]['source']
    assert_match /\.tags\."resource\.k8s\.namespace\.name" = "test-namespace"/, remap_source
    assert_match /\.tags\."resource\.k8s\.pod\.name" = "test-pod"/, remap_source
    assert_match /\.tags\."resource\.k8s\.node\.name" = "test-node"/, remap_source
    assert_match /\.tags\."resource\.k8s\.deployment\.name" = "test-app"/, remap_source
  end

  def test_generate_config_excludes_nil_labels
    endpoint_info = {
      name: 'test-namespace_test-pod',
      endpoint: 'http://10.0.0.1:9090/metrics',
      namespace: 'test-namespace',
      pod: 'test-pod',
      service: nil,
      deployment_name: nil,
      node_name: nil
    }

    result = @discovery.send(:generate_config, endpoint_info)
    config = result[:content]
    transform_name = 'kubernetes_discovery_test-namespace_test-pod'
    remap_source = config['transforms'][transform_name]['source']

    # Should include namespace and pod
    assert_match /\.tags\."resource\.k8s\.namespace\.name" = "test-namespace"/, remap_source
    assert_match /\.tags\."resource\.k8s\.pod\.name" = "test-pod"/, remap_source

    # Should not include nil fields
    refute_match /deployment_name/, remap_source
    refute_match /node_name/, remap_source
  end

  def test_configs_identical_returns_true_for_same_content
    dir1 = File.join(@test_dir, 'dir1')
    dir2 = File.join(@test_dir, 'dir2')
    FileUtils.mkdir_p(dir1)
    FileUtils.mkdir_p(dir2)

    # Create identical files
    File.write(File.join(dir1, 'test.yaml'), "content: same")
    File.write(File.join(dir2, 'test.yaml'), "content: same")

    assert @discovery.send(:configs_identical?, dir1, dir2)
  end

  def test_configs_identical_returns_false_for_different_files
    dir1 = File.join(@test_dir, 'dir1')
    dir2 = File.join(@test_dir, 'dir2')
    FileUtils.mkdir_p(dir1)
    FileUtils.mkdir_p(dir2)

    # Create different files
    File.write(File.join(dir1, 'test1.yaml'), "content: 1")
    File.write(File.join(dir2, 'test2.yaml'), "content: 2")

    assert !@discovery.send(:configs_identical?, dir1, dir2)
  end

  def test_configs_identical_returns_false_for_different_content
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