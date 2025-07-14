#!/bin/bash
#
# Cluster Agent Manager
#
# This script manages the cluster-agent by:
# 1. Checking if the cluster collector should run via /should_run_cluster_collector.rb
# 2. Starting the agent only if the check passes
# 3. Monitoring every 60 seconds and stopping the agent if the check fails
# 4. Restarting the cycle to allow the agent to start again when conditions change

# Trap SIGTERM for clean shutdown
trap 'kill $AGENT_PID 2>/dev/null; exit' SIGTERM

while true; do
  if ruby /should_run_cluster_collector.rb; then
    /usr/local/bin/cluster-agent \
      --coroot-url http://localhost:33000 \
      --metrics-scrape-interval=15s \
      --config-update-interval=15s &
    AGENT_PID=$!
    while sleep 60; do
      if ! ruby /should_run_cluster_collector.rb; then
        kill $AGENT_PID
        wait $AGENT_PID
        break
      fi
    done
  fi
  sleep 60
done
