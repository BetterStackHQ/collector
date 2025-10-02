#!/bin/bash
# Health check script for Vector
# Detects when Vector is running with minimal/console-only configuration

set -euo pipefail

CHECK_INTERVAL=60  # seconds between checks

echo "$(date): Starting Vector health check monitor (interval: ${CHECK_INTERVAL}s)"

# Function to safely restart Vector
safe_restart_vector() {
    local reason="$1"

    # Check Vector's current state before restarting
    local VECTOR_STATE=$(supervisorctl status vector | awk '{print $2}')
    echo "$(date): Vector current state: $VECTOR_STATE (reason: $reason)"

    if [ "$VECTOR_STATE" = "RUNNING" ]; then
        echo "$(date): Force restarting Vector..."
        supervisorctl restart vector
    elif [ "$VECTOR_STATE" = "STARTING" ]; then
        echo "$(date): Vector is already starting, waiting for it to stabilize..."
    else
        echo "$(date): Vector is in state $VECTOR_STATE, supervisor will handle it"
    fi
}

while true; do
    # Give Vector some time to start up on first run
    if [ ! -f "/tmp/healthcheck-started" ]; then
        echo "$(date): Initial startup delay..."
        touch /tmp/healthcheck-started
        sleep 30
    fi

    # Check if Vector is healthy (returns JSON: {"ok":true} or {"ok":false})
    VECTOR_HEALTH=$(curl -s http://localhost:8686/health 2>/dev/null | jq -r '.ok' 2>/dev/null || echo "error")

    if [ "$VECTOR_HEALTH" != "true" ]; then
        echo "$(date): Vector health check failed - not responding or unhealthy ($VECTOR_HEALTH)"
    else
        # Check what sinks Vector has configured
        # If only console sink exists, something is wrong
        SINKS=$(curl -s http://localhost:8686/graphql \
            -H "Content-Type: application/json" \
            -d '{"query":"{ sinks { edges { node { componentId componentType } } } }"}' 2>/dev/null | \
            jq -r '.data.sinks.edges[].node.componentId' 2>/dev/null || echo "")

        if [ -z "$SINKS" ]; then
            echo "$(date): ERROR: Vector has no sinks configured"
            safe_restart_vector "no sinks configured"
        else
            # Count how many sinks we have
            SINK_COUNT=$(echo "$SINKS" | wc -l)

            # Check if only console sink exists (emergency/fallback mode)
            if [ "$SINK_COUNT" -eq 1 ] && echo "$SINKS" | grep -q "^console$"; then
                echo "$(date): ERROR: Vector running with console-only sink (lost configuration)"
                safe_restart_vector "console-only sink (lost configuration)"
            elif ! echo "$SINKS" | grep -q "better_stack_http"; then
                # Check if we're missing expected Better Stack sinks
                echo "$(date): WARNING: Vector missing Better Stack HTTP sinks"
                echo "$(date): Current sinks: $(echo $SINKS | tr '\n' ' ')"
                # Don't restart yet - updater might be working on it
            else
                echo "$(date): Vector health check passed - $SINK_COUNT sinks configured"
            fi
        fi
    fi

    sleep $CHECK_INTERVAL
done