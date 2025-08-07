require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require 'yaml'
require_relative '../engine/kubernetes_discovery'

class KubernetesDiscoveryIntegrationTest < Minitest::Test
  def setup
    @test_dir = Dir.mktmpdir

    # Set NODE_NAME for tests BEFORE creating the discovery object
    ENV['HOSTNAME'] = 'test-node'
    ENV['KUBERNETES_SERVICE_HOST'] = 'kubernetes.default.svc'
    ENV['KUBERNETES_SERVICE_PORT'] = '443'

    # Now create the discovery object which will read ENV['HOSTNAME']
    @discovery = KubernetesDiscovery.new(@test_dir)

    # Create required directories
    FileUtils.mkdir_p(File.join(@test_dir, 'kubernetes-discovery', '0-default'))
  end

  def teardown
    FileUtils.rm_rf(@test_dir)
    ENV.delete('HOSTNAME')
    ENV.delete('KUBERNETES_SERVICE_HOST')
    ENV.delete('KUBERNETES_SERVICE_PORT')
  end

  def test_discover_and_update_finds_service_endpoints_and_standalone_pods
    # Create latest-valid-upstream with vector.yaml that uses kubernetes_discovery
    upstream_dir = File.join(@test_dir, 'vector-config', 'latest-valid-upstream')
    FileUtils.mkdir_p(upstream_dir)
    File.write(File.join(upstream_dir, 'vector.yaml'), "sources:\n  kubernetes_discovery_test:\n    type: prometheus_scrape")

    # Mock being in Kubernetes
    @discovery.stub :in_kubernetes?, true do
      @discovery.stub :read_service_account_token, 'test-token' do
        @discovery.stub :read_namespace, 'default' do
          @discovery.stub :read_ca_cert, nil do

            # Mock API responses for various workload types
            mock_responses = {
              '/api/v1/namespaces' => {
                'items' => [
                  { 'metadata' => { 'name' => 'default' } },
                  { 'metadata' => { 'name' => 'kube-system' } }
                ]
              },
              '/api/v1/namespaces/default/services' => {
                'items' => [
                  {
                    'metadata' => {
                      'name' => 'webapp-service',
                      'annotations' => {
                        'prometheus.io/scrape' => 'true',
                        'prometheus.io/port' => '8080',
                        'prometheus.io/path' => '/metrics'
                      }
                    }
                  }
                ]
              },
              '/api/v1/namespaces/default/endpoints/webapp-service' => {
                'subsets' => [{
                  'addresses' => [{
                    'ip' => '10.0.0.1',
                    'targetRef' => {
                      'kind' => 'Pod',
                      'name' => 'webapp-deployment-abc123-xyz'
                    }
                  }]
                }]
              },
              '/api/v1/namespaces/default/pods/webapp-deployment-abc123-xyz' => {
                'spec' => { 'nodeName' => 'test-node' },
                'metadata' => {
                  'ownerReferences' => [{
                    'kind' => 'ReplicaSet',
                    'name' => 'webapp-deployment-abc123'
                  }]
                }
              },
              '/apis/apps/v1/namespaces/default/replicasets/webapp-deployment-abc123' => {
                'metadata' => {
                  'ownerReferences' => [{
                    'kind' => 'Deployment',
                    'name' => 'webapp-deployment'
                  }]
                }
              },
              '/api/v1/namespaces/kube-system/services' => { 'items' => [] },
              '/api/v1/namespaces/default/pods' => {
                'items' => [
                  {
                    'metadata' => {
                      'name' => 'cronjob-1234',
                      'annotations' => {
                        'prometheus.io/scrape' => 'true',
                        'prometheus.io/port' => '9090'
                      },
                      'ownerReferences' => [{
                        'kind' => 'Job',
                        'name' => 'scheduled-job-1234'
                      }]
                    },
                    'spec' => { 'nodeName' => 'test-node' },
                    'status' => {
                      'phase' => 'Running',
                      'podIP' => '10.0.0.2'
                    }
                  },
                  {
                    'metadata' => {
                      'name' => 'standalone-pod',
                      'annotations' => {
                        'prometheus.io/scrape' => 'true',
                        'prometheus.io/port' => '9090'
                      },
                      # No ownerReferences key at all for truly standalone pod
                    },
                    'spec' => { 'nodeName' => 'test-node' },
                    'status' => {
                      'phase' => 'Running',
                      'podIP' => '10.0.0.3'
                    }
                  }
                ]
              },
              '/api/v1/namespaces/kube-system/pods' => { 'items' => [] }
            }

            # Mock kubernetes_request to return appropriate responses
            @discovery.stub :kubernetes_request, ->(path) { mock_responses[path] || { 'items' => [] } } do
              # Mock validation to pass
              @discovery.stub :validate_configs, true do

                result = @discovery.send(:discover_and_update)
                assert result

                # Verify generated files
                discovery_dir = Dir.glob(File.join(@test_dir, 'kubernetes-discovery', '2*')).first
                assert discovery_dir

                files = Dir.glob(File.join(discovery_dir, '*.yaml')).sort
                # Filter out discovered_pods.yaml
                config_files = files.reject { |f| f.include?('discovered_pods.yaml') }
                # We expect 3 configs: service endpoint + cronjob pod + standalone pod
                # All pods with prometheus annotations should be discovered
                assert_equal 3, config_files.length

                # Check deployment workload
                # The filename includes the pod name, not the deployment name
                webapp_file = config_files.find { |f| f.include?('webapp-deployment-abc123-xyz') }
                assert webapp_file, "Could not find webapp file in: #{config_files.map { |f| File.basename(f) }}"
                webapp_config = YAML.load_file(webapp_file)
                # Check transform remap source for k8s.deployment.name
                transform_source = webapp_config['transforms'].values.first['source']
                assert_match /\.tags\."resource\.k8s\.deployment\.name" = "webapp-deployment"/, transform_source

                # Check job workload (cronjob pod)
                job_file = config_files.find { |f| f.include?('cronjob') }
                assert job_file, "Should find cronjob pod file"
                job_config = YAML.load_file(job_file)
                # Jobs don't have deployment/statefulset/daemonset labels
                transform_source = job_config['transforms'].values.first['source']
                refute_match /resource\.k8s\.deployment\.name/, transform_source
                refute_match /resource\.k8s\.statefulset\.name/, transform_source
                refute_match /resource\.k8s\.daemonset\.name/, transform_source

                # Check standalone pod (no workload)
                standalone_file = config_files.find { |f| f.include?('standalone') }
                assert standalone_file
                standalone_config = YAML.load_file(standalone_file)
                transform_source = standalone_config['transforms'].values.first['source']
                # Should have basic k8s labels but no workload labels
                assert_match /resource\.k8s\.namespace\.name/, transform_source
                assert_match /resource\.k8s\.pod\.name/, transform_source
                refute_match /resource\.k8s\.deployment\.name/, transform_source
              end
            end
          end
        end
      end
    end
  end

  def test_node_filtering_discovers_only_pods_on_current_node
    # Create latest-valid-upstream with vector.yaml that uses kubernetes_discovery
    upstream_dir = File.join(@test_dir, 'vector-config', 'latest-valid-upstream')
    FileUtils.mkdir_p(upstream_dir)
    File.write(File.join(upstream_dir, 'vector.yaml'), "sources:\n  kubernetes_discovery_test:\n    type: prometheus_scrape")

    # Mock being in Kubernetes
    @discovery.stub :in_kubernetes?, true do
      @discovery.stub :read_service_account_token, 'test-token' do
        @discovery.stub :read_namespace, 'default' do
          @discovery.stub :read_ca_cert, nil do

            # Mock API responses with pods on different nodes
            mock_responses = {
              '/api/v1/namespaces' => {
                'items' => [{ 'metadata' => { 'name' => 'default' } }]
              },
              '/api/v1/namespaces/default/services' => {
                'items' => [{
                  'metadata' => {
                    'name' => 'multi-node-service',
                    'annotations' => {
                      'prometheus.io/scrape' => 'true',
                      'prometheus.io/port' => '8080'
                    }
                  }
                }]
              },
              '/api/v1/namespaces/default/endpoints/multi-node-service' => {
                'subsets' => [{
                  'addresses' => [
                    {
                      'ip' => '10.0.0.1',
                      'targetRef' => { 'kind' => 'Pod', 'name' => 'pod-on-our-node' }
                    },
                    {
                      'ip' => '10.0.0.2',
                      'targetRef' => { 'kind' => 'Pod', 'name' => 'pod-on-other-node' }
                    }
                  ]
                }]
              },
              '/api/v1/namespaces/default/pods/pod-on-our-node' => {
                'spec' => { 'nodeName' => 'test-node' },
                'metadata' => {
                  'ownerReferences' => [{
                    'kind' => 'DaemonSet',
                    'name' => 'node-agent'
                  }]
                }
              },
              '/api/v1/namespaces/default/pods/pod-on-other-node' => {
                'spec' => { 'nodeName' => 'other-node' },
                'metadata' => {
                  'ownerReferences' => [{
                    'kind' => 'DaemonSet',
                    'name' => 'node-agent'
                  }]
                }
              },
              '/api/v1/namespaces/default/pods' => { 'items' => [] }
            }

            @discovery.stub :kubernetes_request, ->(path) { mock_responses[path] || { 'items' => [] } } do
              @discovery.stub :validate_configs, true do

                result = @discovery.send(:discover_and_update)
                assert result

                # Verify only our node's pod was discovered
                discovery_dir = Dir.glob(File.join(@test_dir, 'kubernetes-discovery', '2*')).first
                files = Dir.glob(File.join(discovery_dir, '*.yaml'))
                # Filter out discovered_pods.yaml
                config_files = files.reject { |f| f.include?('discovered_pods.yaml') }
                assert_equal 1, config_files.length
                assert config_files.first.include?('pod-on-our-node')
              end
            end
          end
        end
      end
    end
  end

  def test_deduplication_prevents_duplicate_configs_for_same_pod
    # Create latest-valid-upstream with vector.yaml that uses kubernetes_discovery
    upstream_dir = File.join(@test_dir, 'vector-config', 'latest-valid-upstream')
    FileUtils.mkdir_p(upstream_dir)
    File.write(File.join(upstream_dir, 'vector.yaml'), "sources:\n  kubernetes_discovery_test:\n    type: prometheus_scrape")

    # Mock being in Kubernetes
    @discovery.stub :in_kubernetes?, true do
      @discovery.stub :read_service_account_token, 'test-token' do
        @discovery.stub :read_namespace, 'default' do
          @discovery.stub :read_ca_cert, nil do

            # Mock multiple services pointing to same pod
            mock_responses = {
              '/api/v1/namespaces' => {
                'items' => [{ 'metadata' => { 'name' => 'default' } }]
              },
              '/api/v1/namespaces/default/services' => {
                'items' => [
                  {
                    'metadata' => {
                      'name' => 'service-a',
                      'annotations' => {
                        'prometheus.io/scrape' => 'true',
                        'prometheus.io/port' => '8080'
                      }
                    }
                  },
                  {
                    'metadata' => {
                      'name' => 'service-b',
                      'annotations' => {
                        'prometheus.io/scrape' => 'true',
                        'prometheus.io/port' => '9090'
                      }
                    }
                  }
                ]
              },
              '/api/v1/namespaces/default/endpoints/service-a' => {
                'subsets' => [{
                  'addresses' => [{
                    'ip' => '10.0.0.1',
                    'targetRef' => { 'kind' => 'Pod', 'name' => 'shared-pod' }
                  }]
                }]
              },
              '/api/v1/namespaces/default/endpoints/service-b' => {
                'subsets' => [{
                  'addresses' => [{
                    'ip' => '10.0.0.1',
                    'targetRef' => { 'kind' => 'Pod', 'name' => 'shared-pod' }
                  }]
                }]
              },
              '/api/v1/namespaces/default/pods/shared-pod' => {
                'spec' => { 'nodeName' => 'test-node' },
                'metadata' => {
                  'ownerReferences' => [{
                    'kind' => 'Deployment',
                    'name' => 'shared-app'
                  }]
                }
              },
              '/api/v1/namespaces/default/pods' => { 'items' => [] }
            }

            @discovery.stub :kubernetes_request, ->(path) { mock_responses[path] || { 'items' => [] } } do
              @discovery.stub :validate_configs, true do

                result = @discovery.send(:discover_and_update)
                assert result

                # Verify deduplication worked
                discovery_dir = Dir.glob(File.join(@test_dir, 'kubernetes-discovery', '2*')).first
                files = Dir.glob(File.join(discovery_dir, '*.yaml'))
                # Filter out discovered_pods.yaml
                config_files = files.reject { |f| f.include?('discovered_pods.yaml') }
                assert_equal 1, config_files.length

                # Check that first service's config was kept
                config = YAML.load_file(config_files.first)
                source = config['sources'].values.first
                assert_equal ['http://10.0.0.1:8080/metrics'], source['endpoints']
              end
            end
          end
        end
      end
    end
  end

  def test_run_returns_false_on_kubernetes_api_error
    # Create latest-valid-upstream with vector.yaml that uses kubernetes_discovery
    upstream_dir = File.join(@test_dir, 'vector-config', 'latest-valid-upstream')
    FileUtils.mkdir_p(upstream_dir)
    File.write(File.join(upstream_dir, 'vector.yaml'), "sources:\n  kubernetes_discovery_test:\n    type: prometheus_scrape")

    # Mock being in Kubernetes
    @discovery.stub :in_kubernetes?, true do
      @discovery.stub :read_service_account_token, 'test-token' do
        @discovery.stub :read_namespace, 'default' do
          @discovery.stub :read_ca_cert, nil do

            # Mock API failure
            @discovery.stub :kubernetes_request, ->(_) { raise "Kubernetes API error: 401 Unauthorized" } do
              # Test actual behavior - should return false on API error
              result = @discovery.run
              assert_equal false, result
            end
          end
        end
      end
    end
  end
end