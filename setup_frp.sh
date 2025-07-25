#!/bin/bash

# ==================================================================================
#
#   APPLOOS FRP TUNNEL - Full Management Script (v17.0 - Full Optimization Removal)
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

# --- Color Codes ---
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

# --- Root Check ---
check_root() { if [[ $EUID -ne 0 ]]; then echo -e "${RED}ERROR: Must be run as root.${NC}"; exit 1; fi; }

# --- Input Functions ---
get_server_ips() {
    read -p "Enter Public IP for IRAN Server (entry point): " IRAN_SERVER_IP
    if [[ -z "$IRAN_SERVER_IP" ]]; then echo -e "${RED}IP cannot be empty.${NC}"; return 1; fi
    read -p "Enter Public IP for FOREIGN Server (service host): " FOREIGN_SERVER_IP
    if [[ -z "$FOREIGN_SERVER_IP" ]]; then echo -e "${RED}IP cannot be empty.${NC}"; return 1; fi
    return 0
}
get_port_input() {
    read -p $'\n'"Enter port(s) to tunnel (e.g., 8080, 20000-30000): " user_ports
    if [[ -z "$user_ports" ]]; then echo -e "${RED}No ports entered.${NC}"; return 1; fi
    if ! [[ "$user_ports" =~ ^[0-9,-]+$ ]]; then echo -e "${RED}Invalid format.${NC}"; return 1; fi
    FRP_TUNNEL_PORTS_FRP=$user_ports; FRP_TUNNEL_PORTS_UFW=${user_ports//-/:}; return 0
}
get_protocol_choice() {
    echo -e "\n${CYAN}Select transport protocol:${NC}\n  1. TCP (Standard)\n  2. QUIC (Recommended for latency)"
    read -p "Enter choice [1-2] (Default: 1): " proto_choice
    [[ "$proto_choice" == "2" ]] && FRP_PROTOCOL="quic" || FRP_PROTOCOL="tcp"
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
    get_server_ips && get_port_input && get_protocol_choice || return 1
    echo -e "\n${YELLOW}--- Setting up Iran Server (frps) ---${NC}"; stop_frp_processes; download_and_extract
    if [ "$FRP_PROTOCOL" == "quic" ]; then
        cat > ${FRP_INSTALL_DIR}/frps.ini << EOF
[common]
quic_bind_port = ${FRP_QUIC_CONTROL_PORT}
dashboard_addr = 0.0.0.0; dashboard_port = ${FRP_DASHBOARD_PORT}
dashboard_user = admin; dashboard_pwd = FRP_PASSWORD_123
EOF
    else
        cat > ${FRP_INSTALL_DIR}/frps.ini << EOF
[common]
bind_port = ${FRP_TCP_CONTROL_PORT}
dashboard_addr = 0.0.0.0; dashboard_port = ${FRP_DASHBOARD_PORT}
dashboard_user = admin; dashboard_pwd = FRP_PASSWORD_123
EOF
    fi
    if [ "$FRP_PROTOCOL" == "quic" ]; then ufw allow ${FRP_QUIC_CONTROL_PORT}/udp > /dev/null; else ufw allow ${FRP_TCP_CONTROL_PORT}/tcp > /dev/null; fi
    ufw allow ${FRP_DASHBOARD_PORT}/tcp > /dev/null
    OLD_IFS=$IFS; IFS=','; read -ra PORTS_ARRAY <<< "$FRP_TUNNEL_PORTS_UFW"; IFS=$OLD_IFS
    for port in "${PORTS_ARRAY[@]}"; do ufw allow "$port"/tcp > /dev/null; done; ufw reload > /dev/null
    cat > ${SYSTEMD_DIR}/frps.service << EOF
[Unit]
Description=FRP Server (frps); After=network.target
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
    echo -e "\n${YELLOW}--- Setting up Foreign Server (frpc) ---${NC}"; stop_frp_processes; download_and_extract
    if [ "$FRP_PROTOCOL" == "quic" ]; then
        cat > ${FRP_INSTALL_DIR}/frpc.ini << EOF
[common]
server_addr = ${IRAN_SERVER_IP}; server_port = ${FRP_QUIC_CONTROL_PORT}; protocol = quic
[range:vless-tcp]
type = tcp; local_ip = 127.0.0.1; local_port = ${FRP_TUNNEL_PORTS_FRP}; remote_port = ${FRP_TUNNEL_PORTS_FRP}
EOF
    else
        cat > ${FRP_INSTALL_DIR}/frpc.ini << EOF
[common]
server_addr = ${IRAN_SERVER_IP}; server_port = ${FRP_TCP_CONTROL_PORT}
[range:vless-tcp]
type = tcp; local_ip = 127.0.0.1; local_port = ${FRP_TUNNEL_PORTS_FRP}; remote_port = ${FRP_TUNNEL_PORTS_FRP}
EOF
    fi
    cat > ${SYSTEMD_DIR}/frpc.service << EOF
[Unit]
Description=FRP Client (frpc); After=network.target
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

# --- Optimization Functions (Updated) ---
install_bbr() { sed -i '/net.ipv4.tcp_congestion_control\|net.core.default_qdisc/d' /etc/sysctl.conf; echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf; echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf; sysctl -p > /dev/null 2>&1; echo -e "${GREEN}--> BBR enabled.${NC}"; }
remove_bbr() { sed -i '/net.ipv4.tcp_congestion_control=bbr\|net.core.default_qdisc=fq/d' /etc/sysctl.conf; sysctl -p > /dev/null 2>&1; echo -e "${GREEN}--> BBR removed.${NC}"; }
install_cubic() { sed -i '/net.ipv4.tcp_congestion_control\|net.core.default_qdisc/d' /etc/sysctl.conf; echo "net.ipv4.tcp_congestion_control=cubic" >> /etc/sysctl.conf; sysctl -p > /dev/null 2>&1; echo -e "${GREEN}--> Cubic enabled.${NC}"; }
remove_cubic() { sed -i '/net.ipv4.tcp_congestion_control=cubic/d' /etc/sysctl.conf; sysctl -p > /dev/null 2>&1; echo -e "${GREEN}--> Cubic setting removed.${NC}"; }
apply_sysctl_optimizations() {
    cat > ${OPTIMIZATIONS_FILE} << EOF
# General Network Tuning by APPLOOS FRP Script
net.core.rmem_max=16777216; net.core.wmem_max=16777216; net.ipv4.tcp_rmem=4096 87380 16777216; net.ipv4.tcp_wmem=4096 65536 16777216; net.core.netdev_max_backlog=30000; net.ipv4.tcp_max_syn_backlog=8192; net.ipv4.tcp_max_tw_buckets=2000000; net.ipv4.tcp_fastopen=3
EOF
    sysctl -p ${OPTIMIZATIONS_FILE} > /dev/null 2>&1; echo -e "${GREEN}--> General optimizations applied.${NC}"
}
remove_sysctl_optimizations() { # NEW FUNCTION
    if [ -f "${OPTIMIZATIONS_FILE}" ]; then
        rm -f "${OPTIMIZATIONS_FILE}"; sysctl --system > /dev/null 2>&1
        echo -e "${GREEN}--> General optimizations file removed and settings reverted.${NC}"
    else
        echo -e "${YELLOW}--> No general optimizations file found to remove.${NC}"
    fi
}
show_optimization_menu() {
    while true; do
        clear; echo "================================================="; echo -e "      ${CYAN}Network Optimizations Menu${NC}"; echo "================================================="
        echo -e "Current Algorithm: ${YELLOW}$(sysctl -n net.ipv4.tcp_congestion_control)${NC}"
        echo "-------------------------------------------------"; echo "1. Install BBR"; echo "2. Remove BBR"; echo "---"; echo "3. Install Cubic"; echo "4. Remove Cubic"
        echo "---"; echo "5. Apply General Optimizations"; echo "6. Remove General Optimizations"
        echo "---"; echo "7. Back to Main Menu"; echo "-------------------------------------------------"; read -p "Enter your choice [1-7]: " opt_choice
        case $opt_choice in
            1) install_bbr; ;; 2) remove_bbr; ;; 3) install_cubic; ;; 4) remove_cubic; ;;
            5) apply_sysctl_optimizations; ;; 6) remove_sysctl_optimizations; ;;
            7) break ;; *) echo -e "${RED}Invalid choice.${NC}";;
        esac; echo -e "${CYAN}Operation complete. Press [Enter]...${NC}"; read -n 1;
    done
}

# --- Main Menu Display and Logic ---
main_menu() {
    while true; do
        clear
        CURRENT_SERVER_IP=$(wget -qO- 'https://api.ipify.org' || echo "N/A")
        echo "================================================="; echo -e "      ${CYAN}APPLOOS FRP TUNNEL${NC} - v17.0"; echo "================================================="
        echo -e "  Developed By ${YELLOW}@AliTabari${NC}"; echo -e "  This Server's Public IP: ${GREEN}${CURRENT_SERVER_IP}${NC}"
        echo "-------------------------------------------------"; echo "  1. Setup IRAN Server (frps)"; echo "  2. Setup FOREIGN Server (frpc)"
        echo "  3. UNINSTALL FRP"; echo "  4. Network Optimizations Menu"; echo "  5. Exit"; echo "-------------------------------------------------"
        read -p "Enter your choice [1-5]: " choice
        case $choice in
            1) setup_iran_server; echo -e "\n${CYAN}Press [Enter]...${NC}"; read ;;
            2) setup_foreign_server; echo -e "\n${CYAN}Press [Enter]...${NC}"; read ;;
            3) uninstall_frp; echo -e "\n${CYAN}Press [Enter]...${NC}"; read ;;
            4) show_optimization_menu ;;
            5) echo -e "${YELLOW}Exiting.${NC}"; exit 0 ;;
            *) echo -e "${RED}Invalid choice.${NC}"; sleep 2 ;;
        esac
    done
}

# --- Script Start ---
check_root
main_menu
