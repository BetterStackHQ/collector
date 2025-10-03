#!/bin/bash
# Health check script for Vector
# Returns 0 if healthy, non-zero if unhealthy
# Detects when Vector is running with minimal/console-only configuration

set -euo pipefail

# Check if Vector is healthy (returns JSON: {"ok":true} or {"ok":false})
VECTOR_HEALTH=$(curl -s http://localhost:8686/health 2>/dev/null | jq -r '.ok' 2>/dev/null || echo "error")

if [ "$VECTOR_HEALTH" != "true" ]; then
    echo "Vector health check failed - not responding or unhealthy ($VECTOR_HEALTH)"
    exit 1
fi

# Check what sinks Vector has configured
# If only console sink exists, something is wrong
SINKS=$(curl -s http://localhost:8686/graphql \
    -H "Content-Type: application/json" \
    -d '{"query":"{ sinks { edges { node { componentId componentType } } } }"}' 2>/dev/null | \
    jq -r '.data.sinks.edges[].node.componentId' 2>/dev/null || echo "")

if [ -z "$SINKS" ]; then
    echo "ERROR: Vector has no sinks configured"
    exit 1
fi

# Count how many sinks we have
SINK_COUNT=$(echo "$SINKS" | wc -l)

# Check if only console sink exists (emergency/fallback mode)
if [ "$SINK_COUNT" -eq 1 ] && echo "$SINKS" | grep -q "^console$"; then
    echo "ERROR: Vector running with console-only sink (lost configuration)"
    exit 1
fi

# Check if we're missing expected Better Stack sinks
if ! echo "$SINKS" | grep -q "better_stack_http"; then
    echo "WARNING: Vector missing Better Stack HTTP sinks"
    echo "Current sinks: $(echo $SINKS | tr '\n' ' ')"
    # Don't fail yet - updater might be working on it
fi

echo "Vector health check passed - $SINK_COUNT sinks configured"
exit 0
