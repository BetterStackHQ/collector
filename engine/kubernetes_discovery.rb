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

  def should_discover?
    latest_vector_yaml = File.join(@working_dir, "latest-valid-vector.yaml")
    return false unless File.exist?(latest_vector_yaml)

    config_content = File.read(latest_vector_yaml)
    config_content.include?('kubernetes_discovery_')
  end

  def run
    unless should_discover?
      puts "Skipping kubernetes discovery - not used in vector config"
      return false
    end

    # Rate limit check
    current_time = Time.now
    if @last_run_time && (current_time - @last_run_time) < 30
      puts "Skipping kubernetes discovery - last run #{(current_time - @last_run_time).to_i}s ago"
      return false
    end
    @last_run_time = current_time

    # Initialize kubernetes connection
    unless in_kubernetes?
      puts "Not running in Kubernetes environment"
      return false
    end

    puts "Running kubernetes discovery"

    @base_url = "https://#{ENV['KUBERNETES_SERVICE_HOST']}:#{ENV['KUBERNETES_SERVICE_PORT']}"
    @token = read_service_account_token
    @namespace = read_namespace
    @ca_cert = read_ca_cert

    begin
      discover_and_update
    rescue => e
      puts "Error during kubernetes discovery: #{e.class.name}: #{e.message}"
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
        puts "Cleaning up old kubernetes-discovery version: #{File.basename(dir)}"
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
    puts "Starting Prometheus endpoint discovery"
    puts "Filtering for node: #{@node_name}" if @node_name

    latest_dir = latest_kubernetes_discovery

    # Create new version directory
    timestamp = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S')
    new_dir = File.join(@base_dir, timestamp)
    FileUtils.mkdir_p(new_dir)

    # Get all namespaces we have access to
    namespaces = get_namespaces
    puts "Checking #{namespaces.length} namespaces"

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

    if configs_generated == 0
      puts "No sources discovered, removing directory"
      FileUtils.rm_rf(new_dir)
      return false
    end

    puts "Generated #{configs_generated} configs for kubernetes discovery"

    # Validate the generated configs
    unless validate_configs(new_dir)
      puts "Error: Kubernetes discovery validation failed, removing invalid configs"
      FileUtils.rm_rf(new_dir)
      return false
    end

    puts "Kubernetes discovery validation passed"

    # Check if configs changed from latest version
    if latest_dir && configs_identical?(latest_dir, new_dir)
      puts "Kubernetes discovery unchanged from previous version"
      FileUtils.rm_rf(new_dir)
      return false
    end

    # Clean up old versions
    cleanup_old_versions

    true
  end

  def get_namespaces
    begin
      result = kubernetes_request('/api/v1/namespaces')
      result['items'].map { |ns| ns['metadata']['name'] }
    rescue => e
      puts "Warning: Failed to list namespaces (#{e.message}), using current namespace"
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

      # Only select pods on the current node
      annotations['prometheus.io/scrape'] == 'true' &&
        pod['status']['phase'] == 'Running' &&
        !pod['metadata']['ownerReferences'] && # Skip pods that belong to services
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
        workload = nil
        if @node_name && pod_name
          begin
            pod = kubernetes_request("/api/v1/namespaces/#{namespace}/pods/#{pod_name}")
            node_name = pod.dig('spec', 'nodeName')
            next unless node_name == @node_name
            
            # Extract workload information from ownerReferences
            workload = get_workload_from_pod(pod, namespace)
            if workload
              puts "Found workload for #{pod_name}: #{workload}"
            end
          rescue => e
            puts "Warning: Failed to get pod info for #{pod_name}: #{e.message}"
            next
          end
        end

        results << {
          name: "#{namespace}_#{pod_name || service_name}",
          endpoint: "http://#{address['ip']}:#{port}#{path}",
          namespace: namespace,
          pod: pod_name,
          service: service_name,
          pod_ip: address['ip'],
          workload: workload
        }
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
    workload = get_workload_from_pod(pod, namespace)

    {
      name: "#{namespace}_#{pod_name}",
      endpoint: "http://#{pod_ip}:#{port}#{path}",
      namespace: namespace,
      pod: pod_name,
      service: nil,
      pod_ip: pod_ip,
      workload: workload
    }
  end

  def generate_config(endpoint_info)
    return nil unless endpoint_info

    source_name = "kubernetes_discovery_#{endpoint_info[:name]}"

    config = {
      'sources' => {
        source_name => {
          'type' => 'prometheus_scrape',
          'endpoints' => [endpoint_info[:endpoint]],
          'scrape_interval_secs' => 30,
          'labels' => {
            'namespace' => endpoint_info[:namespace],
            'pod' => endpoint_info[:pod],
            'pod_ip' => endpoint_info[:pod_ip],
          }
        }
      }
    }

    config_md5 = Digest::MD5.hexdigest(config.to_yaml)
    filename = "#{endpoint_info[:name]}-#{config_md5}.yaml"

    # Add service label if this endpoint belongs to a service
    if endpoint_info[:service]
      config['sources'][source_name]['labels']['service'] = endpoint_info[:service]
    end
    
    # Add workload label if available
    if endpoint_info[:workload]
      config['sources'][source_name]['labels']['workload'] = endpoint_info[:workload]
    end

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

  def get_workload_from_pod(pod, namespace)
    owner_refs = pod.dig('metadata', 'ownerReferences') || []
    return nil if owner_refs.empty?

    owner = owner_refs.first
    owner_kind = owner['kind']
    owner_name = owner['name']

    # For ReplicaSets, try to find the parent Deployment
    if owner_kind == 'ReplicaSet'
      begin
        replicaset = kubernetes_request("/apis/apps/v1/namespaces/#{namespace}/replicasets/#{owner_name}")
        rs_owner_refs = replicaset.dig('metadata', 'ownerReferences') || []
        
        if rs_owner_refs.length > 0 && rs_owner_refs.first['kind'] == 'Deployment'
          return "deployment/#{rs_owner_refs.first['name']}"
        end
      rescue => e
        puts "Warning: Failed to get ReplicaSet info for #{owner_name}: #{e.message}"
      end
    end

    # Return the direct owner for other types (DaemonSet, StatefulSet, Job, etc.)
    "#{owner_kind.downcase}/#{owner_name}"
  end
end