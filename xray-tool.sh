#!/bin/bash
# =============================================================================
# Xray Management Tool (VLESS + Reality) - FINAL (fixed key parsing)
# =============================================================================

set -e

XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG_FILE="$XRAY_CONFIG_DIR/config.json"
XRAY_INSTALL_SCRIPT="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
METADATA_DIR="$XRAY_CONFIG_DIR/inbounds"
SCRIPT_PATH="/usr/local/bin/xray-tool"

# ----------------------------------------------
# Helper functions
# ----------------------------------------------
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "Please run as root (use sudo)."
        exit 1
    fi
}

restart_xray() {
    systemctl restart xray
    sleep 1
    if ! systemctl is-active --quiet xray; then
        echo "ERROR: Xray failed to start. Check config with: xray run -test -config $XRAY_CONFIG_FILE"
        exit 1
    fi
}

backup_config() {
    cp "$XRAY_CONFIG_FILE" "$XRAY_CONFIG_FILE.bak"
}

get_server_ip() {
    curl -4 -s --max-time 3 ipinfo.io/ip
}

# ----------------------------------------------
# Command: install
# ----------------------------------------------
cmd_install() {
    check_root
    echo "=== Installing Xray-core + BBR + dependencies ==="
    apt update
    apt install -y qrencode curl jq

    current_cong=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ "$current_cong" != "bbr" ]]; then
        echo "Enabling BBR..."
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
    fi

    bash -c "$(curl -4 -L $XRAY_INSTALL_SCRIPT)" @ install

    mkdir -p "$METADATA_DIR"
    cat << EOF > "$XRAY_CONFIG_FILE"
{
    "log": { "loglevel": "warning" },
    "inbounds": [],
    "outbounds": [
        { "protocol": "freedom", "tag": "direct" },
        { "protocol": "blackhole", "tag": "block" }
    ],
    "policy": { "levels": { "0": { "handshake": 3, "connIdle": 180 } } }
}
EOF

    restart_xray
    systemctl enable xray
    cp "$0" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    echo "Installation complete. Use '$SCRIPT_PATH inbounds add' to create first inbound."
}

# ----------------------------------------------
# Command: update
# ----------------------------------------------
cmd_update() {
    check_root
    echo "Updating Xray-core..."
    bash -c "$(curl -4 -L $XRAY_INSTALL_SCRIPT)" @ install
    restart_xray
    echo "Update finished."
}

# ----------------------------------------------
# Command: inbounds list
# ----------------------------------------------
cmd_inbounds_list() {
    if [ ! -f "$XRAY_CONFIG_FILE" ]; then
        echo "Xray config not found. Run 'install' first."
        return 1
    fi
    count=$(jq '.inbounds | length' "$XRAY_CONFIG_FILE")
    if [ "$count" -eq 0 ]; then
        echo "No inbounds configured."
        return 0
    fi
    echo "=== Inbounds ==="
    jq -r '.inbounds[] | "Port: \(.port) | Type: \(.streamSettings.network) | Target: \(.streamSettings.realitySettings.target) | Clients: \(.settings.clients | length)"' "$XRAY_CONFIG_FILE"
}

# ----------------------------------------------
# Command: inbounds add
# ----------------------------------------------
cmd_inbounds_add() {
    check_root
    echo "=== Add new inbound ==="
    read -p "Port (default: 443): " port
    port=${port:-443}
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        echo "Invalid port."
        return 1
    fi
    if jq --argjson p "$port" '.inbounds[] | select(.port == $p)' "$XRAY_CONFIG_FILE" | grep -q .; then
        echo "Inbound on port $port already exists."
        return 1
    fi

    echo "Select transport:"
    echo "1) TCP + Reality (flow: xtls-rprx-vision)"
    echo "2) gRPC + Reality (flow: empty)"
    echo "3) XHTTP + Reality (flow: empty)"
    read -p "Choice [1-3]: " transport_choice

    case $transport_choice in
        1) transport="tcp"; flow="xtls-rprx-vision";;
        2) transport="grpc"; flow="";;
        3) transport="xhttp"; flow="";;
        *) echo "Invalid choice"; return 1;;
    esac

    read -p "Target domain (default: dl.google.com:443): " target
    target=${target:-dl.google.com:443}
    sni=$(echo "$target" | cut -d: -f1)

    echo "Select client fingerprint (TLS imitation):"
    echo "1) firefox (default)"
    echo "2) chrome"
    echo "3) safari"
    echo "4) edge"
    echo "5) random"
    echo "6) randomized"
    read -p "Choice [1-6] (default: 1): " fp_choice
    case $fp_choice in
        2) fingerprint="chrome";;
        3) fingerprint="safari";;
        4) fingerprint="edge";;
        5) fingerprint="random";;
        6) fingerprint="randomized";;
        *) fingerprint="firefox";;
    esac

    grpc_service=""
    xhttp_path=""
    if [ "$transport" = "grpc" ]; then
        read -p "gRPC serviceName (default: empty, press Enter): " grpc_service
    elif [ "$transport" = "xhttp" ]; then
        read -p "XHTTP path (default: /): " xhttp_path
        xhttp_path=${xhttp_path:-/}
    fi

    # --- FIXED KEY PARSING ---
    keypair=$(xray x25519)
    privateKey=$(echo "$keypair" | grep -m1 'PrivateKey:' | awk '{print $2}')
    publicKey=$(echo "$keypair" | grep -m1 'Password (PublicKey):' | awk '{print $3}')
    if [ -z "$publicKey" ]; then
        # fallback if the above fails
        publicKey=$(echo "$keypair" | grep -m1 'PublicKey:' | awk '{print $2}')
    fi
    if [ -z "$privateKey" ] || [ -z "$publicKey" ]; then
        echo "ERROR: Failed to extract keys. Raw output:"
        echo "$keypair"
        return 1
    fi
    # -------------------------

    shortid=$(openssl rand -hex 8)

    # Build streamSettings JSON
    stream_json=$(jq -n \
        --arg network "$transport" \
        --arg security "reality" \
        --arg target "$target" \
        --arg sni "$sni" \
        --arg privKey "$privateKey" \
        --arg shortid "$shortid" \
        '{
            "network": $network,
            "security": $security,
            "realitySettings": {
                "show": false,
                "target": $target,
                "serverNames": [$sni],
                "privateKey": $privKey,
                "shortIds": [$shortid]
            }
        }')

    if [ "$transport" = "grpc" ]; then
        stream_json=$(echo "$stream_json" | jq --arg svc "$grpc_service" '.grpcSettings = {"serviceName": $svc, "multiMode": false}')
    elif [ "$transport" = "xhttp" ]; then
        stream_json=$(echo "$stream_json" | jq --arg path "$xhttp_path" '.xhttpSettings = {"path": $path}')
    fi

    # Build inbound with empty clients array
    inbound=$(jq -n \
        --arg listen "0.0.0.0" \
        --argjson port "$port" \
        --arg protocol "vless" \
        --arg flow "$flow" \
        --argjson stream "$stream_json" \
        '{
            "listen": $listen,
            "port": $port,
            "protocol": $protocol,
            "settings": {
                "clients": [],
                "decryption": "none"
            },
            "streamSettings": $stream,
            "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}
        }')

    backup_config
    jq --argjson inbound "$inbound" '.inbounds += [$inbound]' "$XRAY_CONFIG_FILE" > "$XRAY_CONFIG_FILE.tmp"
    mv "$XRAY_CONFIG_FILE.tmp" "$XRAY_CONFIG_FILE"
    restart_xray

    mkdir -p "$METADATA_DIR"
    cat > "$METADATA_DIR/${port}.info" << EOF
port=$port
type=$transport
target=$target
sni=$sni
publicKey=$publicKey
shortId=$shortid
grpcServiceName=$grpc_service
xhttpPath=$xhttp_path
flow=$flow
fingerprint=$fingerprint
EOF

    echo "Inbound added on port $port (no default client). Use 'clients add' to create users."
}

# ----------------------------------------------
# Command: inbounds rm
# ----------------------------------------------
cmd_inbounds_rm() {
    check_root
    count=$(jq '.inbounds | length' "$XRAY_CONFIG_FILE")
    if [ "$count" -eq 0 ]; then
        echo "No inbounds to remove."
        return 0
    fi
    echo "Select inbound to remove:"
    jq -r '.inbounds | to_entries[] | "\(.key+1). Port \(.value.port) | \(.value.streamSettings.network)"' "$XRAY_CONFIG_FILE"
    read -p "Number: " idx
    if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -lt 1 ] || [ "$idx" -gt "$count" ]; then
        echo "Invalid number."
        return 1
    fi
    port=$(jq -r ".inbounds[$((idx-1))].port" "$XRAY_CONFIG_FILE")
    backup_config
    jq "del(.inbounds[$((idx-1))])" "$XRAY_CONFIG_FILE" > "$XRAY_CONFIG_FILE.tmp"
    mv "$XRAY_CONFIG_FILE.tmp" "$XRAY_CONFIG_FILE"
    rm -f "$METADATA_DIR/${port}.info"
    restart_xray
    echo "Inbound on port $port removed."
}

# ----------------------------------------------
# Command: clients list
# ----------------------------------------------
cmd_clients_list() {
    if [ ! -f "$XRAY_CONFIG_FILE" ]; then
        echo "Xray config not found."
        return 1
    fi
    echo "=== All clients ==="
    jq -r '.inbounds[] | .port as $port | .settings.clients[] | "\(.email) (inbound port \($port))"' "$XRAY_CONFIG_FILE"
    echo "Total: $(jq '[.inbounds[].settings.clients[]] | length' "$XRAY_CONFIG_FILE") clients"
}

# ----------------------------------------------
# Command: clients add
# ----------------------------------------------
cmd_clients_add() {
    check_root
    count=$(jq '.inbounds | length' "$XRAY_CONFIG_FILE")
    if [ "$count" -eq 0 ]; then
        echo "No inbounds. Create one with 'inbounds add' first."
        return 1
    fi
    echo "Select inbound to add client:"
    jq -r '.inbounds | to_entries[] | "\(.key+1). Port \(.value.port) | \(.value.streamSettings.network)"' "$XRAY_CONFIG_FILE"
    read -p "Number: " idx
    if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -lt 1 ] || [ "$idx" -gt "$count" ]; then
        echo "Invalid number."
        return 1
    fi
    read -p "Client email: " email
    if [[ -z "$email" ]]; then
        echo "Email required."
        return 1
    fi
    if jq --arg email "$email" '.inbounds[].settings.clients[] | select(.email == $email)' "$XRAY_CONFIG_FILE" | grep -q .; then
        echo "Client with email '$email' already exists."
        return 1
    fi
    new_uuid=$(xray uuid)
    port=$(jq -r ".inbounds[$((idx-1))].port" "$XRAY_CONFIG_FILE")
    info_file="$METADATA_DIR/${port}.info"
    if [ ! -f "$info_file" ]; then
        echo "Metadata missing for port $port. Inbound may be corrupted."
        return 1
    fi
    source "$info_file"
    backup_config
    jq --argjson idx "$((idx-1))" --arg email "$email" --arg uuid "$new_uuid" --arg flow "$flow" \
        '.inbounds[$idx].settings.clients += [{"email": $email, "id": $uuid, "flow": $flow}]' \
        "$XRAY_CONFIG_FILE" > "$XRAY_CONFIG_FILE.tmp"
    mv "$XRAY_CONFIG_FILE.tmp" "$XRAY_CONFIG_FILE"
    restart_xray
    echo "Client '$email' added to inbound port $port."
}

# ----------------------------------------------
# Command: clients rm
# ----------------------------------------------
cmd_clients_rm() {
    check_root
    clients=$(jq -r '.inbounds[] | .port as $port | .settings.clients[] | "\($port):\(.email)"' "$XRAY_CONFIG_FILE")
    if [ -z "$clients" ]; then
        echo "No clients found."
        return 1
    fi
    echo "Select client to remove:"
    IFS=$'\n'
    idx=1
    for line in $clients; do
        echo "$idx. $line"
        idx=$((idx+1))
    done
    unset IFS
    read -p "Number: " num
    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "$((idx-1))" ]; then
        echo "Invalid number."
        return 1
    fi
    target_line=$(echo "$clients" | sed -n "${num}p")
    port=$(echo "$target_line" | cut -d: -f1)
    email=$(echo "$target_line" | cut -d: -f2)
    backup_config
    inbound_idx=$(jq --argjson port "$port" '.inbounds | map(.port == $port) | index(true)' "$XRAY_CONFIG_FILE")
    if [ "$inbound_idx" = "null" ]; then
        echo "Error: inbound not found."
        return 1
    fi
    jq --argjson idx "$inbound_idx" --arg email "$email" \
        '.inbounds[$idx].settings.clients |= map(select(.email != $email))' \
        "$XRAY_CONFIG_FILE" > "$XRAY_CONFIG_FILE.tmp"
    mv "$XRAY_CONFIG_FILE.tmp" "$XRAY_CONFIG_FILE"
    restart_xray
    echo "Client '$email' removed."
}

# ----------------------------------------------
# Command: clients qr
# ----------------------------------------------
cmd_clients_qr() {
    if [ ! -f "$XRAY_CONFIG_FILE" ]; then
        echo "Xray config not found."
        return 1
    fi
    clients=$(jq -r '.inbounds[] | .port as $port | .settings.clients[] | "\($port):\(.email):\(.id)"' "$XRAY_CONFIG_FILE")
    if [ -z "$clients" ]; then
        echo "No clients found."
        return 1
    fi
    echo "Select client:"
    IFS=$'\n'
    idx=1
    for line in $clients; do
        port=$(echo "$line" | cut -d: -f1)
        email=$(echo "$line" | cut -d: -f2)
        echo "$idx. $email (port $port)"
        idx=$((idx+1))
    done
    unset IFS
    read -p "Number: " num
    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "$((idx-1))" ]; then
        echo "Invalid number."
        return 1
    fi
    target_line=$(echo "$clients" | sed -n "${num}p")
    port=$(echo "$target_line" | cut -d: -f1)
    email=$(echo "$target_line" | cut -d: -f2)
    uuid=$(echo "$target_line" | cut -d: -f3)

    info_file="$METADATA_DIR/${port}.info"
    if [ ! -f "$info_file" ]; then
        echo "Metadata missing for port $port. Recreate inbound."
        return 1
    fi
    source "$info_file"

    client_flow=$(jq --argjson port "$port" --arg email "$email" -r \
        '.inbounds[] | select(.port == $port) | .settings.clients[] | select(.email == $email) | .flow' "$XRAY_CONFIG_FILE")
    client_flow=${client_flow:-$flow}

    server_ip=$(get_server_ip)
    if [ -z "$server_ip" ]; then
        echo "Failed to detect IPv4. Enter manually:"
        read -p "Server IP: " server_ip
    fi

    case $type in
        tcp)
            link="vless://${uuid}@${server_ip}:${port}?security=reality&sni=${sni}&fp=${fingerprint}&pbk=${publicKey}&sid=${shortId}&type=tcp&flow=${client_flow}&encryption=none#${email}"
            ;;
        grpc)
            link="vless://${uuid}@${server_ip}:${port}?security=reality&sni=${sni}&fp=${fingerprint}&pbk=${publicKey}&sid=${shortId}&type=grpc&serviceName=${grpcServiceName}&encryption=none#${email}"
            ;;
        xhttp)
            link="vless://${uuid}@${server_ip}:${port}?security=reality&sni=${sni}&fp=${fingerprint}&pbk=${publicKey}&sid=${shortId}&type=xhttp&path=${xhttpPath}&encryption=none#${email}"
            ;;
        *)
            echo "Unknown transport type: $type"
            return 1
    esac

    echo ""
    echo "=== Connection link for $email ==="
    echo "$link"
    echo ""
    echo "=== QR Code ==="
    echo "$link" | qrencode -t ansiutf8
    echo ""
}

# ----------------------------------------------
# Help
# ----------------------------------------------
cmd_help() {
    cat << EOF
Xray Management Tool (VLESS + Reality)

Usage: $0 <command> [subcommand]

Commands:
  install                    Install Xray-core, BBR, dependencies
  update                     Update Xray binary
  inbounds                   List all inbounds
  inbounds add               Add new inbound (interactive)
  inbounds rm                Remove an inbound
  clients                    List all clients
  clients add                Add new client
  clients rm                 Remove a client
  clients qr                 Show connection link + QR for a client
EOF
}

# ----------------------------------------------
# Main dispatcher
# ----------------------------------------------
if [ $# -eq 0 ]; then
    cmd_help
    exit 0
fi

case "$1" in
    install)                cmd_install ;;
    update)                 cmd_update ;;
    inbounds)               if [ "$2" = "add" ]; then cmd_inbounds_add; elif [ "$2" = "rm" ]; then cmd_inbounds_rm; else cmd_inbounds_list; fi ;;
    clients)                if [ "$2" = "add" ]; then cmd_clients_add; elif [ "$2" = "rm" ]; then cmd_clients_rm; elif [ "$2" = "qr" ]; then cmd_clients_qr; else cmd_clients_list; fi ;;
    help|--help|-h)         cmd_help ;;
    *)                      echo "Unknown command: $1"; cmd_help; exit 1 ;;
esac

exit 0