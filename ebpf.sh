#!/bin/bash

# eBPF Compatibility Check Script for Better Stack Collector
# This script checks if your system supports eBPF features required by Beyla
# Specifically: BTF + CO-RE support and eBPF ring buffer (BPF_MAP_TYPE_RINGBUF)

set -e

# Check for JSON output flag
JSON_OUTPUT=false
if [ "$1" == "--json" ]; then
    JSON_OUTPUT=true
fi

# Color codes for output (only used for non-JSON output)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Get kernel version
KERNEL_VERSION=$(uname -r)
KERNEL_MAJOR=$(echo "$KERNEL_VERSION" | cut -d. -f1)
KERNEL_MINOR=$(echo "$KERNEL_VERSION" | cut -d. -f2)

# Get system information
ARCHITECTURE=$(uname -m)
DISTRIBUTION="Unknown"
if [ -f /etc/os-release ]; then
    DISTRIBUTION=$(grep "^PRETTY_NAME" /etc/os-release | cut -d= -f2 | tr -d '"')
elif [[ "$OSTYPE" == "darwin"* ]]; then
    DISTRIBUTION="macOS $(sw_vers -productVersion 2>/dev/null || echo "")"
fi

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
DETAILS=""

# JSON result variables
RING_BUFFER_SUPPORTED=false
BPF_FILESYSTEM_MOUNTED=false
BTF_SUPPORT_AVAILABLE=false
BPF_SYSCALL_ENABLED=null
BPF_JIT_ENABLED=null

# Check kernel version
if ! check_kernel_version 5 14; then
    DETAILS="${DETAILS}  ${YELLOW}⚠${NC} Kernel version: $KERNEL_VERSION (5.14+ required, older may work with backports)\n"
else
    DETAILS="${DETAILS}  ${GREEN}✓${NC} Kernel version: $KERNEL_VERSION\n"
fi

# Check for ring buffer support (5.8+ minimum)
if check_kernel_version 5 8; then
    RING_BUFFER_SUPPORTED=true
    DETAILS="${DETAILS}  ${GREEN}✓${NC} eBPF ring buffer: supported\n"
else
    HAS_EBPF=false
    DETAILS="${DETAILS}  ${RED}✗${NC} eBPF ring buffer: not supported (requires kernel 5.8+)\n"
fi

# Check for BPF filesystem
if [ -d "/sys/fs/bpf" ]; then
    BPF_FILESYSTEM_MOUNTED=true
    DETAILS="${DETAILS}  ${GREEN}✓${NC} BPF filesystem: mounted\n"
else
    HAS_EBPF=false
    DETAILS="${DETAILS}  ${RED}✗${NC} BPF filesystem: not available\n"
fi

# Check for BTF support
if [ -f "/sys/kernel/btf/vmlinux" ] || [ -f "/boot/vmlinux-$KERNEL_VERSION" ]; then
    BTF_SUPPORT_AVAILABLE=true
    DETAILS="${DETAILS}  ${GREEN}✓${NC} BTF + CO-RE support: available\n"
else
    HAS_EBPF=false
    DETAILS="${DETAILS}  ${RED}✗${NC} BTF + CO-RE support: not available\n"
fi

# Check for CONFIG_BPF_SYSCALL
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
    BPF_SYSCALL_ENABLED=true
    DETAILS="${DETAILS}  ${GREEN}✓${NC} BPF syscall: enabled\n"
elif [ -f "/proc/config.gz" ] || [ -f "/boot/config-$KERNEL_VERSION" ]; then
    BPF_SYSCALL_ENABLED=false
    HAS_EBPF=false
    DETAILS="${DETAILS}  ${RED}✗${NC} BPF syscall: not enabled\n"
else
    DETAILS="${DETAILS}  ${YELLOW}⚠${NC} BPF syscall: unable to verify\n"
fi

# Check for BPF JIT compiler (warning only)
if [ -f "/proc/sys/net/core/bpf_jit_enable" ]; then
    JIT_ENABLED=$(cat /proc/sys/net/core/bpf_jit_enable)
    if [ "$JIT_ENABLED" != "0" ]; then
        BPF_JIT_ENABLED=true
        DETAILS="${DETAILS}  ${GREEN}✓${NC} BPF JIT compiler: enabled\n"
    else
        BPF_JIT_ENABLED=false
        DETAILS="${DETAILS}  ${YELLOW}⚠${NC} BPF JIT compiler: disabled (performance impact)\n"
    fi
fi

# Output results
if [ "$JSON_OUTPUT" = true ]; then
    # JSON output
    cat <<EOF
{
  "ebpf_supported": $([[ "$HAS_EBPF" = true ]] && echo "true" || echo "false"),
  "kernel_version": "$KERNEL_VERSION",
  "ring_buffer_supported": $([[ "$RING_BUFFER_SUPPORTED" = true ]] && echo "true" || echo "false"),
  "bpf_filesystem_mounted": $([[ "$BPF_FILESYSTEM_MOUNTED" = true ]] && echo "true" || echo "false"),
  "btf_support_available": $([[ "$BTF_SUPPORT_AVAILABLE" = true ]] && echo "true" || echo "false"),
  "bpf_syscall_enabled": $([[ "$BPF_SYSCALL_ENABLED" = true ]] && echo "true" || ([[ "$BPF_SYSCALL_ENABLED" = false ]] && echo "false" || echo "null")),
  "bpf_jit_enabled": $([[ "$BPF_JIT_ENABLED" = true ]] && echo "true" || ([[ "$BPF_JIT_ENABLED" = false ]] && echo "false" || echo "null")),
  "architecture": "$ARCHITECTURE",
  "distribution": "$DISTRIBUTION"
}
EOF
else
    # Human-readable output
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
        echo -e "$DETAILS"
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
fi

exit 0