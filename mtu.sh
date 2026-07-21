#!/bin/bash

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- Helper Functions ---
print_header() {
    echo -e "\n${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║ ${1} ${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
}

print_info() {
    echo -e "${CYAN}[INFO]${NC} ${1}"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} ${1}"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} ${1}"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} ${1}"
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        print_error "Command '$1' not found. Please install it (e.g., sudo apt install $1)."
        exit 1
    fi
}

is_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

is_ipv6() {
    # Attempt to add and then delete the IP to a dummy interface (lo)
    # This is a robust way to validate an IPv6 address format
    ip -6 addr add "$1"/64 dev lo 2>/dev/null && \
    ip -6 addr del "$1"/64 dev lo 2>/dev/null
}

# --- MTU Discovery Function ---
discover_mtu() {
    local IP="$1"
    local PROTOCOL_FLAG=""
    local PING_CMD="ping"
    local MIN_MTU=68 # Minimum for IPv4, 1280 for IPv6
    local MAX_MTU=1500 # Common default
    local current_mtu=$MAX_MTU
    local optimal_mtu=0

    if is_ipv6 "$IP"; then
        PROTOCOL_FLAG="-6"
        PING_CMD="ping6"
        MIN_MTU=1280
        MAX_MTU=1500 # Even for IPv6, path MTU can be less than 1500
    elif ! is_ipv4 "$IP"; then
        print_error "Invalid IP address: $IP"
        return 1
    fi

    print_header "Path MTU Discovery for $IP"
    print_info "Starting MTU discovery between $MIN_MTU and $MAX_MTU..."

    # Binary search for MTU
    local low=$MIN_MTU
    local high=$MAX_MTU

    while [ $low -le $high ]; do
        current_mtu=$(( (low + high) / 2 ))
        if [ $current_mtu -lt $MIN_MTU ]; then
            current_mtu=$MIN_MTU
        fi
        
        local packet_size=$(( current_mtu - 28 )) # 20 bytes IP header, 8 bytes ICMP header
        if is_ipv6 "$IP"; then
            packet_size=$(( current_mtu - 48 )) # 40 bytes IPv6 header, 8 bytes ICMPv6 header
        fi

        if [ $packet_size -le 0 ]; then
            print_warning "Packet size is too small for MTU $current_mtu. Adjusting."
            low=$(( current_mtu + 1 ))
            continue
        fi

        print_info "Probing with MTU: $current_mtu (Packet size: $packet_size bytes)"
        
        # Use -D for IPv4 to set DF bit, -M do for IPv6 to disallow fragmentation
        # Use -c 1 for count, -W 1 for timeout
        local PING_OPTIONS="-c 1 -W 1"
        if is_ipv4 "$IP"; then
            PING_OPTIONS+=" -D -s $packet_size"
        else
            # For ping6, -M do handles DF bit equivalent and -s sets payload size
            PING_OPTIONS+=" -M do -s $packet_size"
        fi

        # Redirect stderr to /dev/null to suppress 'Frag needed and DF set' messages
        if $PING_CMD $PROTOCOL_FLAG $PING_OPTIONS "$IP" &> /dev/null; then
            print_success "Ping successful with MTU $current_mtu"
            optimal_mtu=$current_mtu
            low=$(( current_mtu + 1 )) # Try a larger MTU
        else
            print_warning "Ping failed with MTU $current_mtu (Fragmentation needed)"
            high=$(( current_mtu - 1 )) # Try a smaller MTU
        fi
    done

    if [ $optimal_mtu -gt 0 ]; then
        print_success "Optimal Path MTU discovered: ${optimal_mtu} bytes"
        echo "${optimal_mtu}"
    else
        print_error "Could not discover optimal MTU. Suggesting default $MAX_MTU or $MIN_MTU for IPv6."
        if is_ipv6 "$IP"; then echo "$MIN_MTU"; else echo "$MAX_MTU"; fi
    fi
}

# --- Network Performance Analysis ---
analyze_network_performance() {
    local IP="$1"
    local PROTOCOL_FLAG=""
    local PING_CMD="ping"

    if is_ipv6 "$IP"; then
        PROTOCOL_FLAG="-6"
        PING_CMD="ping6"
    elif ! is_ipv4 "$IP"; then
        print_error "Invalid IP address: $IP"
        return 1
    fi

    print_header "Network Performance Analysis for $IP"
    print_info "Pinging $IP 10 times to measure latency and packet loss..."
    
    local PING_RESULT
    PING_RESULT=$($PING_CMD $PROTOCOL_FLAG -c 10 "$IP" | tail -n 2)
    
    local PACKET_LOSS=$(echo "$PING_RESULT" | grep -oP '\d+(?=% packet loss)')
    local RTT_MIN=$(echo "$PING_RESULT" | grep -oP 'min/avg/max/mdev = ([0-9.]+)/([0-9.]+)/([0-9.]+)' | cut -d'=' -f2 | cut -d'/' -f1)
    local RTT_AVG=$(echo "$PING_RESULT" | grep -oP 'min/avg/max/mdev = ([0-9.]+)/([0-9.]+)/([0-9.]+)' | cut -d'=' -f2 | cut -d'/' -f2)
    local RTT_MAX=$(echo "$PING_RESULT" | grep -oP 'min/avg/max/mdev = ([0-9.]+)/([0-9.]+)/([0-9.]+)' | cut -d'=' -f2 | cut -d'/' -f3)

    print_info "Ping Results:"
    echo -e "  ${CYAN}Packet Loss:${NC} ${PACKET_LOSS}%"
    echo -e "  ${CYAN}Min/Avg/Max RTT:${NC} ${RTT_MIN}/${RTT_AVG}/${RTT_MAX} ms"

    print_info "Traceroute to $IP (max 30 hops)..."
    local TRACEROUTE_CMD="traceroute"
    if is_ipv6 "$IP"; then
        TRACEROUTE_CMD="traceroute6"
    fi
    $TRACEROUTE_CMD -m 30 "$IP"

    # Basic recommendations based on ping/traceroute
    print_header "Performance Recommendations"
    if [ "$PACKET_LOSS" -gt 0 ]; then
        print_warning "High packet loss detected (${PACKET_LOSS}%). This severely impacts performance."
        print_info "Recommendation: Investigate network congestion or routing issues. Try another server location or a VPN."
    fi

    if (( $(echo "$RTT_AVG > 150" | bc -l) )); then
        print_warning "High average latency detected (${RTT_AVG}ms)."
        print_info "Recommendation: This might indicate a long network path. Consider a server geographically closer or a route optimization service."
    fi

    print_info "Consider enabling TCP BBR for better throughput on high-latency links."
    print_info "  To enable BBR: sudo sysctl -w net.core.default_qdisc=fq; sudo sysctl -w net.ipv4.tcp_congestion_control=bbr"
    print_info "  To make permanent: Add above lines to /etc/sysctl.conf"
}

# --- Main Script Logic ---
main() {
    check_command "ping"
    check_command "traceroute"
    check_command "sysctl"

    local TARGET_IP=""

    if [ -z "$1" ]; then
        read -rp "${YELLOW}Enter target IP address (IPv4 or IPv6): ${NC}" TARGET_IP
    else
        TARGET_IP="$1"
    fi

    if [ -z "$TARGET_IP" ]; then
        print_error "No target IP provided. Exiting."
        exit 1
    fi

    local OPTIMAL_MTU=$(discover_mtu "$TARGET_IP")
    if [ $? -ne 0 ]; then
        print_error "MTU discovery failed. Cannot proceed with full analysis."
        exit 1
    fi

    print_success "Recommended MTU for ${TARGET_IP}: ${OPTIMAL_MTU}"

    analyze_network_performance "$TARGET_IP"

    print_header "Final Summary"
    print_success "Optimal MTU: ${OPTIMAL_MTU}"
    print_info "Review the 'Performance Recommendations' section above for further tuning."
    print_info "Note: MTU changes usually require setting on the network interface (e.g., ip link set eth0 mtu ${OPTIMAL_MTU})."
}

main "$@"
