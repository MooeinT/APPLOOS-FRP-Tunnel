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
 FRP_TCP_CONTROL_PORT="7000"
 FRP_QUIC_CONTROL_PORT="7001" # Used for UDP and QUIC main connection
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

 get_frp_token() {
    read -p "Please enter the Authentication Token for FRP (a strong, random string): " FRP_TOKEN
    if [ -z "$FRP_TOKEN" ]; then
        echo -e "${RED}Authentication token cannot be empty. Please enter a token.${NC}"
        return 1
    fi # Corrected from 'end' to 'fi'
    return 0
}

 get_port_input() {
     echo -e "\n${CYAN}Enter the TCP port(s) you want to tunnel (leave blank if none).${NC}"
     read -p "TCP Ports (e.g., 8080, 20000-30000): " user_tcp_ports
     if [[ "$user_tcp_ports" == *"$XUI_PANEL_PORT"* ]]; then
         echo -e "\n${RED}ERROR: Tunneling the XUI panel port (${XUI_PANEL_PORT}) is not allowed.${NC}"
         return 1
     fi
     if [[ -n "$user_tcp_ports" && ! "$user_tcp_ports" =~ ^[0-9,-]+$ ]]; then echo -e "${RED}Invalid TCP port format.${NC}"; return 1; fi

     echo -e "\n${CYAN}Enter the UDP port(s) you want to tunnel (leave blank if none).${NC}"
     read -p "UDP Ports (e.g., 500, 4500): " user_udp_ports
     if [[ "$user_udp_ports" == *"$XUI_PANEL_PORT"* ]]; then
         echo -e "\n${RED}ERROR: Tunneling the XUI panel port (${XUI_PANEL_PORT}) is not allowed.${NC}"
         return 1
     fi
     if [[ -n "$user_udp_ports" && ! "$user_udp_ports" =~ ^[0-9,-]+$ ]]; then echo -e "${RED}Invalid UDP port format.${NC}"; return 1; fi

     # Ask if user wants to tunnel HTTP/HTTPS
     echo -e "\n${CYAN}Do you want to tunnel HTTP (port 80) and HTTPS (port 443) via Vhost? [y/N]: ${NC}"
     read -p "Enter choice [y/N]: " http_https_choice
     HTTP_HTTPS_TUNNEL="false"
     if [[ "$http_https_choice" =~ ^[Yy]$ ]]; then
         HTTP_HTTPS_TUNNEL="true"
         read -p "Enter your domain/subdomain for HTTP/HTTPS Vhost (e.g., frp.yourdomain.com): " FRP_DOMAIN
         if [[ -z "$FRP_DOMAIN" ]]; then
             echo -e "${RED}Domain cannot be empty for HTTP/HTTPS Vhost.${NC}"
             return 1
         fi
     fi

     if [[ -z "$user_tcp_ports" && -z "$user_udp_ports" && "$HTTP_HTTPS_TUNNEL" != "true" ]]; then
         echo -e "${RED}You must enter at least one TCP or UDP port, or enable HTTP/HTTPS tunneling.${NC}"
         return 1
     fi

     FRP_TCP_PORTS_FRP=$user_tcp_ports; FRP_TCP_PORTS_UFW=${user_tcp_ports//-/:}
     FRP_UDP_PORTS_FRP=$user_udp_ports; FRP_UDP_PORTS_UFW=${user_udp_ports//-/:}
     return 0
 }

 get_protocol_choice() {
     echo -e "\n${CYAN}Select transport protocol for the main tunnel connection:${NC}"
     echo "  1. TCP (Standard)"
     echo "  2. QUIC (Recommended for latency)"
     echo "  3. STCP (Secret TCP - for private, encrypted TCP tunnels)"
     echo "  4. SUDP (Secret UDP - for private, encrypted UDP tunnels)"
     echo "  5. XTCP (P2P Connect - experimental direct client-to-client connection)"
     read -p "Enter choice [1-5]: " proto_choice
     FRP_PROTOCOL="tcp" # Default
     case "$proto_choice" in
         "1") FRP_PROTOCOL="tcp" ;;
         "2") FRP_PROTOCOL="quic" ;;
         "3") FRP_PROTOCOL="stcp" ;;
         "4") FRP_PROTOCOL="sudp" ;;
         "5") FRP_PROTOCOL="xtcp" ;;
         *) echo -e "${RED}Invalid protocol choice. Defaulting to TCP.${NC}";;
     esac

     TCP_MUX="false"
     # TCP MUX is generally for TCP-based common protocols (or WSS, but WSS is excluded here)
     if [[ "$FRP_PROTOCOL" == "tcp" ]]; then
         read -p $'\n'"Enable TCP Multiplexer (tcpmux) for better performance? [y/N]: " mux_choice
         if [[ "$mux_choice" =~ ^[Yy]$ ]]; then TCP_MUX="true"; fi
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
     ARCH=$(uname -m)
     case "$ARCH" in
         "x86_64") FRP_ARCH="amd64" ;;
         "aarch64") FRP_ARCH="arm64" ;;
         "armv7l") FRP_ARCH="arm" ;;
         "i386") FRP_ARCH="386" ;;
         *) error_exit "Your CPU architecture (${ARCH}) is not supported." ;;
     esac
     FRP_TAR_FILE="frp_${FRP_VERSION}_linux_${FRP_ARCH}.tar.gz"
     wget -q "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FRP_TAR_FILE}" -O "${FRP_INSTALL_DIR}/${FRP_TAR_FILE}"
     tar -zxvf "${FRP_INSTALL_DIR}/${FRP_TAR_FILE}" -C "${FRP_INSTALL_DIR}" --strip-components=1
     rm "${FRP_INSTALL_DIR}/${FRP_TAR_FILE}"
 }
 setup_iran_server() {
     get_server_ips && get_frp_token && get_port_input && get_protocol_choice || return 1
     echo -e "\n${YELLOW}--- Setting up Iran Server (frps) ---${NC}"; stop_frp_processes; download_and_extract
     cat > ${FRP_INSTALL_DIR}/frps.ini << EOF
