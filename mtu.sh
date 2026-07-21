#!/bin/bash

# ====================================================================
#               Network Optimizer - Super Smart Edition
# Author: Gemini
# Version: 2.0
# ====================================================================

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
    echo -e "${BLUE}║ $1${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
}

print_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        print_error "This script requires root privileges to run certain checks. Please run as root or with sudo."
        exit 1
    fi
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        print_error "Command '$1' not found. Please install it (e.g., sudo apt install $2)."
        exit 1
    fi
}

# --- Validation Functions ---
is_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

is_ipv6() {
    # Robust validation using iproute2 which is a dependency anyway
    ip -6 route get "$1" > /dev/null 2>&1
}

# --- Core Functions ---
discover_mtu() {
    local IP="$1"
    local PING_CMD="ping"
    local MIN_MTU=68
    local MAX_MTU=1500

    if is_ipv6 "$IP"; then
        PING_CMD="ping -6"
        MIN_MTU=1280
    elif ! is_ipv4 "$IP"; then
        print_error "Invalid IP address provided: $IP"
        return 1
    fi

    print_header "1. Path MTU Discovery for $IP"
    print_info "Searching for optimal MTU between $MIN_MTU and $MAX_MTU..."

    local low=$MIN_MTU
    local high=$MAX_MTU
    local optimal_mtu=0

    while [ $low -le $high ]; do
        local mid=$(( (low + high) / 2 ))
        local packet_size=$(( mid - 28 )) # 20 bytes IP header + 8 bytes ICMP header
        if is_ipv6 "$IP"; then
            packet_size=$(( mid - 48 )) # 40 bytes IPv6 header + 8 bytes ICMPv6 header
        fi

        if [ $packet_size -le 0 ]; then
            low=$(( mid + 1 ))
            continue
        fi
        
        echo -n "Probing with MTU $mid... "
        if $PING_CMD -c 1 -W 2 -M do -s $packet_size "$IP" &> /dev/null; then
            echo -e "${GREEN}Success${NC}"
            optimal_mtu=$mid
            low=$(( mid + 1 ))
        else
            echo -e "${YELLOW}Fragmentation needed${NC}"
            high=$(( mid - 1 ))
        fi
    done

    if [ $optimal_mtu -gt 0 ]; then
        echo "$optimal_mtu"
        print_success "Optimal Path MTU discovered: $optimal_mtu bytes"
    else
        print_error "Could not determine optimal MTU. Target might be unreachable."
        return 1
    fi
}

analyze_network_performance() {
    local IP="$1"
    local PING_CMD="ping"
    if is_ipv6 "$IP"; then PING_CMD="ping -6"; fi

    print_header "2. Network Performance Analysis"
    print_info "Pinging $IP 10 times..."
    
    local PING_OUTPUT
    PING_OUTPUT=$($PING_CMD -c 10 -i 0.2 "$IP")
    
    if [ $? -ne 0 ]; then
        print_error "Ping failed. Target is unreachable or blocking ICMP."
        return 1
    fi

    local STATS_LINE=$(echo "$PING_OUTPUT" | grep -oP '.*packet loss.*')
    local RTT_LINE=$(echo "$PING_OUTPUT" | grep -oP 'rtt min/avg/max/mdev =.*' | sed 's|rtt min/avg/max/mdev = ||' | sed 's| ms||')

    PACKET_LOSS=$(echo "$STATS_LINE" | grep -oP '\d+(.\d+)?(?=% packet loss)')
    RTT_AVG=$(echo "$RTT_LINE" | cut -d'/' -f2)

    echo -e "  - ${CYAN}Packet Loss:${NC} $PACKET_LOSS%"
    echo -e "  - ${CYAN}Average RTT:${NC} $RTT_AVG ms"
    
    print_info "Running traceroute..."
    local TRACEROUTE_CMD="traceroute"
    if is_ipv6 "$IP"; then TRACEROUTE_CMD="traceroute -6"; fi
    $TRACEROUTE_CMD "$IP"
    return 0
}

analyze_system_config() {
    print_header "3. System Configuration Analysis"
    CONGESTION_CONTROL=$(sysctl -n net.ipv4.tcp_congestion_control)
    DEFAULT_QDISC=$(sysctl -n net.core.default_qdisc)

    echo -e "  - ${CYAN}TCP Congestion Control:${NC} $CONGESTION_CONTROL"
    echo -e "  - ${CYAN}Default Queuing Discipline:${NC} $DEFAULT_QDISC"
}

generate_recommendations() {
    print_header "4. Final Recommendations"

    # MTU Recommendation
    if [ "$OPTIMAL_MTU" -lt 1500 ]; then
        print_success "Set interface MTU to $OPTIMAL_MTU for optimal performance."
        echo "    Command: ip link set dev <YOUR_INTERFACE> mtu $OPTIMAL_MTU"
    else
        print_info "Your current MTU path (1500) seems optimal. No changes needed."
    fi

    # Latency & Packet Loss Recommendations
    if (( $(echo "$PACKET_LOSS > 1" | bc -l) )); then
        print_warning "Packet loss is high (${PACKET_LOSS}%). This severely degrades performance."
        echo "    - Investigate network path using traceroute results above."
        echo "    - Consider changing server or using a route-optimizing VPN."
    fi
    if (( $(echo "$RTT_AVG > 150" | bc -l) )); then
        print_warning "Average latency is high (${RTT_AVG}ms)."
        echo "    - For better interactive performance, choose a geographically closer server."
    fi

    # System Tuning Recommendations
    if [ "$CONGESTION_CONTROL" != "bbr" ]; then
        print_success "Enable TCP BBR for significantly better throughput on lossy/high-latency links."
        echo "    Command: sysctl -w net.core.default_qdisc=fq"
        echo "    Command: sysctl -w net.ipv4.tcp_congestion_control=bbr"
        echo "    To make permanent, add these lines to /etc/sysctl.conf and run 'sysctl -p'"
    else
        print_info "TCP BBR is already enabled. Good!"
    fi
    
    if [ "$DEFAULT_QDISC" != "fq" ] && [ "$CONGESTION_CONTROL" != "bbr" ]; then
        print_warning "Default qdisc is not 'fq'. BBR works best with 'fq' (Fair Queue)."
        echo "    - The BBR recommendation above will set this for you."
    fi
}

# --- Main Script Logic ---
main() {
    check_root
    check_command "ping" "inetutils-ping or iputils-ping"
    check_command "traceroute" "traceroute"
    check_command "ip" "iproute2"
    check_command "bc" "bc"

    read -rp "${YELLOW}Enter target IP address (IPv4 or IPv6): ${NC}" TARGET_IP

    if [ -z "$TARGET_IP" ]; then
        print_error "No target IP provided. Exiting."
        exit 1
    fi

    OPTIMAL_MTU=$(discover_mtu "$TARGET_IP")
    if [ $? -ne 0 ]; then exit 1; fi

    analyze_network_performance "$TARGET_IP"
    if [ $? -ne 0 ]; then exit 1; fi

    analyze_system_config
    
    generate_recommendations
    
    print_header "Script Finished"
}

main "$@"
