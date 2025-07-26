#!/bin/bash

# ==================================================================================
#
#   APPLOOS FRP TUNNEL - Full Management Script (v24.0 - Final Syntax Fixes)
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
XUI_PANEL_PORT="54333" # Protected Port

# --- Color Codes ---
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

# --- Root Check ---
check_root() { if [[ $EUID -ne 0 ]]; then echo -e "${RED}ERROR: Must be run as root.${NC}"; exit 1; fi; }

# --- Function to check installation status ---
check_install_status() {
    if [ -f "${SYSTEMD_DIR}/frps.service" ] || [ -f "${SYSTEMD_DIR}/frpc.service" ]; then
        echo -e "  FRP Status: ${GREEN}[ ✅ Installed ]${NC}"
    else
        echo -e "  FRP Status: ${RED}[ ❌ Not Installed ]${NC}"
    fi
}

# --- Input Functions ---
get_server_ips() {
    read -p "Enter Public IP for IRAN Server (entry point): " IRAN_SERVER_IP
    if [[ -z "$IRAN_SERVER_IP" ]]; then echo -e "${RED}IP cannot be empty.${NC}"; return 1; fi
    read -p "Enter Public IP for FOREIGN Server (service host): " FOREIGN_SERVER_IP
    if [[ -z "$FOREIGN_SERVER_IP" ]]; then echo -e "${RED}IP cannot be empty.${NC}"; return 1; fi
    return 0
}
get_port_input() {
    echo -e "\n${CYAN}Enter the TCP port(s) you want to tunnel (leave blank if none).${NC}"
    read -p "TCP Ports (e.g., 8080, 20000-30000): " user_tcp_ports
    if [[ "$user_tcp_ports" == *"$XUI_PANEL_PORT"* ]]; then echo -e "\n${RED}ERROR: Tunneling the XUI panel port (${XUI_PANEL_PORT}) is not allowed.${NC}"; return 1; fi
    if [[ -n "$user_tcp_ports" && ! "$user_tcp_ports" =~ ^[0-9,-]+$ ]]; then echo -e "${RED}Invalid TCP port format.${NC}"; return 1; fi
    echo -e "\n${CYAN}Enter the UDP port(s) you want to tunnel (leave blank if none).${NC}"
    read -p "UDP Ports (e.g., 500, 4500): " user_udp_ports
    if [[ "$user_udp_ports" == *"$XUI_PANEL_PORT"* ]]; then echo -e "\n${RED}ERROR: Tunneling the XUI panel port (${XUI_PANEL_PORT}) is not allowed.${NC}"; return 1; fi
    if [[ -n "$user_udp_ports" && ! "$user_udp_ports" =~ ^[0-9,-]+$ ]]; then echo -e "${RED}Invalid UDP port format.${NC}"; return 1; fi
    if [[ -z "$user_tcp_ports" && -z "$user_udp_ports" ]]; then echo -e "${RED}You must enter at least one TCP or UDP port.${NC}"; return 1; fi
    FRP_TCP_PORTS_FRP=$user_tcp_ports; FRP_TCP_PORTS_UFW=${user_tcp_ports//-/:}
    FRP_UDP_PORTS_FRP=$user_udp_ports; FRP_UDP_PORTS_UFW=${user_udp_ports//-/:}
    return 0
}
get_protocol_choice() {
    echo -e "\n${CYAN}Select transport protocol for the main tunnel connection:${NC}\n  1. TCP (Standard)\n  2. QUIC (Recommended for latency)\n  3. WSS (Max Stealth, Requires Domain)"
    read -p "Enter choice [1-3]: " proto_choice
    FRP_PROTOCOL="tcp"; if [[ "$proto_choice" == "2" ]]; then FRP_PROTOCOL="quic"; fi; if [[ "$proto_choice" == "3" ]]; then FRP_PROTOCOL="wss"; fi
    if [[ "$FRP_PROTOCOL" == "wss" ]]; then
        read -p "Enter your domain/subdomain for WSS (e.g., frp.yourdomain.com): " FRP_DOMAIN
        if [[ -z "$FRP_DOMAIN" ]]; then echo -e "${RED}Domain cannot be empty for WSS.${NC}"; return 1; fi
    fi
    TCP_MUX="false"
    if [[ "$FRP_PROTOCOL" == "tcp" || "$FRP_PROTOCOL" == "wss" ]]; then
        read -p $'\n'"Enable TCP Multiplexer (tcpmux) for better performance? [y/N]: " mux_choice
        if [[ "$mux_choice" =~ ^[Yy]$ ]]; then TCP_MUX="true"; fi
    fi
}

# --- Core Logic Functions ---
stop_frp_processes() {
    killall frps > /dev/null 2>&1 || true; killall frpc > /dev/null 2>&1 || true
    systemctl stop frps.service > /dev/null 2>&1; systemctl stop frpc.service > /dev/null 2>&1
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
    cat > ${FRP_INSTALL_DIR}/frps.ini << EOF
[common]
dashboard_addr = 0.0.0.0
dashboard_port = ${FRP_DASHBOARD_PORT}
dashboard_user = admin
dashboard_pwd = FRP_PASSWORD_123
tcp_mux = ${TCP_MUX}
EOF
    case $FRP_PROTOCOL in "tcp") echo "bind_port = ${FRP_TCP_CONTROL_PORT}" >> ${FRP_INSTALL_DIR}/frps.ini ;; "quic") echo "quic_bind_port = ${FRP_QUIC_CONTROL_PORT}" >> ${FRP_INSTALL_DIR}/frps.ini ;; "wss") echo "vhost_https_port = 443" >> ${FRP_INSTALL_DIR}/frps.ini; echo "subdomain_host = ${FRP_DOMAIN}" >> ${FRP_INSTALL_DIR}/frps.ini ;; esac
    if [[ "$FRP_PROTOCOL" == "tcp" ]]; then ufw allow ${FRP_TCP_CONTROL_PORT}/tcp > /dev/null; fi; if [[ "$FRP_PROTOCOL" == "quic" ]]; then ufw allow ${FRP_QUIC_CONTROL_PORT}/udp > /dev/null; fi; if [[ "$FRP_PROTOCOL" == "wss" ]]; then ufw allow 80/tcp > /dev/null; ufw allow 443/tcp > /dev/null; fi
    ufw allow ${FRP_DASHBOARD_PORT}/tcp > /dev/null
    if [ -n "$FRP_TCP_PORTS_UFW" ]; then OLD_IFS=$IFS; IFS=','; read -ra PORTS_ARRAY <<< "$FRP_TCP_PORTS_UFW"; IFS=$OLD_IFS; for port in "${PORTS_ARRAY[@]}"; do ufw allow "$port"/tcp > /dev/null; done; fi
    if [ -n "$FRP_UDP_PORTS_UFW" ]; then OLD_IFS=$IFS; IFS=','; read -ra PORTS_ARRAY <<< "$FRP_UDP_PORTS_UFW"; IFS=$OLD_IFS; for port in "${PORTS_ARRAY[@]}"; do ufw allow "$port"/udp > /dev/null; done; fi
    ufw reload > /dev/null
    cat > ${SYSTEMD_DIR}/frps.service << EOF
[Unit]
Description=FRP Server (frps)
After=network.target

[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5s
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
    cat > ${FRP_INSTALL_DIR}/frpc.ini << EOF
[common]
server_addr = ${IRAN_SERVER_IP}
tcp_mux = ${TCP_MUX}
EOF
    case $FRP_PROTOCOL in "tcp") echo "server_port = ${FRP_TCP_CONTROL_PORT}" >> ${FRP_INSTALL_DIR}/frpc.ini ;; "quic") echo "server_port = ${FRP_QUIC_CONTROL_PORT}" >> ${FRP_INSTALL_DIR}/frpc.ini; echo "protocol = quic" >> ${FRP_INSTALL_DIR}/frpc.ini ;; "wss") echo "server_port = 443" >> ${FRP_INSTALL_DIR}/frpc.ini; echo "protocol = wss" >> ${FRP_INSTALL_DIR}/frpc.ini; echo "tls_enable = true" >> ${FRP_INSTALL_DIR}/frpc.ini; echo "subdomain = frp" >> ${FRP_INSTALL_DIR}/frpc.ini ;; esac
    if [ -n "$FRP_TCP_PORTS_FRP" ]; then
        cat >> ${FRP_INSTALL_DIR}/frpc.ini << EOF

[range:tcp_proxies]
type = tcp
local_ip = 127.0.0.1
local_port = ${FRP_TCP_PORTS_FRP}
remote_port = ${FRP_TCP_PORTS_FRP}
EOF
    fi
    if [ -n "$FRP_UDP_PORTS_FRP" ]; then
        cat >> ${FRP_INSTALL_DIR}/frpc.ini << EOF

[range:udp_proxies]
type = udp
local_ip = 127.0.0.1
local_port = ${FRP_UDP_PORTS_FRP}
remote_port = ${FRP_UDP_PORTS_FRP}
EOF
    fi
    cat > ${SYSTEMD_DIR}/frpc.service << EOF
[Unit]
Description=FRP Client (frpc)
After=network.target

[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5s
ExecStart=${FRP_INSTALL_DIR}/frpc -c ${FRP_INSTALL_DIR}/frpc.ini

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable frpc.service > /dev/null; systemctl restart frpc.service
    echo -e "\n${GREEN}SUCCESS! Foreign Server setup is complete.${NC}"
}
uninstall_frp() {
    echo -e "\n${YELLOW}Uninstalling FRP...${NC}"; stop_frp_processes
    systemctl disable frps.service > /dev/null 2>&1; systemctl disable frpc.service > /dev/null 2>&1
    rm -f ${SYSTEMD_DIR}/frps.service; rm -f ${SYSTEMD_DIR}/frpc.service
    systemctl daemon-reload; rm -rf ${FRP_INSTALL_DIR}
    echo -e "${YELLOW}Note: Firewall rules must be removed manually.${NC}"
    echo -e "\n${GREEN}SUCCESS! FRP has been uninstalled.${NC}"
}

# --- Main Menu Display and Logic ---
main_menu() {
    while true; do
        clear
        CURRENT_SERVER_IP=$(wget -qO- 'https://api.ipify.org' || echo "N/A")
        echo "================================================="; echo -e "      ${CYAN}APPLOOS FRP TUNNEL${NC} - v24.0"; echo "================================================="
        echo -e "  Developed By ${YELLOW}@AliTabari${NC}"; echo -e "  This Server's Public IP: ${GREEN}${CURRENT_SERVER_IP}${NC}"
        check_install_status
        echo "-------------------------------------------------"; echo "  1. Setup/Reconfigure FRP Tunnel"; echo "  2. Uninstall FRP"; echo "  3. Exit"; echo "-------------------------------------------------"
        read -p "Enter your choice [1-3]: " choice
        case $choice in
            1)
                echo -e "\n${CYAN}Which machine is this?${NC}"; echo "  1. This is the IRAN Server (Public Entry)"; echo "  2. This is the FOREIGN Server (Service Host)"
                read -p "Enter choice [1-2]: " setup_choice
                if [[ "$setup_choice" == "1" ]]; then setup_iran_server; elif [[ "$setup_choice" == "2" ]]; then setup_foreign_server; else echo -e "${RED}Invalid choice.${NC}"; fi
                ;;
            2) uninstall_frp ;;
            3) echo -e "${YELLOW}Exiting.${NC}"; exit 0 ;;
            *) echo -e "${RED}Invalid choice.${NC}"; sleep 2 ;;
        esac
        echo -e "\n${CYAN}Operation complete. Press [Enter] to return to menu...${NC}"; read
    done
}

# --- Script Start ---
check_root
main_menu
