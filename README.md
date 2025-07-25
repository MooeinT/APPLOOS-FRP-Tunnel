# APPLOOS FRP TUNNEL SCRIPT

A script to easily install, manage, and optimize FRP (Fast Reverse Proxy) tunnels between two servers.

Developed By: **@AliTabari**

---

## Usage

To run the script, simply use one of the following commands on your server:

### Using wget
```bash
wget -O - [https://raw.githubusercontent.com/MooeinT/APPLOOS-FRP-Tunnel/main/setup_frp.sh](https://raw.githubusercontent.com/YourUsername/APPLOOS-FRP-Tunnel/main/setup_frp.sh) | sudo bash
Using curl
Bash

curl -sL [https://raw.githubusercontent.com/MooeinT/APPLOOS-FRP-Tunnel/main/setup_frp.sh](https://raw.githubusercontent.com/YourUsername/APPLOOS-FRP-Tunnel/main/setup_frp.sh) | sudo bash
Features
Menu-driven and easy to use.

Automated setup for both frps (server) and frpc (client).

Interactive prompts for IPs and Ports.

Support for both TCP and QUIC transport protocols.

Automatic systemd service creation for persistence.

Built-in network optimization tools (BBR, Cubic).

Full uninstaller.
