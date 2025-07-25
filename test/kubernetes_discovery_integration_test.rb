require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require 'yaml'
require_relative '../engine/kubernetes_discovery'

class KubernetesDiscoveryIntegrationTest < Minitest::Test
  def setup
    @test_dir = Dir.mktmpdir
    @discovery = KubernetesDiscovery.new(@test_dir)
    
    # Create required directories
    FileUtils.mkdir_p(File.join(@test_dir, 'kubernetes-discovery', '0-default'))
    
    # Set NODE_NAME for tests
    ENV['HOSTNAME'] = 'test-node'
    ENV['KUBERNETES_SERVICE_HOST'] = 'kubernetes.default.svc'
    ENV['KUBERNETES_SERVICE_PORT'] = '443'
  end

  def teardown
    FileUtils.rm_rf(@test_dir)
    ENV.delete('HOSTNAME')
    ENV.delete('KUBERNETES_SERVICE_HOST')
    ENV.delete('KUBERNETES_SERVICE_PORT')
  end

  def test_discover_and_update_with_complex_workloads
    # Create vector.yaml that uses kubernetes_discovery
    vector_path = File.join(@test_dir, 'latest-valid-vector.yaml')
    File.write(vector_path, "sources:\n  kubernetes_discovery_test:\n    type: prometheus_scrape")
    
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
                        'prometheus.io/scrape' => 'true'
                      },
                      'ownerReferences' => []
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
                
                output = capture_io do
                  result = @discovery.send(:discover_and_update)
                  assert result
                end
                
                # Verify output messages
                assert_match(/Starting Prometheus endpoint discovery/, output.join)
                assert_match(/Found workload for webapp-deployment-abc123-xyz: deployment\/webapp-deployment/, output.join)
                assert_match(/Generated 3 configs for kubernetes discovery/, output.join)
                
                # Verify generated files
                discovery_dir = Dir.glob(File.join(@test_dir, 'kubernetes-discovery', '2*')).first
                assert discovery_dir
                
                files = Dir.glob(File.join(discovery_dir, '*.yaml')).sort
                assert_equal 3, files.length
                
                # Check deployment workload
                webapp_file = files.find { |f| f.include?('webapp-deployment') }
                assert webapp_file
                webapp_config = YAML.load_file(webapp_file)
                assert_equal 'deployment/webapp-deployment', 
                             webapp_config['sources'].values.first['labels']['workload']
                
                # Check job workload
                job_file = files.find { |f| f.include?('cronjob') }
                assert job_file
                job_config = YAML.load_file(job_file)
                assert_equal 'job/scheduled-job-1234',
                             job_config['sources'].values.first['labels']['workload']
                
                # Check standalone pod (no workload)
                standalone_file = files.find { |f| f.include?('standalone') }
                assert standalone_file
                standalone_config = YAML.load_file(standalone_file)
                assert_nil standalone_config['sources'].values.first['labels']['workload']
              end
            end
          end
        end
      end
    end
  end

  def test_node_filtering_with_mixed_nodes
    # Create vector.yaml that uses kubernetes_discovery
    vector_path = File.join(@test_dir, 'latest-valid-vector.yaml')
    File.write(vector_path, "sources:\n  kubernetes_discovery_test:\n    type: prometheus_scrape")
    
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
                      'prometheus.io/scrape' => 'true'
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
                
                output = capture_io do
                  result = @discovery.send(:discover_and_update)
                  assert result
                end
                
                # Should only discover pod on our node
                assert_match(/Generated 1 configs for kubernetes discovery/, output.join)
                assert_match(/Filtering for node: test-node/, output.join)
                
                # Verify only our node's pod was discovered
                discovery_dir = Dir.glob(File.join(@test_dir, 'kubernetes-discovery', '2*')).first
                files = Dir.glob(File.join(discovery_dir, '*.yaml'))
                assert_equal 1, files.length
                assert files.first.include?('pod-on-our-node')
              end
            end
          end
        end
      end
    end
  end

  def test_deduplication_of_service_endpoints
    # Create vector.yaml that uses kubernetes_discovery
    vector_path = File.join(@test_dir, 'latest-valid-vector.yaml')
    File.write(vector_path, "sources:\n  kubernetes_discovery_test:\n    type: prometheus_scrape")
    
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
                
                output = capture_io do
                  result = @discovery.send(:discover_and_update)
                  assert result
                end
                
                # Should only generate one config for the shared pod
                assert_match(/Generated 1 configs for kubernetes discovery/, output.join)
                
                # Verify deduplication worked
                discovery_dir = Dir.glob(File.join(@test_dir, 'kubernetes-discovery', '2*')).first
                files = Dir.glob(File.join(discovery_dir, '*.yaml'))
                assert_equal 1, files.length
                
                # Check that first service's config was kept
                config = YAML.load_file(files.first)
                source = config['sources'].values.first
                assert_equal ['http://10.0.0.1:8080/metrics'], source['endpoints']
                assert_equal 'service-a', source['labels']['service']
              end
            end
          end
        end
      end
    end
  end

  def test_error_handling_during_discovery
    # Create vector.yaml that uses kubernetes_discovery
    vector_path = File.join(@test_dir, 'latest-valid-vector.yaml')
    File.write(vector_path, "sources:\n  kubernetes_discovery_test:\n    type: prometheus_scrape")
    
    # Mock being in Kubernetes
    @discovery.stub :in_kubernetes?, true do
      @discovery.stub :read_service_account_token, 'test-token' do
        @discovery.stub :read_namespace, 'default' do
          @discovery.stub :read_ca_cert, nil do
            
            # Mock API failure
            @discovery.stub :kubernetes_request, ->(_) { raise "Kubernetes API error: 401 Unauthorized" } do
              output = capture_io do
                result = @discovery.run
                assert_equal false, result
              end
              
              assert_match(/Error during kubernetes discovery/, output.join)
              assert_match(/Kubernetes API error: 401 Unauthorized/, output.join)
            end
          end
        end
      end
    end
  end
end