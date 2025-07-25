#!/bin/bash

# Define FRP version to install
FRP_VERSION="0.59.0" # You can change this to a newer version if available

# Define FRP installation directory
INSTALL_DIR="/opt/frp"

# Function to display error messages
error_exit() {
    echo "خطا: $1" >&2
    exit 1
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to install dependencies
install_dependencies() {
    echo "در حال نصب پکیج های مورد نیاز..."
    sudo apt update || error_exit "آپدیت پکیج ها با خطا مواجه شد."
    sudo apt install -y curl unzip || error_exit "نصب curl و unzip با خطا مواجه شد."
}

# Function to download and install FRP
install_frp() {
    echo "در حال دانلود و نصب FRP نسخه ${FRP_VERSION}..."
    ARCH=$(uname -m)
    case "$ARCH" in
        "x86_64") FRP_ARCH="amd64" ;;
        "aarch64") FRP_ARCH="arm64" ;;
        "armv7l") FRP_ARCH="arm" ;;
        "i386") FRP_ARCH="386" ;;
        *) error_exit "معماری CPU شما (${ARCH}) پشتیبانی نمی شود." ;;
    esac

    FRP_FILE="frp_${FRP_VERSION}_linux_${FRP_ARCH}.tar.gz"
    FRP_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FRP_FILE}"

    if [ -d "${INSTALL_DIR}" ]; then
        echo "پوشه FRP از قبل وجود دارد. در حال حذف و نصب مجدد..."
        sudo rm -rf "${INSTALL_DIR}" || error_exit "خطا در حذف پوشه FRP قبلی."
    fi

    sudo mkdir -p "${INSTALL_DIR}" || error_exit "خطا در ساخت پوشه ${INSTALL_DIR}."
    curl -L "${FRP_URL}" -o "/tmp/${FRP_FILE}" || error_exit "خطا در دانلود FRP."
    sudo tar -xzf "/tmp/${FRP_FILE}" -C /tmp || error_exit "خطا در استخراج فایل FRP."
    sudo cp /tmp/frp_${FRP_VERSION}_linux_${FRP_ARCH}/frpc "${INSTALL_DIR}/" || error_exit "خطا در کپی frpc."
    sudo cp /tmp/frp_${FRP_VERSION}_linux_${FRP_ARCH}/frps "${INSTALL_DIR}/" || error_exit "خطا در کپی frps."
    sudo rm -rf "/tmp/${FRP_FILE}" "/tmp/frp_${FRP_VERSION}_linux_${FRP_ARCH}" || error_exit "خطا در پاکسازی فایل های موقت."

    echo "FRP با موفقیت نصب شد."
}

# Function to configure UFW firewall
configure_ufw() {
    echo "در حال تنظیم فایروال UFW..."
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
    
    sudo ufw reload || error_exit "خطا در بارگذاری مجدد UFW."
    echo "UFW با موفقیت تنظیم شد."
}

# Function to configure FRP Server (frps)
configure_iran_server() {
    echo "در حال پیکربندی سرور FRP (frps) در سرور ایران..."

    read -p "لطفاً IP عمومی سرور ایران خود را وارد کنید: " IRAN_SERVER_IP
    if [[ ! "$IRAN_SERVER_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        error_exit "آدرس IP نامعتبر است. لطفاً IP صحیح را وارد کنید."
    fi

    read -p "لطفاً توکن امنیتی (Authentication Token) برای FRP را وارد کنید (یک رشته قوی و تصادفی): " FRP_TOKEN
    if [ -z "$FRP_TOKEN" ]; then
        error_exit "توکن امنیتی نمی تواند خالی باشد. لطفاً یک توکن وارد کنید."
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

    echo "فایل ${INSTALL_DIR}/frps.ini با موفقیت ایجاد شد."

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

    sudo systemctl daemon-reload || error_exit "خطا در بارگذاری مجدد daemon systemd."
    sudo systemctl enable frps.service || error_exit "خطا در فعال سازی frps.service."
    sudo systemctl start frps.service || error_exit "خطا در راه اندازی frps.service."
    echo "سرویس frps با موفقیت نصب و راه اندازی شد."
    echo "---------------------------------------------------"
    echo "پیکربندی سرور ایران (frps) با موفقیت به پایان رسید."
    echo "داشبورد مدیریت FRP در پورت 7500 با یوزر 'admin' و پسورد 'PASSWORD_FRP_123' در دسترس است."
    echo "توصیه می شود پسورد داشبورد را بلافاخته تغییر دهید!"
    echo "و از یک توکن امنیتی قوی تر برای FRP استفاده کنید."
    echo "---------------------------------------------------"
}

# Function to configure FRP Client (frpc)
configure_foreign_server() {
    echo "در حال پیکربندی کلاینت FRP (frpc) در سرور خارجی..."

    read -p "لطفاً IP عمومی سرور ایران خود را وارد کنید: " SERVER_ADDR
    if [[ ! "$SERVER_ADDR" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        error_exit "آدرس IP نامعتبر است. لطفاً IP صحیح را وارد کنید."
    fi

    read -p "لطفاً توکن امنیتی (Authentication Token) که در سرور ایران تنظیم کردید را وارد کنید: " FRP_TOKEN
    if [ -z "$FRP_TOKEN" ]; then
        error_exit "توکن امنیتی نمی تواند خالی باشد. لطفاً توکن را وارد کنید."
    fi

    read -p "لطفاً نام دامنه (FQDN) خود را وارد کنید (مثال: example.com): " CUSTOM_DOMAIN
    if [ -z "$CUSTOM_DOMAIN" ]; then
        error_exit "نام دامنه نمی تواند خالی باشد."
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

    echo "فایل ${INSTALL_DIR}/frpc.ini با موفقیت ایجاد شد."

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

    sudo systemctl daemon-reload || error_exit "خطا در بارگذاری مجدد daemon systemd."
    sudo systemctl enable frpc.service || error_exit "خطا در فعال سازی frpc.service."
    sudo systemctl start frpc.service || error_exit "خطا در راه اندازی frpc.service."
    echo "سرویس frpc با موفقیت نصب و راه اندازی شد."
    echo "---------------------------------------------------"
    echo "پیکربندی سرور خارجی (frpc) با موفقیت به پایان رسید."
    echo "---------------------------------------------------"
}

# Main script logic
clear
echo "---------------------------------------------------"
echo "           FRP Setup Script (Version 1.0)          "
echo "---------------------------------------------------"
echo "این اسکریپت FRP را نصب و پیکربندی می کند."
echo "شما می توانید سرور (Iran) یا کلاینت (Foreign) را انتخاب کنید."
echo ""
echo "گزینه ها:"
echo "1. نصب/پیکربندی تونل FRP"
echo "2. حذف FRP"
echo "3. خروج"
read -p "لطفاً گزینه مورد نظر خود را وارد کنید [1-3]: " main_choice

case "$main_choice" in
    1)
        clear
        echo "---------------------------------------------------"
        echo "      نصب/پیکربندی تونل FRP      "
        echo "---------------------------------------------------"
        echo "1. این سرور ایران است (Public Entry)"
        echo "2. این سرور خارجی است (Service Host)"
        read -p "لطفاً گزینه مورد نظر خود را وارد کنید [1-2]: " server_type_choice

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
                error_exit "انتخاب نامعتبر. لطفاً 1 یا 2 را وارد کنید."
                ;;
        esac
        ;;
    2)
        echo "در حال حذف FRP..."
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
        echo "FRP با موفقیت حذف شد."
        ;;
    3)
        echo "خروج."
        exit 0
        ;;
    *)
        error_exit "انتخاب نامعتبر. لطفاً 1، 2 یا 3 را وارد کنید."
        ;;
esac

echo "پایان عملیات اسکریپت."
