#!/bin/bash

# ==================================================================================
#
#   APPLOOS FRP TUNNEL - Full Management Script (v13.0 - Final Menu Logic Fix)
#   Developed By: @AliTabari
#   Purpose: Automate the installation, configuration, and management of FRP.
#
# ==================================================================================

# --- Static Configuration Variables ---
FRP_VERSION="0.59.0"
FRP_INSTALL_DIR="/opt/frp"
SYSTEMD_DIR="/etc/systemd/system"
FRP_TCP_CONTROL_PORT="7000"
FRP_QUIC_CONTROL_PORT="7001"
FRP_DASHBOARD_PORT="7500"
OPTIMIZATIONS_FILE="/etc/sysctl.d/99-network-optimizations.conf"

# --- Color Codes for beautiful output ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- Function to check if run as root ---
check_root() {
    if [[ $EUID -ne 0 ]]; then
       echo -e "${RED}ERROR: This script must be run as root.${NC}" 
       exit 1
    fi
}

# --- Input and Helper Functions (Using 'return 1' on failure instead of 'exit') ---

get_server_ips() {
    echo -e "${CYAN}Please provide the IP addresses for the tunnel setup.${NC}"
    read -p "Enter the Public IP for the IRAN Server (the entry point): " IRAN_SERVER_IP
    if [[ -z "$IRAN_SERVER_IP" ]]; then echo -e "${RED}IP cannot be empty.${NC}"; return 1; fi

    read -p "Enter the Public IP for the FOREIGN Server (where services are): " FOREIGN_SERVER_IP
    if [[ -z "$FOREIGN_SERVER_IP" ]]; then echo -e "${RED}IP cannot be empty.${NC}"; return 1; fi
    return 0
}

get_port_input() {
    echo -e "\n${CYAN}Please enter the port(s) you want to tunnel.${NC}"
    read -p "Examples: 8080, 20000-30000. Enter ports: " user_ports
    if [[ -z "$user_ports" ]]; then echo -e "${RED}No ports entered.${NC}"; return 1; fi
    if ! [[ "$user_ports" =~ ^[0-9,-]+$ ]]; then echo -e "${RED}Invalid format.${NC}"; return 1; fi
    FRP_TUNNEL_PORTS_FRP=$user_ports
    FRP_TUNNEL_PORTS_UFW=${user_ports//-/:}
    return 0
}

get_protocol_choice() {
    echo -e "\n${CYAN}Select the transport protocol for the tunnel:${NC}"
    echo "  1. TCP (Standard, reliable)"
    echo "  2. QUIC (Recommended for reducing latency)"
    read -p "Enter your choice [1-2] (Default is 1): " proto_choice
    case $proto_choice in
        2) FRP_PROTOCOL="quic" ;;
        *) FRP_PROTOCOL="tcp" ;;
    esac
    echo -e "${GREEN}Protocol set to: ${FRP_PROTOCOL}${NC}"
}

# --- Core Logic Functions ---

stop_frp_processes() {
    systemctl stop frps.service > /dev/null 2>&1; systemctl stop frpc.service > /dev/null 2>&1
    killall frps > /dev/null 2>&1 || true; killall frpc > /dev/null 2>&1 || true
}

download_and_extract() {
    rm -rf ${FRP_INSTALL_DIR}; mkdir -p ${FRP_INSTALL_DIR}
    FRP_TAR_FILE="frp_${FRP_VERSION}_linux_amd64.tar.gz"
    wget -q "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FRP_TAR_FILE}" -O "${FRP_TAR_FILE}"
    tar -zxvf "${FRP_TAR_FILE}" -C "${FRP_INSTALL_DIR}" --strip-components=1
    rm "${FRP_TAR_FILE}"
}

setup_iran_server() {
    # Chaining input functions. If any fails, the function returns.
    get_server_ips && get_port_input && get_protocol_choice || return 1

    echo -e "\n${YELLOW}--- Starting Full Setup for Iran Server (frps) ---${NC}"
    stop_frp_processes; download_and_extract
    
    echo -e "${YELLOW}--> Creating frps.ini...${NC}"
    if [ "$FRP_PROTOCOL" == "quic" ]; then
        cat > ${FRP_INSTALL_DIR}/frps.ini << EOF
[common]
quic_bind_port = ${FRP_QUIC_CONTROL_PORT}
dashboard_addr = 0.0.0.0
dashboard_port = ${FRP_DASHBOARD_PORT}
dashboard_user = admin
dashboard_pwd = FRP_PASSWORD_123
EOF
    else
        cat > ${FRP_INSTALL_DIR}/frps.ini << EOF
[common]
bind_port = ${FRP_TCP_CONTROL_PORT}
dashboard_addr = 0.0.0.0
dashboard_port = ${FRP_DASHBOARD_PORT}
dashboard_user = admin
dashboard_pwd = FRP_PASSWORD_123
EOF
    fi

    echo -e "${YELLOW}--> Setting up firewall...${NC}"
    if [ "$FRP_PROTOCOL" == "quic" ]; then ufw allow ${FRP_QUIC_CONTROL_PORT}/udp > /dev/null; else ufw allow ${FRP_TCP_CONTROL_PORT}/tcp > /dev/null; fi
    ufw allow ${FRP_DASHBOARD_PORT}/tcp > /dev/null
    OLD_IFS=$IFS; IFS=','; read -ra PORTS_ARRAY <<< "$FRP_TUNNEL_PORTS_UFW"; IFS=$OLD_IFS
    for port in "${PORTS_ARRAY[@]}"; do ufw allow "$port"/tcp > /dev/null; done
    ufw reload > /dev/null

    echo -e "${YELLOW}--> Creating systemd service...${NC}"
    cat > ${SYSTEMD_DIR}/frps.service << EOF
[Unit]
Description=FRP Server (frps)
After=network.target
[Service]
Type=simple; User=root; Restart=on-failure; RestartSec=5s
ExecStart=${FRP_INSTALL_DIR}/frps -c ${FRP_INSTALL_DIR}/frps.ini
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable frps.service > /dev/null; systemctl restart frps.service
    echo -e "\n${GREEN}SUCCESS! Iran Server setup is complete.${NC}"
}

setup_foreign_server() {
    get_server_ips && get_port_input && get_protocol_choice || return 1

    echo -e "\n${YELLOW}--- Starting Full Setup for Foreign Server (frpc) ---${NC}"
    stop_frp_processes; download_and_extract
    
    echo -e "${YELLOW}--> Creating frpc.ini...${NC}"
    if [ "$FRP_PROTOCOL" == "quic" ]; then
        cat > ${FRP_INSTALL_DIR}/frpc.ini << EOF
[common]
server_addr = ${IRAN_SERVER_IP}
server_port = ${FRP_QUIC_CONTROL_PORT}
protocol = quic
[range:vless-tcp]
type = tcp; local_ip = 127.0.0.1; local_port = ${FRP_TUNNEL_PORTS_FRP}; remote_port = ${FRP_TUNNEL_PORTS_FRP}
EOF
    else
        cat > ${FRP_INSTALL_DIR}/frpc.ini << EOF
[common]
server_addr = ${IRAN_SERVER_IP}
server_port = ${FRP_TCP_CONTROL_PORT}
[range:vless-tcp]
type = tcp; local_ip = 127.0.0.1; local_port = ${FRP_TUNNEL_PORTS_FRP}; remote_port = ${FRP_TUNNEL_PORTS_FRP}
EOF
    fi

    echo -e "${YELLOW}--> Creating systemd service...${NC}"
    cat > ${SYSTEMD_DIR}/frpc.service << EOF
[Unit]
Description=FRP Client (frpc)
After=network.target
[Service]
Type=simple; User=root; Restart=on-failure; RestartSec=5s
ExecStart=${FRP_INSTALL_DIR}/frpc -c ${FRP_INSTALL_DIR}/frpc.ini
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable frpc.service > /dev/null; systemctl restart frpc.service
    echo -e "\n${GREEN}SUCCESS! Foreign Server setup is complete.${NC}"
}

uninstall_frp() {
    echo -e "\n${YELLOW}Uninstalling FRP...${NC}"; stop_frp_processes
    rm -f ${SYSTEMD_DIR}/frps.service; rm -f ${SYSTEMD_DIR}/frpc.service
    systemctl daemon-reload; rm -rf ${FRP_INSTALL_DIR}
    echo -e "${YELLOW}Note: Firewall rules must be removed manually.${NC}"
    echo -e "\n${GREEN}SUCCESS! FRP has been uninstalled.${NC}"
}

# --- Optimization Menu and Functions ---
install_bbr() { sed -i '/net.ipv4.tcp_congestion_control\|net.core.default_qdisc/d' /etc/sysctl.conf; echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf; echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf; sysctl -p > /dev/null 2>&1; echo -e "${GREEN}--> BBR enabled.${NC}"; }
remove_bbr() { sed -i '/net.ipv4.tcp_congestion_control=bbr\|net.core.default_qdisc=fq/d' /etc/sysctl.conf; sysctl -p > /dev/null 2>&1; echo -e "${GREEN}--> BBR removed.${NC}"; }
install_cubic() { sed -i '/net.ipv4.tcp_congestion_control\|net.core.default_qdisc/d' /etc/sysctl.conf; echo "net.ipv4.tcp_congestion_control=cubic" >> /etc/sysctl.conf; sysctl -p > /dev/null 2>&1; echo -e "${GREEN}--> Cubic enabled.${NC}"; }
remove_cubic() { sed -i '/net.ipv4.tcp_congestion_control=cubic/d' /etc/sysctl.conf; sysctl -p > /dev/null 2>&1; echo -e "${GREEN}--> Cubic setting removed.${NC}"; }
show_optimization_menu() {
    while true; do
        clear
        echo "================================================="; echo -e "      ${CYAN}Network Optimizations Menu${NC}"; echo "================================================="
        local current_congestion_control=$(sysctl -n net.ipv4.tcp_congestion_control)
        echo -e "Current Algorithm: ${YELLOW}${current_congestion_control}${NC}"
        echo "-------------------------------------------------"; echo "1. Install BBR"; echo "2. Remove BBR"; echo "---"
        echo "3. Install Cubic (Linux Default)"; echo "4. Remove Cubic"; echo "---"; echo "5. Back to Main Menu"
        echo "-------------------------------------------------"; read -p "Enter your choice [1-5]: " opt_choice
        case $opt_choice in
            1) install_bbr; ;; 2) remove_bbr; ;; 3) install_cubic; ;;
            4) remove_cubic; ;; 5) break ;; *) echo -e "${RED}Invalid choice.${NC}";;
        esac; echo -e "${CYAN}Operation complete. Press [Enter]...${NC}"; read -n 1;
    done
}

# --- Main Menu Display and Logic ---
check_root

while true; do
    clear
    CURRENT_SERVER_IP=$(wget -qO- 'https://api.ipify.org' || echo "N/A")
    echo "================================================="
    echo -e "      ${CYAN}APPLOOS FRP TUNNEL${NC} - v13.0"
    echo "================================================="
    echo -e "  Developed By ${YELLOW}@AliTabari${NC}"
    echo -e "  This Server's Public IP: ${GREEN}${CURRENT_SERVER_IP}${NC}"
    echo "-------------------------------------------------"
    echo "  1. Setup this machine as IRAN Server (frps)"
    echo "  2. Setup this machine as FOREIGN Server (frpc)"
    echo "  3. UNINSTALL FRP from this machine"
    echo "  4. Network Optimizations Menu"
    echo "  5. Exit"
    echo "-------------------------------------------------"

    read -p "Enter your choice [1-5]: " choice

    # Perform the action based on the choice
    case $choice in
        1)
            setup_iran_server
            ;;
        2)
            setup_foreign_server
            ;;
        3)
            uninstall_frp
            ;;
        4)
            show_optimization_menu
            continue # Skip the pause below, as the submenu handles its own loop
            ;;
        5)
            echo -e "${YELLOW}Exiting.${NC}";
            break # Exit the while loop
            ;;
        *)
            echo -e "${RED}Invalid choice. Please try again.${NC}";
            sleep 2
            continue # Skip the pause and redisplay menu
            ;;
    esac

    # Pause at the end of the loop for main actions (1, 2, 3)
    echo -e "\n${CYAN}--- Press [Enter] to return to the main menu. ---${NC}"
    read
done
