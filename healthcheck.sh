#!/bin/bash
# Health check script for Vector
# Detects when Vector is running with minimal/console-only configuration

set -euo pipefail

CHECK_INTERVAL=60  # seconds between checks

echo "$(date): Starting Vector health check monitor (interval: ${CHECK_INTERVAL}s)"

while true; do
    # Give Vector some time to start up on first run
    if [ ! -f "/tmp/healthcheck-started" ]; then
        echo "$(date): Initial startup delay..."
        touch /tmp/healthcheck-started
        sleep 30
    fi

    # Check if Vector is healthy
    VECTOR_HEALTH=$(curl -s http://localhost:8686/health 2>/dev/null || echo "FAILED")

    if [ "$VECTOR_HEALTH" != "ok" ]; then
        echo "$(date): Vector health check failed - not responding or unhealthy"
    else
        # Check what sinks Vector has configured
        # If only console sink exists, something is wrong
        SINKS=$(curl -s http://localhost:8686/graphql \
            -H "Content-Type: application/json" \
            -d '{"query":"{ sinks { edges { node { componentId componentType } } } }"}' 2>/dev/null | \
            jq -r '.data.sinks.edges[].node.componentId' 2>/dev/null || echo "")

        if [ -z "$SINKS" ]; then
            echo "$(date): ERROR: Vector has no sinks configured"
            echo "$(date): Force restarting Vector..."
            supervisorctl restart vector
        else
            # Count how many sinks we have
            SINK_COUNT=$(echo "$SINKS" | wc -l)

            # Check if only console sink exists (emergency/fallback mode)
            if [ "$SINK_COUNT" -eq 1 ] && echo "$SINKS" | grep -q "^console$"; then
                echo "$(date): ERROR: Vector running with console-only sink (lost configuration)"
                echo "$(date): Force restarting Vector..."
                supervisorctl restart vector
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