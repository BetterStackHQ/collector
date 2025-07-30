#!/bin/bash

# eBPF Compatibility Check Script for Better Stack Collector
# This script checks if your system supports eBPF features required by Beyla
# Specifically: BTF + CO-RE support and eBPF ring buffer (BPF_MAP_TYPE_RINGBUF)

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

# Check kernel version (5.14+ required for reliable operation)
if ! check_kernel_version 5 14; then
    # Older kernels may work if distro has backported features, so don't set HAS_EBPF=false yet
    ISSUES+=("Kernel version is below 5.14 - eBPF features may not work reliably without backports")
fi

# Check for ring buffer support (5.8+ minimum)
if ! check_kernel_version 5 8; then
    HAS_EBPF=false
    ISSUES+=("Kernel version must be at least 5.8 for eBPF ring buffer support")
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
if [ "$HAS_EBPF" = false ]; then
    echo
    echo -e "${BOLD}Details:${NC}"
    
    # Kernel version
    if ! check_kernel_version 5 14; then
        echo -e "  ${YELLOW}⚠${NC} Kernel version: $KERNEL_VERSION (5.14+ required, may work with backports)"
    else
        echo -e "  ${GREEN}✓${NC} Kernel version: $KERNEL_VERSION"
    fi
    
    # Ring buffer support (5.8+ has BPF_MAP_TYPE_RINGBUF)
    if check_kernel_version 5 8; then
        echo -e "  ${GREEN}✓${NC} eBPF ring buffer: supported"
    else
        echo -e "  ${RED}✗${NC} eBPF ring buffer: not supported (requires 5.8+)"
    fi
    
    # BPF filesystem
    if [ -d "/sys/fs/bpf" ]; then
        echo -e "  ${GREEN}✓${NC} BPF filesystem: mounted"
    else
        echo -e "  ${RED}✗${NC} BPF filesystem: not available"
    fi
    
    # BTF support
    if [ -f "/sys/kernel/btf/vmlinux" ] || [ -f "/boot/vmlinux-$KERNEL_VERSION" ]; then
        echo -e "  ${GREEN}✓${NC} BTF + CO-RE support: available"
    else
        echo -e "  ${RED}✗${NC} BTF + CO-RE support: not available"
    fi
    
    # BPF syscall
    BPF_SYSCALL_FOUND=false
    if [ -f "/proc/config.gz" ]; then
        if zcat /proc/config.gz 2>/dev/null | grep -q "CONFIG_BPF_SYSCALL=y"; then
            BPF_SYSCALL_FOUND=true
        fi
    elif [ -f "/boot/config-$KERNEL_VERSION" ]; then
        if grep -q "CONFIG_BPF_SYSCALL=y" "/boot/config-$KERNEL_VERSION" 2>/dev/null; then
            BPF_SYSCALL_FOUND=true
        fi
    fi
    
    if [ "$BPF_SYSCALL_FOUND" = true ]; then
        echo -e "  ${GREEN}✓${NC} BPF syscall: enabled"
    else
        if [ -f "/proc/config.gz" ] || [ -f "/boot/config-$KERNEL_VERSION" ]; then
            echo -e "  ${RED}✗${NC} BPF syscall: not enabled"
        else
            echo -e "  ${YELLOW}⚠${NC} BPF syscall: unable to verify"
        fi
    fi
    
    # BPF JIT
    if [ -f "/proc/sys/net/core/bpf_jit_enable" ]; then
        JIT_ENABLED=$(cat /proc/sys/net/core/bpf_jit_enable)
        if [ "$JIT_ENABLED" != "0" ]; then
            echo -e "  ${GREEN}✓${NC} BPF JIT compiler: enabled"
        else
            echo -e "  ${YELLOW}⚠${NC} BPF JIT compiler: disabled (performance impact)"
        fi
    fi
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