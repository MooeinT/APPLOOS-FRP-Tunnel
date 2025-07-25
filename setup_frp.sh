#!/bin/bash

# ==================================================================================
#
#   APPLOOS FRP TUNNEL - Full Management Script (v24.1 - Simplified)
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
# XUI_PANEL_PORT به صورت پویا از سیستم دریافت خواهد شد

# --- Color Codes ---
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

# --- Root Check ---
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}ERROR: Must be run as root.${NC}"
        exit 1
    fi
}

# --- Dependency Management ---
install_dependencies() {
    echo -e "\n${YELLOW}Checking and installing dependencies...${NC}"
    local apt_packages="wget tar ufw sqlite3" # Added sqlite3 for XUI port detection
    local yum_packages="wget tar ufw sqlite" # sqlite for CentOS/RHEL

    if command -v apt &> /dev/null; then
        # Debian/Ubuntu based
        if ! dpkg -s $apt_packages &> /dev/null; then
            apt update -qq > /dev/null
            apt install -y $apt_packages > /dev/null
            if [ $? -ne 0 ]; then
                echo -e "${RED}ERROR: Failed to install APT dependencies. Please check your internet connection or repository settings.${NC}"
                exit 1
            fi
        fi
    elif command -v yum &> /dev/null; then
        # CentOS/RHEL based
        if ! rpm -q $yum_packages &> /dev/null; then
            yum install -y $yum_packages > /dev/null
            if [ $? -ne 0 ]; then
                echo -e "${RED}ERROR: Failed to install YUM dependencies. Please check your internet connection or repository settings.${NC}"
                exit 1
            fi
        fi
    else
        echo -e "${RED}ERROR: Unsupported operating system. Please install wget, tar, ufw, and sqlite manually.${NC}"
        exit 1
    fi
    echo -e "${GREEN}Dependencies check complete.${NC}"
}

# --- Function to check installation status ---
check_install_status() {
    if [ -f "${SYSTEMD_DIR}/frps.service" ] || [ -f "${SYSTEMD_DIR}/frpc.service" ]; then
        echo -e "  FRP Status: ${GREEN}[ ✅ Installed ]${NC}"
    else
        echo -e "  FRP Status: ${RED}[ ❌ Not Installed ]${NC}"
    fi
}

# --- Helper Functions ---
# Function to get XUI panel port dynamically
get_xui_panel_port() {
    # Try to find x-ui port from /etc/x-ui/x-ui.db
    local xui_db="/etc/x-ui/x-ui.db"
    if [ -f "$xui_db" ]; then
        # Use sqlite3 to query the port
        local port=$(sqlite3 "$xui_db" "SELECT value FROM settings WHERE key = 'port';" 2>/dev/null)
        if [[ -n "$port" && "$port" =~ ^[0-9]+$ ]]; then
            XUI_PANEL_PORT="$port"
            echo -e "${GREEN}XUI Panel Port detected: ${XUI_PANEL_PORT}${NC}"
            return 0
        fi
    fi

    # Fallback if x-ui.db not found or port not in DB
    echo -e "${YELLOW}Could not automatically detect XUI Panel Port. If XUI is installed, please enter its port manually.${NC}"
    read -p "Enter XUI Panel Port (e.g., 54333, leave blank if XUI is not installed): " manual_xui_port
    if [[ -n "$manual_xui_port" && "$manual_xui_port" =~ ^[0-9]+$ ]]; then
        XUI_PANEL_PORT="$manual_xui_port"
    else
        XUI_PANEL_PORT="" # No XUI port or invalid input
    fi
    return 0
}

# Function to get a strong password from user
get_strong_password() {
    local prompt_msg="$1"
    local output_var="$2"
    while true; do
        read -s -p "$prompt_msg" password_input
        echo "" # New line after silent input
        if [[ -z "$password_input" ]]; then
            echo -e "${RED}Password cannot be empty. Please try again.${NC}"
        elif [[ "${#password_input}" -lt 8 ]]; then
            echo -e "${RED}Password must be at least 8 characters long. Please try again.${NC}"
        else
            eval "$output_var='$password_input'" # Assign to the variable name passed as argument
            return 0
        fi
    done
}

# Function to get a security token from user
get_security_token() {
    get_strong_password "Enter a Security Token (e.g., a strong passphrase for FRP connection): " FRP_AUTH_TOKEN
}

# --- Input Functions ---
get_server_ips() {
    read -p "Enter Public IP for IRAN Server (entry point): " IRAN_SERVER_IP
    if [[ -z "$IRAN_SERVER_IP" ]]; then echo -e "${RED}IP cannot be empty.${NC}"; return 1; fi
    read -p "Enter Public IP for FOREIGN Server (service host): " FOREIGN_SERVER_IP
    if [[ -z "$FOREIGN_SERVER_IP" ]]; then echo -e "${RED}IP cannot be empty.${NC}"; return 1; fi
    return 0
}

# Merged function for getting TCP and UDP ports
get_tunneled_ports() {
    echo -e "\n${CYAN}Enter the TCP and/or UDP port(s) you want to tunnel.${NC}"
    echo -e "${CYAN}Use commas for multiple ports, e.g., 8080,443. Use hyphens for ranges, e.g., 20000-30000.${NC}"
    echo -e "${CYAN}Specify protocol with /tcp or /udp (e.g., 8080/tcp, 500/udp). Default is TCP if not specified.${NC}"
    read -p "Enter Ports: " user_ports_input

    # Split input into TCP and UDP parts based on /tcp or /udp suffix
    FRP_TCP_PORTS_FRP=""
    FRP_UDP_PORTS_FRP=""

    local temp_tcp_ports=""
    local temp_udp_ports=""

    # Normalize input: remove spaces, convert to lowercase
    local normalized_input=$(echo "$user_ports_input" | tr -d ' ' | tr '[:upper:]' '[:lower:]')

    # Process each segment of the input
    OLD_IFS=$IFS; IFS=','; read -ra PORTS_ARRAY <<< "$normalized_input"; IFS=$OLD_IFS;
    for segment in "${PORTS_ARRAY[@]}"; do
        if [[ "$segment" =~ /tcp$ ]]; then
            port_val=${segment%/*} # Remove /tcp suffix
            if [[ -n "$port_val" && "$port_val" =~ ^[0-9]+(-[0-9]+)?$ ]]; then temp_tcp_ports+="$port_val,"; fi
        elif [[ "$segment" =~ /udp$ ]]; then
            port_val=${segment%/*} # Remove /udp suffix
            if [[ -n "$port_val" && "$port_val" =~ ^[0-9]+(-[0-9]+)?$ ]]; then temp_udp_ports+="$port_val,"; fi
        elif [[ "$segment" =~ ^[0-9]+(-[0-9]+)?$ ]]; then
            # If no /tcp or /udp suffix, default to TCP
            temp_tcp_ports+="$segment,"
        else
            echo -e "${RED}Invalid port format in '$segment'. Skipping.${NC}"
        fi
    done

    # Remove trailing commas
    FRP_TCP_PORTS_FRP=$(echo "$temp_tcp_ports" | sed 's/,$//')
    FRP_UDP_PORTS_FRP=$(echo "$temp_udp_ports" | sed 's/,$//')

    if [[ -z "$FRP_TCP_PORTS_FRP" && -z "$FRP_UDP_PORTS_FRP" ]]; then
        echo -e "${RED}You must enter at least one valid TCP or UDP port.${NC}"
        return 1
    fi

    # Check for XUI panel port conflict
    if [[ -n "$XUI_PANEL_PORT" ]]; then
        local conflict=false
        # Check TCP ports
        if [ -n "$FRP_TCP_PORTS_FRP" ]; then
            OLD_IFS=$IFS; IFS=','; read -ra CHECK_PORTS <<< "$FRP_TCP_PORTS_FRP"; IFS=$OLD_IFS;
            for p_range in "${CHECK_PORTS[@]}"; do
                if [[ "$p_range" =~ "-" ]]; then # It's a range
                    local start_port=$(echo "$p_range" | cut -d'-' -f1)
                    local end_port=$(echo "$p_range" | cut -d'-' -f2)
                    if (( XUI_PANEL_PORT >= start_port && XUI_PANEL_PORT <= end_port )); then conflict=true; break; fi
                elif [[ "$p_range" == "$XUI_PANEL_PORT" ]]; then conflict=true; break; fi
            done
        fi
        
        # Check UDP ports
        if [ "$conflict" == false ] && [ -n "$FRP_UDP_PORTS_FRP" ]; then
            OLD_IFS=$IFS; IFS=','; read -ra CHECK_PORTS <<< "$FRP_UDP_PORTS_FRP"; IFS=$OLD_IFS;
            for p_range in "${CHECK_PORTS[@]}"; do
                if [[ "$p_range" =~ "-" ]]; then # It's a range
                    local start_port=$(echo "$p_range" | cut -d'-' -f1)
                    local end_port=$(echo "$p_range" | cut -d'-' -f2)
                    if (( XUI_PANEL_PORT >= start_port && XUI_PANEL_PORT <= end_port )); then conflict=true; break; fi
                elif [[ "$p_range" == "$XUI_PANEL_PORT" ]]; then conflict=true; break; fi
            done
        fi

        if [[ "$conflict" == true ]]; then
            echo -e "\n${RED}ERROR: Tunneling the XUI panel port (${XUI_PANEL_PORT}) is not allowed as it falls within the specified range/port.${NC}"
            return 1
        fi
    fi

    # Format for UFW: replace hyphens with colons
    FRP_TCP_PORTS_UFW="${FRP_TCP_PORTS_FRP//-/:}"
    FRP_UDP_PORTS_UFW="${FRP_UDP_PORTS_FRP//-/:}"

    # Save ports for later UFW cleanup
    # Overwrite if exists to ensure only current ports are listed
    # Use array for easier management and avoid issues with single line append
    local all_tcp_ports_for_cleanup=()
    local all_udp_ports_for_cleanup=()

    if [[ -n "$FRP_TCP_PORTS_UFW" ]]; then
        OLD_IFS=$IFS; IFS=','; read -ra temp_array <<< "$FRP_TCP_PORTS_UFW"; IFS=$OLD_IFS;
        all_tcp_ports_for_cleanup+=("${temp_array[@]}")
    fi
    if [[ -n "$FRP_UDP_PORTS_UFW" ]]; then
        OLD_IFS=$IFS; IFS=','; read -ra temp_array <<< "$FRP_UDP_PORTS_UFW"; IFS=$OLD_IFS;
        all_udp_ports_for_cleanup+=("${temp_array[@]}")
    fi
    
    # Always include dashboard and control ports in UFW cleanup list
    all_tcp_ports_for_cleanup+=("${FRP_DASHBOARD_PORT}")
    all_tcp_ports_for_cleanup+=("${FRP_TCP_CONTROL_PORT}")
    all_udp_ports_for_cleanup+=("${FRP_QUIC_CONTROL_PORT}") # QUIC control is UDP

    # If WSS, add ports 80 and 443 to cleanup list
    if [[ "$FRP_PROTOCOL" == "wss" ]]; then
        all_tcp_ports_for_cleanup+=("80")
        all_tcp_ports_for_cleanup+=("443")
    fi

    # Write unique ports to files
    printf "%s\n" "${all_tcp_ports_for_cleanup[@]}" | sort -u > "${FRP_INSTALL_DIR}/frp_tcp_ports_ufw.conf"
    printf "%s\n" "${all_udp_ports_for_cleanup[@]}" | sort -u > "${FRP_INSTALL_DIR}/frp_udp_ports_ufw.conf"

    return 0
}

get_protocol_choice() {
    echo -e "\n${CYAN}Select transport protocol for the main tunnel connection:${NC}\n  1. TCP (Standard)\n  2. QUIC (Recommended for latency)\n  3. WSS (Max Stealth, Requires Domain)"
    read -p "Enter choice [1-3]: " proto_choice
    FRP_PROTOCOL="tcp" # Default
    if [[ "$proto_choice" == "2" ]]; then FRP_PROTOCOL="quic"; fi
    if [[ "$proto_choice" == "3" ]]; then FRP_PROTOCOL="wss"; fi

    if [[ "$FRP_PROTOCOL" == "wss" ]]; then
        read -p "Enter your domain/subdomain for WSS (e.g., frp.yourdomain.com): " FRP_DOMAIN
        if [[ -z "$FRP_DOMAIN" ]]; then echo -e "${RED}Domain cannot be empty for WSS.${NC}"; return 1; fi
        read -p "Enter the subdomain used by frpc to connect to frps (e.g., frp. If left blank, 'frp' will be used): " FRP_CLIENT_SUBDOMAIN
        if [[ -z "$FRP_CLIENT_SUBDOMAIN" ]]; then FRP_CLIENT_SUBDOMAIN="frp"; fi
    fi

    TCP_MUX="false"
    if [[ "$FRP_PROTOCOL" == "tcp" || "$FRP_PROTOCOL" == "wss" ]]; then
        read -p $'\n'"Enable TCP Multiplexer (tcpmux) for better performance? [y/N]: " mux_choice
        if [[ "$mux_choice" =~ ^[Yy]$ ]]; then TCP_MUX="true"; fi
    fi
}

# Removed get_advanced_settings function

# --- Core Logic Functions ---
stop_frp_processes() {
    killall frps > /dev/null 2>&1 || true; killall frpc > /dev/null 2>&1 || true
    systemctl stop frps.service > /dev/null 2>&1; systemctl stop frpc.service > /dev/null 2>&1
}

download_and_extract() {
    rm -rf ${FRP_INSTALL_DIR}
    mkdir -p ${FRP_INSTALL_DIR}
    FRP_TAR_FILE="frp_${FRP_VERSION}_linux_amd64.tar.gz"
    echo -e "${YELLOW}Downloading FRP v${FRP_VERSION}...${NC}"
    wget -q "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FRP_TAR_FILE}" -O "${FRP_TAR_FILE}"
    if [ $? -ne 0 ]; then
        echo -e "${RED}ERROR: Failed to download FRP. Please check your internet connection.${NC}"
        exit 1
    fi
    echo -e "${YELLOW}Extracting FRP...${NC}"
    tar -zxvf "${FRP_TAR_FILE}" -C "${FRP_INSTALL_DIR}" --strip-components=1 > /dev/null
    rm "${FRP_TAR_FILE}"
}

add_ufw_rules() {
    echo -e "${YELLOW}--> Setting up firewall (UFW)...${NC}"
    # Main control port
    if [[ "$FRP_PROTOCOL" == "tcp" ]]; then ufw allow ${FRP_TCP_CONTROL_PORT}/tcp comment "FRP TCP Control Port" > /dev/null; fi
    if [[ "$FRP_PROTOCOL" == "quic" ]]; then ufw allow ${FRP_QUIC_CONTROL_PORT}/udp comment "FRP QUIC Control Port" > /dev/null; fi
    if [[ "$FRP_PROTOCOL" == "wss" ]]; then ufw allow 80/tcp comment "FRP WSS HTTP" > /dev/null; ufw allow 443/tcp comment "FRP WSS HTTPS" > /dev/null; fi

    # Dashboard port
    ufw allow ${FRP_DASHBOARD_PORT}/tcp comment "FRP Dashboard" > /dev/null

    # Tunneled TCP ports
    if [ -n "$FRP_TCP_PORTS_UFW" ]; then
        OLD_IFS=$IFS; IFS=','; read -ra PORTS_ARRAY <<< "$FRP_TCP_PORTS_UFW"; IFS=$OLD_IFS;
        for port in "${PORTS_ARRAY[@]}"; do
            ufw allow "$port"/tcp comment "FRP Tunneled TCP Port(s)" > /dev/null
        done
    fi

    # Tunneled UDP ports
    if [ -n "$FRP_UDP_PORTS_UFW" ]; then
        OLD_IFS=$IFS; IFS=','; read -ra PORTS_ARRAY <<< "$FRP_UDP_PORTS_UFW"; IFS=$OLD_IFS;
        for port in "${PORTS_ARRAY[@]}"; do
            ufw allow "$port"/udp comment "FRP Tunneled UDP Port(s)" > /dev/null
        done
    fi
    ufw reload > /dev/null
    echo -e "${GREEN}UFW rules applied.${NC}"
}

remove_ufw_rules() {
    echo -e "${YELLOW}--> Removing firewall rules (UFW)...${NC}"
    local ufw_tcp_rules_file="${FRP_INSTALL_DIR}/frp_tcp_ports_ufw.conf"
    local ufw_udp_rules_file="${FRP_INSTALL_DIR}/frp_udp_ports_ufw.conf"

    if [ -f "$ufw_tcp_rules_file" ]; then
        while IFS= read -r port_rule; do
            # Split by comma to handle multiple port rules on one line (e.g., 8080,20000:30000)
            OLD_IFS=$IFS; IFS=','; read -ra INDIVIDUAL_PORTS <<< "$port_rule"; IFS=$OLD_IFS;
            for p_rule in "${INDIVIDUAL_PORTS[@]}"; do
                if [[ "$p_rule" =~ ^[0-9]+(:[0-9]+)?$ ]]; then # Match single port or range (e.g., 80 or 20000:30000)
                    ufw delete allow "$p_rule"/tcp > /dev/null 2>&1 || true
                fi
            done
        done < "$ufw_tcp_rules_file"
        rm -f "$ufw_tcp_rules_file"
    fi

    if [ -f "$ufw_udp_rules_file" ]; then
        while IFS= read -r port_rule; do
            OLD_IFS=$IFS; IFS=','; read -ra INDIVIDUAL_PORTS <<< "$port_rule"; IFS=$OLD_IFS;
            for p_rule in "${INDIVIDUAL_PORTS[@]}"; do
                if [[ "$p_rule" =~ ^[0-9]+(:[0-9]+)?$ ]]; then
                    ufw delete allow "$p_rule"/udp > /dev/null 2>&1 || true
                fi
            done
        done < "$ufw_udp_rules_file"
    rm -f "$ufw_udp_rules_file"
    fi
    ufw reload > /dev/null 2>&1 || true # Reload UFW even if no rules were found
    echo -e "${GREEN}UFW rules removed.${NC}"
}

setup_iran_server() {
    get_server_ips && get_tunneled_ports && get_protocol_choice && get_strong_password "Enter a strong password for FRP Dashboard: " FRP_DASHBOARD_PASSWORD && get_security_token || return 1
    
    echo -e "\n${YELLOW}--- Setting up Iran Server (frps) ---${NC}"
    stop_frp_processes
    download_and_extract

    # Ensure previous UFW rules are cleared before adding new ones
    remove_ufw_rules # Important: clear old rules from previous config/installation

    cat > ${FRP_INSTALL_DIR}/frps.ini << EOF
[common]
dashboard_addr = 0.0.0.0
dashboard_port = ${FRP_DASHBOARD_PORT}
dashboard_user = admin
dashboard_pwd = ${FRP_DASHBOARD_PASSWORD}
tcp_mux = ${TCP_MUX}
authentication_method = token
token = ${FRP_AUTH_TOKEN}
log_file = /var/log/frps.log
log_level = info
log_max_days = 3
EOF

    case $FRP_PROTOCOL in # <--- Added 'in' here
        "tcp") echo "bind_port = ${FRP_TCP_CONTROL_PORT}" >> ${FRP_INSTALL_DIR}/frps.ini ;;
        "quic") echo "quic_bind_port = ${FRP_QUIC_CONTROL_PORT}" >> ${FRP_INSTALL_DIR}/frps.ini ;;
        "wss")
            echo "vhost_https_port = 443" >> ${FRP_INSTALL_DIR}/frps.ini
            echo "subdomain_host = ${FRP_DOMAIN}" >> ${FRP_INSTALL_DIR}/frps.ini
            ;;
    esac # <--- Added 'esac' here

    add_ufw_rules # Add new UFW rules

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
ExecReload=/bin/kill -HUP $MAINPID

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable frps.service > /dev/null
    systemctl restart frps.service
    
    echo -e "\n${GREEN}SUCCESS! Iran Server setup is complete.${NC}"
    display_post_installation_info "frps"
}

setup_foreign_server() {
    get_server_ips && get_xui_panel_port && get_tunneled_ports && get_protocol_choice && get_security_token || return 1
    
    echo -e "\n${YELLOW}--- Setting up Foreign Server (frpc) ---${NC}"
    stop_frp_processes
    download_and_extract

    cat > ${FRP_INSTALL_DIR}/frpc.ini << EOF
[common]
server_addr = ${IRAN_SERVER_IP}
tcp_mux = ${TCP_MUX}
authentication_method = token
token = ${FRP_AUTH_TOKEN}
log_file = /var/log/frpc.log
log_level = info
log_max_days = 3
EOF

    case $FRP_PROTOCOL in # <--- Added 'in' here
        "tcp") echo "server_port = ${FRP_TCP_CONTROL_PORT}" >> ${FRP_INSTALL_DIR}/frpc.ini ;;
        "quic")
            echo "server_port = ${FRP_QUIC_CONTROL_PORT}" >> ${FRP_INSTALL_DIR}/frpc.ini
            echo "protocol = quic" >> ${FRP_INSTALL_DIR}/frpc.ini
            ;;
        "wss")
            echo "server_port = 443" >> ${FRP_INSTALL_DIR}/frpc.ini
            echo "protocol = wss" >> ${FRP_INSTALL_DIR}/frpc.ini
            echo "tls_enable = true" >> ${FRP_INSTALL_DIR}/frpc.ini
            echo "subdomain = ${FRP_CLIENT_SUBDOMAIN}" >> ${FRP_INSTALL_DIR}/frpc.ini
            ;;
    esac # <--- Added 'esac' here

    # Add general TCP/UDP range proxies
    if [ -n "$FRP_TCP_PORTS_FRP" ]; then
        cat >> ${FRP_INSTALL_DIR}/frpc.ini << EOF
[range:tcp_proxies]
type = tcp
local_ip = 127.0.0.1
local_port = ${FRP_TCP_PORTS_FRP}
remote_port = ${FRP_TCP_PORTS_FRP}
use_compression = true
max_pool_count = 5 # Defaulted to 5 after removing advanced options
EOF
    fi

    if [ -n "$FRP_UDP_PORTS_FRP" ]; then
        cat >> ${FRP_INSTALL_DIR}/frpc.ini << EOF
[range:udp_proxies]
type = udp
local_ip = 127.0.0.1
local_port = ${FRP_UDP_PORTS_FRP}
remote_port = ${FRP_UDP_PORTS_FRP}
use_compression = true
max_pool_count = 5 # Defaulted to 5 after removing advanced options
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
ExecReload=/bin/kill -HUP $MAINPID

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable frpc.service > /dev/null
    systemctl restart frpc.service
    
    echo -e "\n${GREEN}SUCCESS! Foreign Server setup is complete.${NC}"
    display_post_installation_info "frpc"
}

uninstall_frp() {
    echo -e "\n${YELLOW}Uninstalling FRP...${NC}"
    stop_frp_processes
    remove_ufw_rules # Call the new function to remove UFW rules

    systemctl disable frps.service > /dev/null 2>&1
    systemctl disable frpc.service > /dev/null 2>&1
    rm -f ${SYSTEMD_DIR}/frps.service
    rm -f ${SYSTEMD_DIR}/frpc.service
    systemctl daemon-reload
    rm -rf ${FRP_INSTALL_DIR}
    
    echo -e "\n${GREEN}SUCCESS! FRP has been uninstalled.${NC}"
}

# --- Post-Installation Information Display ---
display_post_installation_info() {
    local frp_type="$1" # frps or frpc
    echo -e "\n${CYAN}--- FRP Post-Installation Information ---${NC}"
    echo -e "Service Status:"
    if systemctl is-active --quiet "${frp_type}.service"; then
        echo -e "${GREEN}  FRP ${frp_type} service is running.${NC}"
    else
        echo -e "${RED}  FRP ${frp_type} service is NOT running. Check logs for errors.${NC}"
    fi

    echo -e "\nFRP Configuration File:"
    echo -e "${GREEN}  ${FRP_INSTALL_DIR}/${frp_type}.ini${NC}"
    
    echo -e "FRP Service Log File:"
    echo -e "${GREEN}  /var/log/${frp_type}.log${NC}"
    echo -e "  To view logs: ${YELLOW}tail -f /var/log/${frp_type}.log${NC}"

    if [ "$frp_type" == "frps" ]; then
        echo -e "\nFRP Dashboard Access:"
        echo -e "${GREEN}  URL: http://${IRAN_SERVER_IP}:${FRP_DASHBOARD_PORT}${NC}"
        echo -e "${GREEN}  User: admin${NC}"
        echo -e "${GREEN}  Password: (The password you entered during setup)${NC}"
    fi

    echo -e "\nUseful Commands:"
    echo -e "${YELLOW}  Check service status: systemctl status ${frp_type}.service${NC}"
    echo -e "${YELLOW}  Stop service: systemctl stop ${frp_type}.service${NC}"
    echo -e "${YELLOW}  Start service: systemctl start ${frp_type}.service${NC}"
    echo -e "${YELLOW}  Restart service: systemctl restart ${frp_type}.service${NC}"
    echo -e "${YELLOW}  Disable service (prevent auto-start): systemctl disable ${frp_type}.service${NC}"
    echo -e "${YELLOW}  Enable service (allow auto-start): systemctl enable ${frp_type}.service${NC}"

    echo -e "\nFirewall Information (UFW):"
    echo -e "${YELLOW}  To list UFW rules: sudo ufw status verbose${NC}"
}

# --- Main Menu Display and Logic ---
main_menu() {
    while true; do
        clear
        CURRENT_SERVER_IP=$(wget -qO- 'https://api.ipify.org' || echo "N/A")
        echo "================================================="
        echo -e "      ${CYAN}APPLOOS FRP TUNNEL${NC} - v24.1"
        echo "================================================="
        echo -e "  Developed By ${YELLOW}@AliTabari${NC}"
        echo -e "  This Server's Public IP: ${GREEN}${CURRENT_SERVER_IP}${NC}"
        check_install_status
        echo "-------------------------------------------------"
        echo "  1. Setup/Reconfigure FRP Tunnel"
        echo "  2. Uninstall FRP"
        echo "  3. Exit"
        echo "-------------------------------------------------"
        read -p "Enter your choice [1-3]: " choice
        case $choice in
            1)
                echo -e "\n${CYAN}Which machine is this?${NC}"
                echo "  1. This is the IRAN Server (Public Entry)"
                echo "  2. This is the FOREIGN Server (Service Host)"
                read -p "Enter choice [1-2]: " setup_choice
                if [[ "$setup_choice" == "1" ]]; then
                    setup_iran_server
                elif [[ "$setup_choice" == "2" ]]; then
                    setup_foreign_server
                else
                    echo -e "${RED}Invalid choice.${NC}"
                fi
                ;;
            2) uninstall_frp ;;
            3) echo -e "${YELLOW}Exiting.${NC}"; exit 0 ;;
            *) echo -e "${RED}Invalid choice.${NC}"; sleep 2 ;;
        esac
        echo -e "\n${CYAN}Operation complete. Press [Enter] to return to menu...${NC}"; read -r
    done
}

# --- Script Start ---
check_root
install_dependencies
main_menu
