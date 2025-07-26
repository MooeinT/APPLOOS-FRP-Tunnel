#!/bin/bash

# ==================================================================================
#
#   APPLOOS FRP TUNNEL - Full Management Script (v50.0 - Final WSS/Nginx Fix)
#   Developed By: @AliTabari
#   Purpose: Automate the installation, configuration, and management of FRP.
#
# ==================================================================================

# --- Static Configuration Variables ---
FRP_VERSION="0.62.1"
FRP_INSTALL_DIR="/opt/frp"
SYSTEMD_DIR="/etc/systemd/system"
FRP_TCP_CONTROL_PORT="7000"
FRP_KCP_CONTROL_PORT="7002"
FRP_QUIC_CONTROL_PORT="7001"
FRP_DASHBOARD_PORT="7500"
XUI_PANEL_PORT="54333"

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
    echo -e "\n${CYAN}Please enter the port(s) you want to tunnel for BOTH TCP & UDP.${NC}"
    echo -e "Examples:\n  - A single port: ${YELLOW}8080${NC}\n  - A range: ${YELLOW}20000-30000${NC}\n  - A mix: ${YELLOW}80,443,9000-9100${NC}"
    read -p "Enter ports: " user_ports
    if [[ -z "$user_ports" ]]; then echo -e "${RED}No ports entered.${NC}"; return 1; fi
    if [[ "$user_ports" == *"$XUI_PANEL_PORT"* ]]; then echo -e "\n${RED}ERROR: Tunneling the XUI panel port (${XUI_PANEL_PORT}) is not allowed.${NC}"; return 1; fi
    if ! [[ "$user_ports" =~ ^[0-9,-]+$ ]]; then echo -e "${RED}Invalid format.${NC}"; return 1; fi
    FRP_TUNNEL_PORTS_FRP=$user_ports; FRP_TUNNEL_PORTS_UFW=${user_ports//-/:}; return 0
}
get_protocol_choice() {
    echo -e "\n${CYAN}Select the main transport protocol for the tunnel:${NC}"
    echo "  1. TCP (Standard)"; echo "  2. KCP (Fast on lossy networks)"; echo "  3. QUIC (Modern & fast, UDP-based)"
    echo "  4. WSS (Max stealth, requires domain & auto-installs Nginx)"
    read -p "Enter your choice [1-4]: " proto_choice
    case $proto_choice in 2) FRP_PROTOCOL="kcp" ;; 3) FRP_PROTOCOL="quic" ;; 4) FRP_PROTOCOL="wss" ;; *) FRP_PROTOCOL="tcp" ;; esac
    if [[ "$FRP_PROTOCOL" == "wss" ]]; then
        read -p "Enter your domain pointed to the Iran server (e.g., frp.yourdomain.com): " FRP_DOMAIN
        if [[ -z "$FRP_DOMAIN" ]]; then echo -e "${RED}Domain cannot be empty for WSS.${NC}"; return 1; fi
    fi
    TCP_MUX="false"
    if [[ "$FRP_PROTOCOL" == "tcp" || "$FRP_PROTOCOL" == "kcp" ]]; then # WSS MUX is buggy
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
    FRP_DOWNLOAD_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FRP_TAR_FILE}";
    wget -q "${FRP_DOWNLOAD_URL}" -O "${FRP_TAR_FILE}"; tar -zxvf "${FRP_TAR_FILE}" -C "${FRP_INSTALL_DIR}" --strip-components=1; rm "${FRP_TAR_FILE}"
    echo -e "${GREEN}--> FRP version $(${FRP_INSTALL_DIR}/frps --version) downloaded successfully.${NC}"
}
setup_iran_server() {
    get_server_ips && get_port_input && get_protocol_choice || return 1
    echo -e "\n${YELLOW}--- Setting up Iran Server (frps) ---${NC}"; stop_frp_processes; download_and_extract
    
    if [ "$FRP_PROTOCOL" == "wss" ]; then
        echo -e "${YELLOW}--> WSS mode: Installing Nginx & Certbot...${NC}"; apt-get update -y > /dev/null && apt-get install nginx certbot python3-certbot-nginx -y > /dev/null
        if [ $? -ne 0 ]; then echo -e "${RED}Failed to install Nginx/Certbot.${NC}"; return 1; fi
        systemctl stop nginx
        echo -e "${YELLOW}--> Obtaining SSL certificate for ${FRP_DOMAIN}...${NC}";
        certbot certonly --standalone --agree-tos --non-interactive --email you@example.com -d ${FRP_DOMAIN}
        if [ $? -ne 0 ]; then echo -e "${RED}Failed to obtain SSL certificate. Check your DNS record for ${FRP_DOMAIN} and that port 80 is open.${NC}"; systemctl start nginx; return 1; fi
        echo -e "${YELLOW}--> Configuring Nginx as a reverse proxy...${NC}"
        cat > /etc/nginx/sites-available/default << EOF
server {
    listen 80;
    server_name ${FRP_DOMAIN};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name ${FRP_DOMAIN};
    ssl_certificate /etc/letsencrypt/live/${FRP_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${FRP_DOMAIN}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    location / {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${FRP_TCP_CONTROL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
EOF
        systemctl restart nginx
        cat > ${FRP_INSTALL_DIR}/frps.ini << EOF
[common]
bind_port = ${FRP_TCP_CONTROL_PORT}
subdomain_host = ${FRP_DOMAIN}
dashboard_addr = 127.0.0.1
dashboard_port = ${FRP_DASHBOARD_PORT}
dashboard_user = admin
dashboard_pwd = FRP_PASSWORD_123
tcp_mux = ${TCP_MUX}
EOF
    else
        cat > ${FRP_INSTALL_DIR}/frps.ini << EOF
[common]
dashboard_addr = 0.0.0.0
dashboard_port = ${FRP_DASHBOARD_PORT}
dashboard_user = admin
dashboard_pwd = FRP_PASSWORD_123
tcp_mux = ${TCP_MUX}
EOF
        if [[ "$FRP_PROTOCOL" == "tcp" || "$FRP_PROTOCOL" == "kcp" || "$FRP_PROTOCOL" == "quic" ]]; then echo "bind_port = ${FRP_TCP_CONTROL_PORT}" >> ${FRP_INSTALL_DIR}/frps.ini; fi
        if [[ "$FRP_PROTOCOL" == "kcp" ]]; then echo "kcp_bind_port = ${FRP_KCP_CONTROL_PORT}" >> ${FRP_INSTALL_DIR}/frps.ini; fi
        if [[ "$FRP_PROTOCOL" == "quic" ]]; then echo "quic_bind_port = ${FRP_QUIC_CONTROL_PORT}" >> ${FRP_INSTALL_DIR}/frps.ini; fi
    fi

    echo -e "${YELLOW}--> Setting up firewall...${NC}"; ufw allow ${FRP_TCP_CONTROL_PORT}/tcp > /dev/null
    if [[ "$FRP_PROTOCOL" == "kcp" ]]; then ufw allow ${FRP_KCP_CONTROL_PORT}/udp > /dev/null; fi
    if [[ "$FRP_PROTOCOL" == "quic" ]]; then ufw allow ${FRP_QUIC_CONTROL_PORT}/udp > /dev/null; fi
    if [[ "$FRP_PROTOCOL" == "wss" ]]; then ufw allow 80/tcp > /dev/null; ufw allow 443/tcp > /dev/null; else ufw allow ${FRP_DASHBOARD_PORT}/tcp > /dev/null; fi
    OLD_IFS=$IFS; IFS=','; read -ra PORTS_ARRAY <<< "$FRP_TUNNEL_PORTS_UFW"; IFS=$OLD_IFS
    for port in "${PORTS_ARRAY[@]}"; do ufw allow "$port"/tcp > /dev/null; ufw allow "$port"/udp > /dev/null; done
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
    if [[ "$FRP_PROTOCOL" == "tcp" || "$FRP_PROTOCOL" == "kcp" || "$FRP_PROTOCOL" == "quic" ]]; then echo "server_port = ${FRP_TCP_CONTROL_PORT}" >> ${FRP_INSTALL_DIR}/frpc.ini; fi
    case $FRP_PROTOCOL in "kcp") echo "transport.protocol = kcp" >> ${FRP_INSTALL_DIR}/frpc.ini ;; "quic") echo "transport.protocol = quic" >> ${FRP_INSTALL_DIR}/frpc.ini ;; "wss") echo "server_port = 443" >> ${FRP_INSTALL_DIR}/frpc.ini; echo "transport.protocol = wss" >> ${FRP_INSTALL_DIR}/frpc.ini; echo "tls_enable = true" >> ${FRP_INSTALL_DIR}/frpc.ini; echo "server_name = ${FRP_DOMAIN}" >> ${FRP_INSTALL_DIR}/frpc.ini ;; esac
    
    cat >> ${FRP_INSTALL_DIR}/frpc.ini << EOF

[range:tcp_proxies]
type = tcp
local_ip = 127.0.0.1
local_port = ${FRP_TUNNEL_PORTS_FRP}
remote_port = ${FRP_TUNNEL_PORTS_FRP}

[range:udp_proxies]
type = udp
local_ip = 127.0.0.1
local_port = ${FRP_TUNNEL_PORTS_FRP}
remote_port = ${FRP_TUNNEL_PORTS_FRP}
EOF
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
    if [ -d "/etc/nginx" ]; then if [ -f "/etc/nginx/sites-available/default.bak" ]; then mv /etc/nginx/sites-available/default.bak /etc/nginx/sites-available/default; systemctl restart nginx > /dev/null 2>&1; echo -e "${YELLOW}--> Restored old Nginx config.${NC}"; fi; fi
    echo -e "${YELLOW}Note: Firewall rules must be removed manually.${NC}"; echo -e "\n${GREEN}SUCCESS! FRP has been uninstalled.${NC}"
}
main_menu() {
    while true; do
        clear; CURRENT_SERVER_IP=$(wget -qO- 'https://api.ipify.org' || echo "N/A")
        echo "================================================="; echo -e "      ${CYAN}APPLOOS FRP TUNNEL${NC} - v50.0"; echo "================================================="
        echo -e "  Developed By ${YELLOW}@AliTabari${NC}"; echo -e "  This Server's Public IP: ${GREEN}${CURRENT_SERVER_IP}${NC}"; check_install_status
        echo "-------------------------------------------------"; echo "  1. Setup/Reconfigure FRP Tunnel"; echo "  2. Uninstall FRP"; echo "  3. Exit"; echo "-------------------------------------------------"
        read -p "Enter your choice [1-3]: " choice
        case $choice in
            1)
                echo -e "\n${CYAN}Which machine is this?${NC}"; echo "  1. IRAN Server (Public Entry)"; echo "  2. FOREIGN Server (Service Host)"
                read -p "Enter choice [1-2]: " setup_choice
                if [[ "$setup_choice" == "1" ]]; then setup_iran_server; elif [[ "$setup_choice" == "2" ]]; then setup_foreign_server; else echo -e "${RED}Invalid choice.${NC}"; fi
                ;;
            2) uninstall_frp ;;
            3) echo -e "${YELLOW}Exiting.${NC}"; exit 0 ;;
            *) echo -e "${RED}Invalid choice.${NC}"; sleep 2 ;;
        esac
        echo -e "\n${CYAN}Operation complete. Press [Enter] to return...${NC}"; read
    done
}
check_root
main_menu
