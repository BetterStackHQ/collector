require 'net/http'
require 'json'
require 'openssl'
require 'fileutils'
require 'yaml'
require 'time'
require 'digest'
require 'set'
require_relative 'utils'

# Generates a directory of configs for discovered Kubernetes pods. E.g. /kubernetes-discovery/2025-07-25T12:00:00/
# Directory contains one config per pod. E.g. /kubernetes-discovery/2025-07-25T12:00:00/monitoring-my-pod-1234567890.yaml
#
# All generated configs are guaranteed to be valid. Entire directory of configs is validated and removed if validation fails.
# New generated directory of configs is not kept if it's same as the latest version.

class KubernetesDiscovery
  include Utils
  SERVICE_ACCOUNT_PATH = '/var/run/secrets/kubernetes.io/serviceaccount'
  DUMMY_VECTOR_CONFIG = {
    'transforms' => {
      'kubernetes_discovery_test' => {
        'type' => 'remap',
        'inputs' => ['kubernetes_discovery_*'],
        'source' => '.test = "ok"'
      }
    },
    'sinks' => {
      'kubernetes_discovery_test_sink' => {
        'type' => 'blackhole',
        'inputs' => ['kubernetes_discovery_test']
      }
    }
  }

  def initialize(working_dir)
    @working_dir = working_dir
    @base_dir = File.join(working_dir, "kubernetes-discovery")
    @last_run_time = nil
    @node_name = ENV['HOSTNAME']
  end

  def self.vector_config_uses_kubernetes_discovery?(vector_config_dir)
    return false unless File.exist?(vector_config_dir)

    # Check all yaml files in latest-valid-upstream for kubernetes_discovery_
    Dir.glob(File.join(vector_config_dir, "*.yaml")).each do |config_file|
      if File.read(config_file).include?('kubernetes_discovery_')
        return true
      end
    end

    false
  end

  def should_discover?
    vector_config_dir = File.join(@working_dir, "vector-config", "latest-valid-upstream")
    self.class.vector_config_uses_kubernetes_discovery?(vector_config_dir)
  end

  def run
    unless should_discover?
      # Kubernetes discovery not used in vector config
      return false
    end

    current_time = Time.now
    if @last_run_time && (current_time - @last_run_time) < 30
      # Rate limited - last run was too recent
      return false
    end
    @last_run_time = current_time

    unless in_kubernetes?
      # Not in Kubernetes environment
      return false
    end

    @base_url = "https://#{ENV['KUBERNETES_SERVICE_HOST']}:#{ENV['KUBERNETES_SERVICE_PORT']}"
    @token = read_service_account_token
    @namespace = read_namespace
    @ca_cert = read_ca_cert

    begin
      discover_and_update
    rescue => e
      puts "Kubernetes discovery failed: #{e.class.name}: #{e.message}"
      false
    end
  end

  def cleanup_old_versions(keep_count = 5)
    versions = Dir.glob(File.join(@base_dir, "*")).select { |f| File.directory?(f) }
    versions = versions.reject { |v| v.end_with?('/0-default') }
    versions.sort!

    if versions.length > keep_count
      to_delete = versions[0...(versions.length - keep_count)]
      to_delete.each do |dir|
        # Cleaning up old kubernetes-discovery version
        FileUtils.rm_rf(dir)
      end
    end
  end

  private

  def in_kubernetes?
    return false unless ENV['KUBERNETES_SERVICE_HOST']
    return false unless File.exist?(SERVICE_ACCOUNT_PATH)
    true
  end

  def read_service_account_token
    token_path = "#{SERVICE_ACCOUNT_PATH}/token"
    return nil unless File.exist?(token_path)
    File.read(token_path).strip
  end

  def read_namespace
    namespace_path = "#{SERVICE_ACCOUNT_PATH}/namespace"
    return 'default' unless File.exist?(namespace_path)
    File.read(namespace_path).strip
  end

  def read_ca_cert
    ca_path = "#{SERVICE_ACCOUNT_PATH}/ca.crt"
    return nil unless File.exist?(ca_path)
    OpenSSL::X509::Certificate.new(File.read(ca_path))
  end

  def kubernetes_request(path)
    uri = URI("#{@base_url}#{path}")

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_PEER

    if @ca_cert
      store = OpenSSL::X509::Store.new
      store.add_cert(@ca_cert)
      http.cert_store = store
    end

    request = Net::HTTP::Get.new(uri)
    request['Authorization'] = "Bearer #{@token}"
    request['Accept'] = 'application/json'

    response = http.request(request)

    unless response.code == '200'
      raise "Kubernetes API request failed: #{response.code} #{response.body}"
    end

    JSON.parse(response.body)
  end

  def discover_and_update
    latest_dir = latest_kubernetes_discovery

    # Create new version directory
    timestamp = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S')
    new_dir = File.join(@base_dir, timestamp)
    FileUtils.mkdir_p(new_dir)

    # Get all namespaces we have access to
    namespaces = get_namespaces

    # Use hash to store configs by namespace_pod key to avoid duplicates
    discovered_configs = {}

    namespaces.each do |namespace|
      # Discover services with prometheus annotations
      services = get_annotated_services(namespace)

      services.each do |service|
        endpoints = get_service_endpoints(service, namespace)

        endpoints.each do |endpoint|
          # Use namespace_pod as key for deduplication
          config_key = endpoint[:name]  # This is already "namespace_pod"

          # Skip if we already have a config for this pod
          next if discovered_configs.has_key?(config_key)

          config = generate_config(endpoint)
          if config
            discovered_configs[config_key] = config
          end
        end
      end

      # Discover standalone pods (those not backing services)
      pods = get_annotated_pods(namespace)

      pods.each do |pod|
        endpoint = get_pod_endpoint(pod, namespace)
        if endpoint
          # Use namespace_pod as key for deduplication
          config_key = endpoint[:name]  # This is already "namespace_pod"

          # Skip if we already have a config for this pod (discovered via service)
          next if discovered_configs.has_key?(config_key)

          config = generate_config(endpoint)
          if config
            discovered_configs[config_key] = config
          end
        end
      end
    end

    # Write all configs to disk at once
    configs_generated = 0
    discovered_configs.each do |key, config|
      filepath = File.join(new_dir, config[:filename])
      File.write(filepath, config[:content].to_yaml)
      configs_generated += 1
    end

    # Always generate discovered_pods.yaml with the count of discovered pods
    discovered_pods_config = {
      'sources' => {
        'kubernetes_discovery_static_metrics' => {
          'type' => 'static_metrics',
          'namespace' => '',  # Empty namespace to avoid "static_" prefix
          'metrics' => [
            {
              'name' => 'collector_kubernetes_discovered_pods',
              'kind' => 'absolute',
              'value' => {
                'gauge' => {
                  'value' => configs_generated
                }
              },
              'tags' => {}
            }
          ]
        }
      }
    }
    File.write(File.join(new_dir, 'discovered_pods.yaml'), discovered_pods_config.to_yaml)

    # Validate the generated configs
    unless validate_configs(new_dir)
      puts "Kubernetes discovery: validation failed"
      FileUtils.rm_rf(new_dir)
      return false
    end

    # Check if configs changed from latest version
    if latest_dir && configs_identical?(latest_dir, new_dir)
      FileUtils.rm_rf(new_dir)
      return false
    end

    puts "Kubernetes discovery: Generated configs for #{configs_generated} pods"

    # Clean up old versions
    cleanup_old_versions

    true
  end

  def get_namespaces
    begin
      result = kubernetes_request('/api/v1/namespaces')
      result['items'].map { |ns| ns['metadata']['name'] }
    rescue => e
      puts "Kubernetes discovery: Failed to list namespaces (#{e.message}), using current namespace"
      [@namespace]
    end
  end

  def get_annotated_services(namespace)
    services = kubernetes_request("/api/v1/namespaces/#{namespace}/services")

    services['items'].select do |service|
      annotations = service.dig('metadata', 'annotations') || {}
      annotations['prometheus.io/scrape'] == 'true'
    end
  end

  def get_annotated_pods(namespace)
    pods = kubernetes_request("/api/v1/namespaces/#{namespace}/pods")

    pods['items'].select do |pod|
      annotations = pod.dig('metadata', 'annotations') || {}
      node_name = pod.dig('spec', 'nodeName')

      # Select all running pods with prometheus scrape annotation on the current node
      annotations['prometheus.io/scrape'] == 'true' &&
        pod['status']['phase'] == 'Running' &&
        (@node_name.nil? || node_name == @node_name) # If NODE_NAME not set, discover all pods
    end
  end

  def get_service_endpoints(service, namespace)
    service_name = service['metadata']['name']
    annotations = service['metadata']['annotations']

    port = annotations['prometheus.io/port'] || '9090'
    path = annotations['prometheus.io/path'] || '/metrics'

    # Get endpoints for this service
    endpoints = kubernetes_request("/api/v1/namespaces/#{namespace}/endpoints/#{service_name}")

    results = []

    (endpoints['subsets'] || []).each do |subset|
      addresses = subset['addresses'] || []
      addresses.each do |address|
        pod_name = address.dig('targetRef', 'name')

        # Skip if we have NODE_NAME set and need to check pod's node
        pod_metadata = {}
        if pod_name
          begin
            pod = kubernetes_request("/api/v1/namespaces/#{namespace}/pods/#{pod_name}")

            if @node_name
              node_name = pod.dig('spec', 'nodeName')
              next unless node_name == @node_name
            end

            # Extract workload information from ownerReferences
            workload_info = get_workload_info(pod, namespace)

            # Extract container names
            containers = pod.dig('spec', 'containers') || []
            container_names = containers.map { |c| c['name'] }

            # Collect pod metadata
            pod_metadata = {
              pod_uid: pod.dig('metadata', 'uid'),
              node_name: pod.dig('spec', 'nodeName'),
              start_time: pod.dig('status', 'startTime'),
              container_names: container_names,
              deployment_name: workload_info[:deployment],
              statefulset_name: workload_info[:statefulset],
              daemonset_name: workload_info[:daemonset],
              replicaset_name: workload_info[:replicaset]
            }
          rescue => e
            puts "Kubernetes discovery: Failed to get pod info for #{pod_name}: #{e.message}"
            next if @node_name  # Skip if we need node filtering but couldn't get pod info
          end
        end

        results << {
          name: "#{namespace}_#{pod_name || service_name}",
          endpoint: "http://#{address['ip']}:#{port}#{path}",
          namespace: namespace,
          pod: pod_name,
          service: service_name
        }.merge(pod_metadata)
      end
    end

    results
  end

  def get_pod_endpoint(pod, namespace)
    annotations = pod['metadata']['annotations']
    pod_name = pod['metadata']['name']
    pod_ip = pod.dig('status', 'podIP')

    return nil unless pod_ip

    port = annotations['prometheus.io/port'] || '9090'
    path = annotations['prometheus.io/path'] || '/metrics'

    # Extract workload information from ownerReferences
    workload_info = get_workload_info(pod, namespace)

    # Extract container names
    containers = pod.dig('spec', 'containers') || []
    container_names = containers.map { |c| c['name'] }

    {
      name: "#{namespace}_#{pod_name}",
      endpoint: "http://#{pod_ip}:#{port}#{path}",
      namespace: namespace,
      pod: pod_name,
      service: nil,
      # k8s metadata for labels
      pod_uid: pod.dig('metadata', 'uid'),
      node_name: pod.dig('spec', 'nodeName'),
      start_time: pod.dig('status', 'startTime'),
      container_names: container_names,
      deployment_name: workload_info[:deployment],
      statefulset_name: workload_info[:statefulset],
      daemonset_name: workload_info[:daemonset],
      replicaset_name: workload_info[:replicaset]
    }
  end

  def generate_config(endpoint_info)
    return nil unless endpoint_info

    source_name = "prometheus_scrape_#{endpoint_info[:name]}"
    transform_name = "kubernetes_discovery_#{endpoint_info[:name]}"

    config = {
      'sources' => {
        source_name => {
          'type' => 'prometheus_scrape',
          'endpoints' => [endpoint_info[:endpoint]],
          'scrape_interval_secs' => 30,
          'instance_tag' => 'instance'  # This will add instance="host:port" tag
        }
      },
      'transforms' => {
        transform_name => {
          'type' => 'remap',
          'inputs' => [source_name],
          'source' => ''  # Will be built below
        }
      }
    }

    # Build remap source to add all k8s labels
    remap_lines = []

    # Add labels
    remap_lines << ".tags.\"k8s.namespace.name\" = \"#{endpoint_info[:namespace]}\""
    remap_lines << ".tags.\"k8s.pod.name\" = \"#{endpoint_info[:pod]}\""

    # Add new k8s labels if present
    remap_lines << ".tags.\"k8s.node.name\" = \"#{endpoint_info[:node_name]}\"" if endpoint_info[:node_name]
    remap_lines << ".tags.\"k8s.pod.uid\" = \"#{endpoint_info[:pod_uid]}\"" if endpoint_info[:pod_uid]
    remap_lines << ".tags.\"k8s.pod.start_time\" = \"#{endpoint_info[:start_time]}\"" if endpoint_info[:start_time]

    # Add workload-specific labels
    remap_lines << ".tags.\"k8s.deployment.name\" = \"#{endpoint_info[:deployment_name]}\"" if endpoint_info[:deployment_name]
    remap_lines << ".tags.\"k8s.statefulset.name\" = \"#{endpoint_info[:statefulset_name]}\"" if endpoint_info[:statefulset_name]
    remap_lines << ".tags.\"k8s.daemonset.name\" = \"#{endpoint_info[:daemonset_name]}\"" if endpoint_info[:daemonset_name]
    remap_lines << ".tags.\"k8s.replicaset.name\" = \"#{endpoint_info[:replicaset_name]}\"" if endpoint_info[:replicaset_name]

    # Add container names if present
    if endpoint_info[:container_names] && !endpoint_info[:container_names].empty?
      remap_lines << ".tags.\"k8s.container.name\" = \"#{endpoint_info[:container_names].join(',')}\""
    end

    config['transforms'][transform_name]['source'] = remap_lines.join("\n")

    config_md5 = Digest::MD5.hexdigest(config.to_yaml)
    filename = "#{endpoint_info[:name]}-#{config_md5}.yaml"

    {
      filename: filename,
      content: config
    }
  end

  def validate_configs(config_dir)
    timestamp = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S')
    tmp_dir = "/tmp/validate-kubernetes-discovery-#{timestamp}"
    FileUtils.rm_rf(tmp_dir) if File.exist?(tmp_dir)
    FileUtils.mkdir_p(tmp_dir)

    begin
      # Copy generated configs
      FileUtils.cp_r(config_dir, "#{tmp_dir}/kubernetes-discovery")

      # Write dummy vector config that consumes our sources
      File.write("#{tmp_dir}/vector.yaml", DUMMY_VECTOR_CONFIG.to_yaml)

      # Run validation
      output = `REGION=unknown AZ=unknown vector validate #{tmp_dir}/vector.yaml #{tmp_dir}/kubernetes-discovery/\*.yaml 2>&1`
      success = $?.success?

      unless success
        puts "Error: Kubernetes discovery validation failed"
        puts output
      end

      return success
    ensure
      FileUtils.rm_rf(tmp_dir)
    end
  end

  def configs_identical?(dir1, dir2)
    files1 = Dir.glob("#{dir1}/*.yaml").map { |f| File.basename(f) }.sort
    files2 = Dir.glob("#{dir2}/*.yaml").map { |f| File.basename(f) }.sort

    return false unless files1 == files2

    files1.all? do |filename|
      content1 = File.read("#{dir1}/#{filename}")
      content2 = File.read("#{dir2}/#{filename}")
      content1 == content2
    end
  end

  def get_workload_info(pod, namespace)
    owner_refs = pod.dig('metadata', 'ownerReferences') || []
    workload_info = {
      deployment: nil,
      statefulset: nil,
      daemonset: nil,
      replicaset: nil
    }

    return workload_info if owner_refs.empty?

    owner = owner_refs.first
    owner_kind = owner['kind']
    owner_name = owner['name']

    case owner_kind
    when 'ReplicaSet'
      workload_info[:replicaset] = owner_name
      # Try to find parent Deployment
      begin
        replicaset = kubernetes_request("/apis/apps/v1/namespaces/#{namespace}/replicasets/#{owner_name}")
        rs_owner_refs = replicaset.dig('metadata', 'ownerReferences') || []

        if rs_owner_refs.length > 0 && rs_owner_refs.first['kind'] == 'Deployment'
          workload_info[:deployment] = rs_owner_refs.first['name']
        end
      rescue => e
        puts "Kubernetes discovery: Failed to get ReplicaSet info for #{owner_name}: #{e.message}"
      end
    when 'Deployment'
      workload_info[:deployment] = owner_name
    when 'StatefulSet'
      workload_info[:statefulset] = owner_name
    when 'DaemonSet'
      workload_info[:daemonset] = owner_name
    end

    workload_info
  end
end