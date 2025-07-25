#!/bin/bash

# Define FRP version to install
FRP_VERSION="0.59.0" # You can change this to a newer version if available

# Define FRP installation directory
INSTALL_DIR="/opt/frp"

# Function to display error messages
error_exit() {
    echo "Error: $1" >&2
    exit 1
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to install dependencies
install_dependencies() {
    echo "Installing required packages..."
    sudo apt update || error_exit "Failed to update packages."
    sudo apt install -y curl unzip || error_exit "Failed to install curl and unzip."
}

# Function to download and install FRP
install_frp() {
    echo "Downloading and installing FRP version ${FRP_VERSION}..."
    ARCH=$(uname -m)
    case "$ARCH" in
        "x86_64") FRP_ARCH="amd64" ;;
        "aarch64") FRP_ARCH="arm64" ;;
        "armv7l") FRP_ARCH="arm" ;;
        "i386") FRP_ARCH="386" ;;
        *) error_exit "Your CPU architecture (${ARCH}) is not supported." ;;
    esac

    FRP_FILE="frp_${FRP_VERSION}_linux_${FRP_ARCH}.tar.gz"
    FRP_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FRP_FILE}"

    if [ -d "${INSTALL_DIR}" ]; then
        echo "FRP directory already exists. Deleting and reinstalling..."
        sudo rm -rf "${INSTALL_DIR}" || error_exit "Failed to delete previous FRP directory."
    fi

    sudo mkdir -p "${INSTALL_DIR}" || error_exit "Failed to create directory ${INSTALL_DIR}."
    curl -L "${FRP_URL}" -o "/tmp/${FRP_FILE}" || error_exit "Failed to download FRP."
    sudo tar -xzf "/tmp/${FRP_FILE}" -C /tmp || error_exit "Failed to extract FRP file."
    sudo cp /tmp/frp_${FRP_VERSION}_linux_${FRP_ARCH}/frpc "${INSTALL_DIR}/" || error_exit "Failed to copy frpc."
    sudo cp /tmp/frp_${FRP_VERSION}_linux_${FRP_ARCH}/frps "${INSTALL_DIR}/" || error_exit "Failed to copy frps."
    sudo rm -rf "/tmp/${FRP_FILE}" "/tmp/frp_${FRP_VERSION}_linux_${FRP_ARCH}" || error_exit "Failed to clean up temporary files."

    echo "FRP installed successfully."
}

# Function to configure UFW firewall
configure_ufw() {
    echo "Configuring UFW firewall..."
    sudo ufw enable || sudo ufw --force enable
    sudo ufw allow ssh comment "Allow SSH"
    sudo ufw allow 7000/tcp comment "FRP Base TCP Port"
    sudo ufw allow 7001/udp comment "FRP Base UDP/QUIC Port"
    sudo ufw allow 7002/udp comment "FRP QUIC KCP Port (if used)"
    sudo ufw allow 80/tcp comment "FRP HTTP Vhost"
    sudo ufw allow 443/tcp comment "FRP HTTPS Vhost"
    
    # Example remote ports for various proxies (adjust as needed)
    sudo ufw allow 6000/tcp comment "FRP Remote Port for TCP Proxy"
    sudo ufw allow 6001/udp comment "FRP Remote Port for UDP Proxy"
    sudo ufw allow 6002/udp comment "FRP Remote Port for QUIC Proxy"
    sudo ufw allow 6003/tcp comment "FRP Remote Port for STCP Proxy"
    sudo ufw allow 6004/udp comment "FRP Remote Port for SUDP Proxy"
    sudo ufw allow 6005/udp comment "FRP Remote Port for XTCP Proxy"
    
    sudo ufw reload || error_exit "Failed to reload UFW."
    echo "UFW configured successfully."
}

# Function to configure FRP Server (frps)
configure_iran_server() {
    echo "Configuring FRP Server (frps) on the Iran server..."

    read -p "Please enter the public IP address of your Iran server: " IRAN_SERVER_IP
    if [[ ! "$IRAN_SERVER_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        error_exit "Invalid IP address. Please enter a valid IP."
    fi

    read -p "Please enter the Authentication Token for FRP (a strong, random string): " FRP_TOKEN
    if [ -z "$FRP_TOKEN" ]; then
        error_exit "Authentication token cannot be empty. Please enter a token."
    fi

    # Generate frps.ini
    cat <<EOL > "${INSTALL_DIR}/frps.ini"
[common]
bind_addr = 0.0.0.0
bind_port = 7000           # Default port for TCP
bind_udp_port = 7001       # Default port for UDP and QUIC
kcp_bind_port = 7002       # Default port for QUIC (if bind_udp_port is not sufficient)
vhost_http_port = 80       # Port for HTTP
vhost_https_port = 443     # Port for HTTPS
tcp_mux = true             # Enable TCP Multiplexing

authentication_method = token
token = ${FRP_TOKEN}

dashboard_addr = 0.0.0.0
dashboard_port = 7500
dashboard_user = admin
dashboard_pwd = PASSWORD_FRP_123 # Default password for dashboard (CHANGE THIS!)

log_file = /var/log/frps.log
log_level = info
log_max_days = 3
EOL

    echo "File ${INSTALL_DIR}/frps.ini created successfully."

    # Create systemd service file for frps
    sudo cp /dev/null /etc/systemd/system/frps.service
    cat <<EOL | sudo tee /etc/systemd/system/frps.service > /dev/null
[Unit]
Description = FRP Server (frps)
After = network.target

[Service]
Type = simple
ExecStart = ${INSTALL_DIR}/frps -c ${INSTALL_DIR}/frps.ini
Restart = on-failure

[Install]
WantedBy = multi-user.target
EOL

    sudo systemctl daemon-reload || error_exit "Failed to reload systemd daemon."
    sudo systemctl enable frps.service || error_exit "Failed to enable frps.service."
    sudo systemctl start frps.service || error_exit "Failed to start frps.service."
    echo "frps service installed and started successfully."
    echo "---------------------------------------------------"
    echo "Iran server (frps) configuration completed successfully."
    echo "FRP Dashboard is available on port 7500 with username 'admin' and password 'PASSWORD_FRP_123'."
    echo "It is highly recommended to change the dashboard password IMMEDIATELY!"
    echo "And use a stronger authentication token for FRP."
    echo "---------------------------------------------------"
}

# Function to configure FRP Client (frpc)
configure_foreign_server() {
    echo "Configuring FRP Client (frpc) on the foreign server..."

    read -p "Please enter the public IP address of your Iran server: " SERVER_ADDR
    if [[ ! "$SERVER_ADDR" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        error_exit "Invalid IP address. Please enter a valid IP."
    fi

    read -p "Please enter the Authentication Token you set on the Iran server: " FRP_TOKEN
    if [ -z "$FRP_TOKEN" ]; then
        error_exit "Authentication token cannot be empty. Please enter the token."
    fi

    read -p "Please enter your domain name (FQDN) (e.g., example.com): " CUSTOM_DOMAIN
    if [ -z "$CUSTOM_DOMAIN" ]; then
        error_exit "Domain name cannot be empty."
    fi

    # Generate frpc.ini
    cat <<EOL > "${INSTALL_DIR}/frpc.ini"
[common]
server_addr = ${SERVER_ADDR}
server_port = 7000           # Must be the same as bind_port in frps.ini
protocol = tcp               # Main connection protocol to the server (tcp, udp, quic)
tcp_mux = true               # Enable TCP Multiplexing

authentication_method = token
token = ${FRP_TOKEN}

log_file = /var/log/frpc.log
log_level = info
log_max_days = 3

# --- Sample Proxies ---
# You can enable or disable these proxies based on your needs.
# Each proxy must have a unique name (e.g., [ssh_proxy]).

# TCP Proxy Example (e.g., for SSH or RDP)
[tcp_proxy_example]
type = tcp
local_ip = 127.0.0.1
local_port = 22             # Local service port (e.g., SSH)
remote_port = 6000          # Port opened on the Iran server (for public access)
use_compression = true      # Data compression
# use_encryption = true     # Data encryption (optional)

# UDP Proxy Example (e.g., for DNS or UDP VPN)
[udp_proxy_example]
type = udp
local_ip = 127.0.0.1
local_port = 53             # Local service port (e.g., DNS)
remote_port = 6001          # Port opened on the Iran server
use_compression = true

# QUIC Proxy Example (for better performance on unstable networks)
[quic_proxy_example]
type = quic
local_ip = 127.0.0.1
local_port = 8080           # Local service port
remote_port = 6002          # Port opened on the Iran server
# Note: For full QUIC utilization, the 'protocol' in [common] should also be set to 'quic'.

# HTTP Proxy Example (for web servers)
[http_proxy_example]
type = http
local_ip = 127.0.0.1
local_port = 80             # Local HTTP web server port
custom_domains = ${CUSTOM_DOMAIN} # Your domain pointing to the Iran server via Cloudflare
# Or use subdomain:
# subdomain = myweb

# HTTPS Proxy Example (for secure web servers)
[https_proxy_example]
type = https
local_ip = 127.0.0.1
local_port = 443            # Local HTTPS web server port
custom_domains = ${CUSTOM_DOMAIN} # Your domain pointing to the Iran server via Cloudflare
# Or use subdomain:
# subdomain = mysecureweb

# STCP Proxy Example (Secret TCP - for secure and private tunnels)
[stcp_proxy_example]
type = stcp
local_ip = 127.0.0.1
local_port = 3389           # Local service port (e.g., RDP)
remote_port = 6003          # Port opened on the Iran server
sk = MY_STCP_SECRET_KEY_123 # A shared secret key (MUST CHANGE THIS!)
# To connect to this proxy, the client must use 'frpc visitor' with this 'sk'.

# SUDP Proxy Example (Secret UDP - for secure and private UDP tunnels)
[sudp_proxy_example]
type = sudp
local_ip = 127.0.0.1
local_port = 1194           # Local service port (e.g., OpenVPN UDP)
remote_port = 6004          # Port opened on the Iran server
sk = MY_SUDP_SECRET_KEY_456 # A shared secret key (MUST CHANGE THIS!)
# To connect to this proxy, the client must use 'frpc visitor' with this 'sk'.

# XTCP Proxy Example (P2P Connect - for direct client-to-client communication)
[xtcp_proxy_example]
type = xtcp
local_ip = 127.0.0.1
local_port = 5900           # Local service port (e.g., VNC)
remote_port = 6005          # Port opened on the Iran server
sk = MY_XTCP_SECRET_KEY_789 # A shared secret key (MUST CHANGE THIS!)
# To connect to this proxy, the client must use 'frpc visitor' with this 'sk'.
EOL

    echo "File ${INSTALL_DIR}/frpc.ini created successfully."

    # Create systemd service file for frpc
    sudo cp /dev/null /etc/systemd/system/frpc.service
    cat <<EOL | sudo tee /etc/systemd/system/frpc.service > /dev/null
[Unit]
Description = FRP Client (frpc)
After = network.target

[Service]
Type = simple
ExecStart = ${INSTALL_DIR}/frpc -c ${INSTALL_DIR}/frpc.ini
Restart = on-failure

[Install]
WantedBy = multi-user.target
EOL

    sudo systemctl daemon-reload || error_exit "Failed to reload systemd daemon."
    sudo systemctl enable frpc.service || error_exit "Failed to enable frpc.service."
    sudo systemctl start frpc.service || error_exit "Failed to start frpc.service."
    echo "frpc service installed and started successfully."
    echo "---------------------------------------------------"
    echo "Foreign server (frpc) configuration completed successfully."
    echo "---------------------------------------------------"
}

# Main script logic
clear
echo "---------------------------------------------------"
echo "           FRP Setup Script (Version 1.0)          "
echo "---------------------------------------------------"
echo "This script installs and configures FRP."
echo "You can choose to set up the Server (Iran) or the Client (Foreign)."
echo ""
echo "Options:"
echo "1. Install/Configure FRP Tunnel"
echo "2. Uninstall FRP"
echo "3. Exit"
read -p "Please enter your choice [1-3]: " main_choice

case "$main_choice" in
    1)
        clear
        echo "---------------------------------------------------"
        echo "           Install/Configure FRP Tunnel            "
        echo "---------------------------------------------------"
        echo "1. This is the IRAN Server (Public Entry)"
        echo "2. This is the FOREIGN Server (Service Host)"
        read -p "Please enter your choice [1-2]: " server_type_choice

        install_dependencies
        install_frp

        case "$server_type_choice" in
            1)
                configure_ufw
                configure_iran_server
                ;;
            2)
                configure_foreign_server
                ;;
            *)
                error_exit "Invalid choice. Please enter 1 or 2."
                ;;
        esac
        ;;
    2)
        echo "Uninstalling FRP..."
        sudo systemctl stop frps.service 2>/dev/null
        sudo systemctl disable frps.service 2>/dev/null
        sudo rm /etc/systemd/system/frps.service 2>/dev/null
        sudo systemctl stop frpc.service 2>/dev/null
        sudo systemctl disable frpc.service 2>/dev/null
        sudo rm /etc/systemd/system/frpc.service 2>/dev/null
        sudo rm -rf "${INSTALL_DIR}"
        sudo rm /var/log/frps.log 2>/dev/null
        sudo rm /var/log/frpc.log 2>/dev/null
        sudo systemctl daemon-reload
        echo "FRP uninstalled successfully."
        ;;
    3)
        echo "Exiting."
        exit 0
        ;;
    *)
        error_exit "Invalid choice. Please enter 1, 2, or 3."
        ;;
esac

echo "Script operation finished."
