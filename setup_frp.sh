#!/bin/bash

# ==================================================================================
#
#    APPLOOS FRP TUNNEL - Full Management Script (v23.0 - With XUI Port Protection)
#    Developed By: @AliTabari
#    Purpose: Automate the installation, configuration, and management of FRP.
#
# ==================================================================================

# --- Static Configuration Variables ---
FRP_VERSION="0.59.0"
FRP_INSTALL_DIR="/opt/frp"
SYSTEMD_DIR="/etc/systemd/system"
FRP_TCP_CONTROL_PORT="7000" # FIXED for troubleshooting
FRP_QUIC_CONTROL_PORT="7001" # Will not be used in this troubleshooting step
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

# --- Input Functions (Updated with XUI Port Protection) ---
get_server_ips() {
    read -p "Enter Public IP for IRAN Server (entry point): " IRAN_SERVER_IP
    if [[ -z "$IRAN_SERVER_IP" ]]; then echo -e "${RED}IP cannot be empty.${NC}"; return 1; fi
    read -p "Enter Public IP for FOREIGN Server (service host): " FOREIGN_SERVER_IP
    if [[ -z "$FOREIGN_SERVER_IP" ]]; then echo -e "${RED}IP cannot be empty.${NC}"; return 1; fi
    return 0
}

get_port_input() {
    user_tcp_ports=""
    user_udp_ports=""
    HTTP_HTTPS_TUNNEL="false"
    FRP_DOMAIN=""

    echo -e "\n${CYAN}Enter the TCP port(s) you want to tunnel (e.g., 8080, 20000-30000).${NC}"
    read -p "TCP Ports: " user_tcp_ports
    # Validate TCP ports format and XUI port conflict
    if [[ -n "$user_tcp_ports" ]]; then
        if [[ "$user_tcp_ports" == *"$XUI_PANEL_PORT"* ]]; then
            echo -e "\n${RED}ERROR: Tunneling the XUI panel port (${XUI_PANEL_PORT}) is not allowed.${NC}"
            return 1
        fi
        if ! [[ "$user_tcp_ports" =~ ^[0-9,-]+$ ]]; then
            echo -e "${RED}Invalid TCP port format.${NC}"
            return 1
        fi
    fi

    echo -e "\n${CYAN}Enter the UDP port(s) you want to tunnel (e.g., 500, 4500, or leave blank).${NC}"
    read -p "UDP Ports: " user_udp_ports
    # Validate UDP ports format and XUI port conflict
    if [[ -n "$user_udp_ports" ]]; then
        if [[ "$user_udp_ports" == *"$XUI_PANEL_PORT"* ]]; then
            echo -e "\n${RED}ERROR: Tunneling the XUI panel port (${XUI_PANEL_PORT}) is not allowed.${NC}"
            return 1
        fi
        if ! [[ "$user_udp_ports" =~ ^[0-9,-]+$ ]]; then
            echo -e "${RED}Invalid UDP port format.${NC}"
            return 1
        fi
    fi

    echo -e "\n${CYAN}Do you want to tunnel HTTP (port 80) and HTTPS (port 443) via Vhost? [y/N]: ${NC}"
    read -p "Enter choice [y/N]: " http_https_choice
    if [[ "$http_https_choice" =~ ^[Yy]$ ]]; then
        HTTP_HTTPS_TUNNEL="true"
        read -p "Enter your domain/subdomain for HTTP/HTTPS Vhost (e.g., frp.yourdomain.com): " FRP_DOMAIN
        if [[ -z "$FRP_DOMAIN" ]]; then
            echo -e "${RED}Domain cannot be empty for HTTP/HTTPS Vhost.${NC}"
            return 1
        fi
    fi

    # Combined check: MUST have at least one valid option (TCP, UDP, or HTTP/HTTPS)
    if [[ -z "$user_tcp_ports" && -z "$user_udp_ports" && "$HTTP_HTTPS_TUNNEL" != "true" ]]; then
        echo -e "${RED}You must enter at least one TCP or UDP port, or enable HTTP/HTTPS tunneling.${NC}"
        return 1
    fi

    FRP_TCP_PORTS_FRP=$user_tcp_ports
    FRP_TCP_PORTS_UFW=${user_tcp_ports//-/:} # Convert 20000-30000 to 20000:30000 for UFW
    FRP_UDP_PORTS_FRP=$user_udp_ports
    FRP_UDP_PORTS_UFW=${user_udp_ports//-/:} # Convert 20000-30000 to 20000:30000 for UFW
    return 0
}

# Protocol and TCP_MUX are now fixed for troubleshooting
get_protocol_choice() {
    FRP_PROTOCOL="tcp" # Fixed to TCP for troubleshooting
    TCP_MUX="false"    # Fixed to false for troubleshooting
    echo -e "\n${YELLOW}Using fixed protocol: TCP, TCP Multiplexer: Disabled (for troubleshooting).${NC}"
    # If WSS was chosen in previous step via HTTP_HTTPS_TUNNEL, we need to ensure FRP_DOMAIN is set.
    # This scenario is less likely as we are forcing TCP, but keeping for robustness.
    if [[ "$HTTP_HTTPS_TUNNEL" == "true" && -z "$FRP_DOMAIN" ]]; then
        echo -e "${RED}ERROR: Domain must be set for HTTP/HTTPS Vhost even with TCP protocol selected in this troubleshooting step.${NC}"
        return 1
    fi
    return 0
}

# --- Core Logic Functions ---
stop_frp_processes() {
    killall frps > /dev/null 2>&1 || true; killall frpc > /dev/null 2>&1 || true
    systemctl stop frps.service > /dev/null 2>&1; systemctl stop frpc.service > /dev/null 2>&1
}

download_and_extract() {
    rm -rf "${FRP_INSTALL_DIR}"; mkdir -p "${FRP_INSTALL_DIR}"
    # Detect architecture dynamically
    ARCH=$(uname -m)
    case "$ARCH" in
        "x86_64") FRP_ARCH="amd64" ;;
        "aarch64") FRP_ARCH="arm64" ;;
        "armv7l") FRP_ARCH="arm" ;;
        "i386") FRP_ARCH="386" ;;
        *) echo -e "${RED}Your CPU architecture (${ARCH}) is not supported.${NC}"; exit 1 ;;
    esac
    FRP_TAR_FILE="frp_${FRP_VERSION}_linux_${FRP_ARCH}.tar.gz"
    
    wget -q "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FRP_TAR_FILE}" -O "${FRP_INSTALL_DIR}/${FRP_TAR_FILE}"
    if [ $? -ne 0 ]; then
        echo -e "${RED}ERROR: Failed to download FRP binary. Check internet connection or FRP version/architecture.${NC}"
        exit 1
    fi
    tar -zxvf "${FRP_INSTALL_DIR}/${FRP_TAR_FILE}" -C "${FRP_INSTALL_DIR}" --strip-components=1
    if [ $? -ne 0 ]; then
        echo -e "${RED}ERROR: Failed to extract FRP files. The downloaded archive might be corrupted.${NC}"
        exit 1
    fi
    rm "${FRP_INSTALL_DIR}/${FRP_TAR_FILE}"
    
    # Ensure the binaries are executable
    chmod +x "${FRP_INSTALL_DIR}/frps" "${FRP_INSTALL_DIR}/frpc"
    if [ $? -ne 0 ]; then
        echo -e "${RED}ERROR: Failed to set executable permissions for FRP binaries.${NC}"
        exit 1
    fi
}

setup_iran_server() {
    get_server_ips && get_port_input && get_protocol_choice || return 1
    echo -e "\n${YELLOW}--- Setting up Iran Server (frps) ---${NC}"; stop_frp_processes; download_and_extract
    cat > ${FRP_INSTALL_DIR}/frps.ini << EOF
[common]
dashboard_addr = 0.0.0.0
dashboard_port = ${FRP_DASHBOARD_PORT}
dashboard_user = admin
dashboard_pwd = FRP_PASSWORD_123 # IMPORTANT: CHANGE THIS PASSWORD IMMEDIATELY!
bind_port = ${FRP_TCP_CONTROL_PORT} # Fixed to TCP control port
tcp_mux = ${TCP_MUX} # Fixed for troubleshooting
EOF

    # If HTTP/HTTPS tunnel is chosen, add vhost_https_port
    if [[ "$HTTP_HTTPS_TUNNEL" == "true" ]]; then
        cat >> ${FRP_INSTALL_DIR}/frps.ini << EOF
vhost_https_port = 443
subdomain_host = ${FRP_DOMAIN}
EOF
    fi

    echo -e "${YELLOW}--> Setting up firewall...${NC}"
    sudo ufw allow ssh comment "Allow SSH" > /dev/null
    sudo ufw allow ${FRP_TCP_CONTROL_PORT}/tcp comment "FRP TCP Control" > /dev/null # Allow the fixed TCP control port
    if [[ "$HTTP_HTTPS_TUNNEL" == "true" ]]; then
        sudo ufw allow 80/tcp comment "FRP HTTP Vhost" > /dev/null
        sudo ufw allow 443/tcp comment "FRP HTTPS Vhost" > /dev/null
    fi
    sudo ufw allow ${FRP_DASHBOARD_PORT}/tcp comment "FRP Dashboard" > /dev/null

    # Allow user-specified TCP/UDP ports for range proxies
    if [ -n "$FRP_TCP_PORTS_UFW" ]; then OLD_IFS=$IFS; IFS=','; read -ra PORTS_ARRAY <<< "$FRP_TCP_PORTS_UFW"; IFS=$OLD_IFS; for port in "${PORTS_ARRAY[@]}"; do sudo ufw allow "$port"/tcp > /dev/null; done; fi
    if [ -n "$FRP_UDP_PORTS_UFW" ]; then OLD_IFS=$IFS; IFS=','; read -ra PORTS_ARRAY <<< "$FRP_UDP_PORTS_UFW"; IFS=$OLD_IFS; for port in "${PORTS_ARRAY[@]}"; do sudo ufw allow "$port"/udp > /dev/null; done; fi
    sudo ufw reload > /dev/null

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
server_port = ${FRP_TCP_CONTROL_PORT} # Fixed to TCP control port
tcp_mux = ${TCP_MUX} # Fixed for troubleshooting
loginFailExit = false # Keep trying to connect
EOF

    # If HTTP/HTTPS tunnel is chosen, add vhost_http_port/vhost_https_port
    if [[ "$HTTP_HTTPS_TUNNEL" == "true" ]]; then
        cat >> ${FRP_INSTALL_DIR}/frpc.ini << EOF

[http_proxy]
type = http
local_ip = 127.0.0.1
local_port = 80
remote_port = 80
subdomain = http # You might want to change this
use_compression = true

[https_proxy]
type = https
local_ip = 127.0.0.1
local_port = 443
remote_port = 443
subdomain = https # You might want to change this
use_compression = true
EOF
    fi

    # Add TCP range proxies ONLY if ports were specified by user
    if [ -n "$FRP_TCP_PORTS_FRP" ]; then
        cat >> ${FRP_INSTALL_DIR}/frpc.ini << EOF

[range:tcp_proxies]
type = tcp
local_ip = 127.0.0.1
local_port = ${FRP_TCP_PORTS_FRP}
remote_port = ${FRP_TCP_PORTS_FRP}
EOF
    fi

    # Add UDP range proxies ONLY if ports were specified by user
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
         echo "================================================="; echo -e "     ${CYAN}APPLOOS FRP TUNNEL${NC} - v23.0"; echo "================================================="
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
