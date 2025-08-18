#!/bin/bash
#
# Cluster Agent Manager for Beyla Container
#
# This script manages the cluster-agent by:
# 1. Checking if the cluster collector should run via HTTP endpoint from collector container
# 2. Starting the agent only if the check passes
# 3. Monitoring every 60 seconds and stopping the agent if the check fails
# 4. Restarting the cycle to allow the agent to start again when conditions change
#

ENDPOINT_URL="http://localhost:33000/v1/cluster-agent-enabled"

# Trap SIGTERM for clean shutdown
trap 'kill $AGENT_PID 2>/dev/null; exit' SIGTERM

# Function to check if cluster agent should run
should_run_cluster_agent() {
  # Use curl to check the endpoint, timeout after 5 seconds
  response=$(curl -s --max-time 5 "$ENDPOINT_URL" 2>/dev/null)
  if [ "$response" = "yes" ]; then
    return 0
  fi
  return 1
}

while true; do
  if should_run_cluster_agent; then
    echo "Starting cluster agent (enabled via API endpoint)"
    /usr/local/bin/cluster-agent \
      --coroot-url http://localhost:33000 \
      --metrics-scrape-interval=15s \
      --config-update-interval=15s &
    AGENT_PID=$!
    while sleep 60; do
      if ! should_run_cluster_agent; then
        echo "Stopping cluster agent (disabled via API endpoint)"
        kill $AGENT_PID
        wait $AGENT_PID
        break
      fi
    done
  else
    echo "Cluster agent disabled, checking again in 60 seconds..."
  fi
  sleep 60
done