#!/bin/bash

# eBPF Compatibility Check Script for Better Stack Collector
# This script checks if your system supports eBPF features required by Beyla

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Get kernel version
KERNEL_VERSION=$(uname -r)
KERNEL_MAJOR=$(echo "$KERNEL_VERSION" | cut -d. -f1)
KERNEL_MINOR=$(echo "$KERNEL_VERSION" | cut -d. -f2)

# Function to check if kernel version meets minimum requirement
check_kernel_version() {
    local min_major=$1
    local min_minor=$2
    
    if [ "$KERNEL_MAJOR" -gt "$min_major" ] || \
       ([ "$KERNEL_MAJOR" -eq "$min_major" ] && [ "$KERNEL_MINOR" -ge "$min_minor" ]); then
        return 0
    else
        return 1
    fi
}

# Initialize check results
HAS_EBPF=true
ISSUES=()

# Check kernel version (5.14+ recommended, 5.8+ minimum)
if ! check_kernel_version 5 8; then
    HAS_EBPF=false
    ISSUES+=("Kernel version must be at least 5.8 for eBPF support")
elif ! check_kernel_version 5 14; then
    ISSUES+=("Kernel version is below recommended 5.14 - some eBPF features may be limited")
fi

# Check for BPF filesystem
if [ ! -d "/sys/fs/bpf" ]; then
    HAS_EBPF=false
    ISSUES+=("BPF filesystem is not available")
fi

# Check for BTF support
if [ ! -f "/sys/kernel/btf/vmlinux" ] && [ ! -f "/boot/vmlinux-$KERNEL_VERSION" ]; then
    HAS_EBPF=false
    ISSUES+=("BTF support is not available")
fi

# Check for CONFIG_BPF_SYSCALL
if [ -f "/proc/config.gz" ]; then
    if ! zcat /proc/config.gz 2>/dev/null | grep -q "CONFIG_BPF_SYSCALL=y"; then
        HAS_EBPF=false
        ISSUES+=("BPF syscall is not enabled in kernel configuration")
    fi
elif [ -f "/boot/config-$KERNEL_VERSION" ]; then
    if ! grep -q "CONFIG_BPF_SYSCALL=y" "/boot/config-$KERNEL_VERSION" 2>/dev/null; then
        HAS_EBPF=false
        ISSUES+=("BPF syscall is not enabled in kernel configuration")
    fi
fi

# Check for BPF JIT compiler (warning only)
if [ -f "/proc/sys/net/core/bpf_jit_enable" ]; then
    JIT_ENABLED=$(cat /proc/sys/net/core/bpf_jit_enable)
    if [ "$JIT_ENABLED" = "0" ]; then
        ISSUES+=("BPF JIT compiler is disabled")
    fi
fi

# Display results
if [ "$HAS_EBPF" = true ]; then
    echo -e "${GREEN}✅ Your system supports eBPF!${NC}"
else
    echo -e "${RED}❌ Collector will be able to collect logs, but not eBPF traces.${NC}"
    echo
    echo "Please upgrade your kernel to 5.14 or integrate directly into your app"
    echo "with OpenTelemetry SDK: https://opentelemetry.io/docs/languages/"
    echo "We're here to help at hello@betterstack.com."
fi

# Display issues if any
if [ ${#ISSUES[@]} -gt 0 ] && [ "$HAS_EBPF" = false ]; then
    echo
    echo -e "${BOLD}Issues found:${NC}"
    for issue in "${ISSUES[@]}"; do
        echo "  • $issue"
    done
fi

# Display system information only on failure
if [ "$HAS_EBPF" = false ]; then
    echo
    echo -e "${BOLD}System Information:${NC}"
    echo "  Kernel version: $KERNEL_VERSION"
    echo "  Architecture: $(uname -m)"
    if [ -f /etc/os-release ]; then
        echo "  Distribution: $(grep "^PRETTY_NAME" /etc/os-release | cut -d= -f2 | tr -d '"')"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        echo "  Distribution: macOS $(sw_vers -productVersion 2>/dev/null || echo "")"
    else
        echo "  Distribution: Unknown"
    fi
fi

exit 0