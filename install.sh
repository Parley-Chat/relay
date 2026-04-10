#!/usr/bin/env bash
set -e

MIRROR="${MIRROR_BASE_URL:-https://github.com/Parley-Chat/relay/releases/latest/download}"
DEFAULT_INTERNAL_PORT=7861
DEFAULT_INSTALL_DIR="/opt/parley-relay"

get_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "x64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) echo "Unsupported architecture: $(uname -m)"; exit 1 ;;
    esac
}

ask() {
    local prompt="$1" default="$2" val
    [ -n "$default" ] && prompt="$prompt [$default]"
    read -rp "$prompt: " val
    echo "${val:-$default}"
}

is_ip() {
    python3 -c "import ipaddress,sys; ipaddress.ip_address(sys.argv[1])" "$1" 2>/dev/null
}

fetch() {
    local url="$1" dest="$2"
    echo "  Downloading $(basename "$dest")..."
    if command -v wget &>/dev/null; then
        wget --progress=bar -O "$dest" "$url" 2>&1 | tail -1 || { echo "  Download failed: $url"; exit 1; }
    elif command -v curl &>/dev/null; then
        curl -fL --progress-bar "$url" -o "$dest" || { echo "  Download failed: $url"; exit 1; }
    else
        echo "  Neither wget nor curl found. Please install one of them."; exit 1
    fi
}

get_or_copy() {
    local url="$1" dest="$2" local_src="$3"
    if [ -f "$local_src" ]; then
        cp "$local_src" "$dest"
    else
        fetch "$url" "$dest"
    fi
}

install_package() {
    if command -v apt-get &>/dev/null; then
        apt-get update -qq; apt-get install -y "$1" >/dev/null 2>&1
    elif command -v dnf &>/dev/null; then
        dnf install -y "$1" >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y "$1" >/dev/null 2>&1
    elif command -v pacman &>/dev/null; then
        pacman -S --noconfirm "$1" >/dev/null 2>&1
    else
        echo "  Cannot detect package manager. Install $1 manually then re-run."; exit 1
    fi
}

ensure_nginx() {
    { command -v nginx &>/dev/null || [ -f /usr/sbin/nginx ]; } && return 0
    echo "  nginx not found, installing..."; install_package nginx
}

ensure_certbot() {
    command -v certbot &>/dev/null && return 0
    echo "  certbot not found, installing..."; install_package certbot
}

setup_renewal_cron() {
    local cron_job='0 0,12 * * * /usr/bin/certbot renew --quiet --pre-hook "systemctl stop nginx 2>/dev/null || true" --post-hook "systemctl start nginx 2>/dev/null || true" --deploy-hook "systemctl restart parley-relay-nginx"'
    local existing; existing=$(crontab -l 2>/dev/null || true)
    echo "$existing" | grep -q "certbot renew" && return 0
    { echo "$existing"; echo "$cron_job"; } | crontab -
}

gen_self_signed() {
    local cert="$1" key="$2" domain="$3" san
    is_ip "$domain" &>/dev/null && san="IP:$domain" || san="DNS:$domain"
    local cfg; cfg=$(mktemp)
    printf '[req]\ndistinguished_name=req_dn\nx509_extensions=san_ext\nprompt=no\n[req_dn]\nCN=%s\n[san_ext]\nsubjectAltName=%s\n' "$domain" "$san" > "$cfg"
    openssl req -x509 -newkey rsa:2048 -keyout "$key" -out "$cert" -days 3650 -nodes -config "$cfg" 2>/dev/null
    rm -f "$cfg"
}

save_version() {
    local install_dir="$1"
    local ver
    if command -v wget &>/dev/null; then
        ver=$(wget -qO- "$MIRROR/version.txt" 2>/dev/null || true)
    else
        ver=$(curl -fsSL "$MIRROR/version.txt" 2>/dev/null || true)
    fi
    [ -n "$ver" ] && echo "$ver" > "$install_dir/.version"
}

write_auto_update_script() {
    local install_dir="$1" arch="$2"
    local script="$install_dir/auto-update.sh"
    cat > "$script" <<AUTOUPDATE
#!/bin/bash
set -e
MIRROR="$MIRROR"
ARCH="$arch"
INSTALL_DIR="$install_dir"
VERSION_FILE="\$INSTALL_DIR/.version"
if command -v wget &>/dev/null; then
    REMOTE_VERSION=\$(wget -qO- "\$MIRROR/version.txt" 2>/dev/null || true)
elif command -v curl &>/dev/null; then
    REMOTE_VERSION=\$(curl -fsSL "\$MIRROR/version.txt" 2>/dev/null || true)
else
    echo "Neither wget nor curl found"; exit 1
fi
LOCAL_VERSION=\$(cat "\$VERSION_FILE" 2>/dev/null || true)
if [ -z "\$REMOTE_VERSION" ] || [ "\$LOCAL_VERSION" = "\$REMOTE_VERSION" ]; then
    exit 0
fi
echo "Updating from \$LOCAL_VERSION to \$REMOTE_VERSION"
systemctl stop parley-relay
if command -v wget &>/dev/null; then
    wget -q -O "\$INSTALL_DIR/relay.new" "\$MIRROR/relay-linux-\$ARCH"
else
    curl -fsSL "\$MIRROR/relay-linux-\$ARCH" -o "\$INSTALL_DIR/relay.new"
fi
chmod +x "\$INSTALL_DIR/relay.new"
mv "\$INSTALL_DIR/relay.new" "\$INSTALL_DIR/relay"
echo "\$REMOTE_VERSION" > "\$VERSION_FILE"
systemctl start parley-relay
AUTOUPDATE
    chmod +x "$script"
}

ask_auto_update_schedule() {
    echo ""; echo "Auto-update schedule:"
    echo "[1] Every 5 minutes"
    echo "[2] Every hour"
    echo "[3] Daily at 3 AM"
    echo "[4] Daily at 4 AM"
    echo "[5] Custom (enter cron expression)"; echo ""
    read -rp "> " sched_choice
    case "$sched_choice" in
        1) AUTO_UPDATE_EXPR="*/5 * * * *";  AUTO_UPDATE_LABEL="every 5 minutes" ;;
        2) AUTO_UPDATE_EXPR="0 * * * *";    AUTO_UPDATE_LABEL="every hour" ;;
        4) AUTO_UPDATE_EXPR="0 4 * * *";    AUTO_UPDATE_LABEL="daily at 4 AM" ;;
        5)
            AUTO_UPDATE_EXPR=$(ask "Cron expression (e.g. '0 2 * * *' for daily at 2 AM)")
            AUTO_UPDATE_LABEL="on schedule '$AUTO_UPDATE_EXPR'"
            ;;
        *) AUTO_UPDATE_EXPR="0 3 * * *";    AUTO_UPDATE_LABEL="daily at 3 AM" ;;
    esac
}

setup_auto_update_cron() {
    local script="$1" expr="$2"
    local cron_job="$expr $script >> /var/log/parley-relay-update.log 2>&1"
    local existing; existing=$(crontab -l 2>/dev/null || true)
    echo "$existing" | grep -qF "$script" && return 0
    { echo "$existing"; echo "$cron_job"; } | crontab -
}

remove_auto_update_cron() {
    local install_dir="$1"
    local script="$install_dir/auto-update.sh"
    local existing; existing=$(crontab -l 2>/dev/null || true)
    echo "$existing" | grep -vF "$script" | crontab - 2>/dev/null || true
}

CERT_FILE="" KEY_FILE="" SSL_TYPE=""

setup_ssl() {
    local domain="$1" install_dir="$2"
    if is_ip "$domain" &>/dev/null; then
        echo "  IP address detected - using self-signed certificate."
        CERT_FILE="$install_dir/certs/cert.pem"; KEY_FILE="$install_dir/certs/key.pem"
        gen_self_signed "$CERT_FILE" "$KEY_FILE" "$domain"; SSL_TYPE="self-signed"; return
    fi
    echo ""; echo "SSL Certificate:"
    echo "[1] Self-signed (works everywhere, browser warning on first visit)"
    echo "[2] Let's Encrypt - HTTP verification (port 80 must be open, auto-renews)"
    echo "[3] Let's Encrypt - DNS verification (works behind firewall)"
    echo "[4] Use existing certificates (provide paths)"; echo ""
    read -rp "> " ssl_choice
    case "$ssl_choice" in
        2)
            local email; email=$(ask "Email for Let's Encrypt notifications")
            ensure_certbot
            certbot certonly --standalone -d "$domain" --non-interactive --agree-tos -m "$email"
            setup_renewal_cron
            CERT_FILE="/etc/letsencrypt/live/$domain/fullchain.pem"
            KEY_FILE="/etc/letsencrypt/live/$domain/privkey.pem"
            SSL_TYPE="letsencrypt-http"
            ;;
        3)
            local email; email=$(ask "Email for Let's Encrypt notifications")
            ensure_certbot
            echo ""; echo "  certbot will now ask you to add a DNS TXT record to your domain."
            echo "  Follow the instructions on screen and press Enter when the record is added."; echo ""
            certbot certonly --manual --preferred-challenges dns -d "$domain" --agree-tos -m "$email"
            CERT_FILE="/etc/letsencrypt/live/$domain/fullchain.pem"
            KEY_FILE="/etc/letsencrypt/live/$domain/privkey.pem"
            SSL_TYPE="letsencrypt-dns"
            ;;
        4)
            CERT_FILE=$(ask "Path to certificate file (PEM)")
            KEY_FILE=$(ask "Path to private key file (PEM)")
            SSL_TYPE="custom"
            ;;
        *)
            CERT_FILE="$install_dir/certs/cert.pem"; KEY_FILE="$install_dir/certs/key.pem"
            gen_self_signed "$CERT_FILE" "$KEY_FILE" "$domain"; SSL_TYPE="self-signed"
            ;;
    esac
}

write_nginx_conf() {
    local conf="$1" ext_port="$2" domain="$3" cert="$4" key="$5" relay_host="$6" int_port="$7"
    cat > "$conf" <<NGINXEOF
events {
    worker_connections 1024;
}

http {
    map \$http_host \$browser_authority {
        default \$http_host;
        ""      \$host;
    }
    server {
        listen $ext_port ssl http2;
        server_name $domain;

        ssl_certificate $cert;
        ssl_certificate_key $key;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers HIGH:!aNULL:!MD5;

        error_page 497 @handle_plain_http;
        location @handle_plain_http {
            return 301 https://\$host:$ext_port\$request_uri;
        }

        location / {
            proxy_pass http://$relay_host:$int_port;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "keep-alive";
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$remote_addr;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_cache off;
            proxy_buffering off;
            proxy_read_timeout 24h;
            proxy_send_timeout 24h;
            client_max_body_size 64M;
            proxy_redirect ~^https?://[^/]+(.*)$ \$scheme://\$browser_authority\$1;
        }
    }
}
NGINXEOF
}

write_relay_config() {
    local path="$1" uri_prefix="$2" host="$3" port="$4" backend="$5" threads="$6"
    local up_enabled="$7" up_url="$8" fe_mode="$9" fe_dir="${10}" fe_url="${11}"
    cat > "$path" <<TOMLEOF
version=1

uri_prefix="$uri_prefix"

[server]
    host="$host"
    port=$port
    threads=$threads
    max_content_length=67108864

[backend]
    url="$backend"

[upstream_proxy]
    enabled=$up_enabled
    url="$up_url"

[frontend]
    mode="$fe_mode"
    directory="$fe_dir"
    url="$fe_url"

[[paths]]
    prefix="/api/v1"
    action="proxy"

[[paths]]
    prefix="/pfp"
    action="proxy"

[[paths]]
    prefix="/attachment"
    action="proxy"

[[paths]]
    prefix="/health"
    action="proxy"
TOMLEOF
}

write_service() {
    cat > "/etc/systemd/system/$1.service" <<SVCEOF
[Unit]
Description=$2
After=network.target

[Service]
Type=simple
WorkingDirectory=$3
ExecStart=$4
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF
}

do_install() {
    local arch; arch=$(get_arch)
    local script_dir; script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    echo ""
    local domain; domain=$(ask "Domain or IP address")
    [ -z "$domain" ] && { echo "Domain/IP is required."; exit 1; }

    local uri_prefix; uri_prefix=$(python3 -c "import random,string; print(''.join(random.choices(string.ascii_lowercase+string.digits,k=20)))")
    uri_prefix=$(ask "URI path prefix (must match Sova's uri_prefix)" "$uri_prefix")

    local backend_url; backend_url=$(ask "Sova backend URL" "http://127.0.0.1:42836")
    local install_dir; install_dir=$(ask "Install directory" "$DEFAULT_INSTALL_DIR")
    local threads; threads=$(ask "Threads" "16")

    local use_nginx; use_nginx=$(ask "Use built-in nginx reverse proxy? [Y/n]" "y")
    local relay_host int_port ext_port
    if [[ "${use_nginx,,}" != "n" ]]; then
        ext_port=$(ask "nginx HTTPS port" "443")
        int_port=$(ask "Relay internal port" "$DEFAULT_INTERNAL_PORT")
        relay_host=$(ask "Relay bind host" "127.0.0.1")
    else
        ext_port=$(ask "Relay port" "$DEFAULT_INTERNAL_PORT")
        relay_host=$(ask "Relay bind host" "0.0.0.0")
        int_port=$ext_port
    fi

    local up_enabled="false" up_url=""
    local use_up; use_up=$(ask "Use upstream HTTP/SOCKS5 proxy? [y/N]" "n")
    if [[ "${use_up,,}" == "y" ]]; then
        up_url=$(ask "Proxy URL (e.g. socks5://user:pass@host:1080 or http://proxy:3128)")
        up_enabled="true"
    fi

    echo ""; echo "Frontend mode:"
    echo "[1] serve    - serve static files from a local directory"
    echo "[2] forward  - forward requests to a separate frontend URL"
    echo "[3] disabled - return 404 for non-API routes"
    echo ""; read -rp "> " fe_choice
    local fe_mode fe_dir="" fe_url=""
    case "$fe_choice" in
        2) fe_mode="forward"; fe_url=$(ask "Frontend URL") ;;
        3) fe_mode="disabled" ;;
        *) fe_mode="serve"; fe_dir=$(ask "Frontend directory" "$install_dir/mura") ;;
    esac

    local auto_update; auto_update=$(ask "Enable automatic updates? [y/N]" "n")

    echo ""; echo "Installing to $install_dir..."; echo ""
    mkdir -p "$install_dir" "$install_dir/certs"

    if [[ "${use_nginx,,}" != "n" ]]; then
        echo "  Setting up SSL..."
        setup_ssl "$domain" "$install_dir"
    fi

    echo "  Fetching relay binary..."
    get_or_copy "$MIRROR/relay-linux-$arch" "$install_dir/relay" "$script_dir/relay-linux-$arch"
    chmod +x "$install_dir/relay"

    echo "  Writing config..."
    write_relay_config "$install_dir/config.toml" "$uri_prefix" "$relay_host" "$int_port" "$backend_url" "$threads" "$up_enabled" "$up_url" "$fe_mode" "$fe_dir" "$fe_url"

    echo "  Writing systemd service..."
    write_service "parley-relay" "Parley Chat Relay" "$install_dir" "$install_dir/relay"

    if [[ "${use_nginx,,}" != "n" ]]; then
        echo "  Setting up nginx..."
        ensure_nginx
        write_nginx_conf "$install_dir/nginx.conf" "$ext_port" "$domain" "$CERT_FILE" "$KEY_FILE" "$relay_host" "$int_port"
        write_service "parley-relay-nginx" "Parley Chat Relay nginx" "$install_dir" "/usr/sbin/nginx -c $install_dir/nginx.conf -g 'daemon off;'"
    fi

    save_version "$install_dir"

    AUTO_UPDATE_EXPR="0 3 * * *"
    AUTO_UPDATE_LABEL="daily at 3 AM"
    if [[ "${auto_update,,}" == "y" ]]; then
        echo "  Setting up auto-update..."
        ask_auto_update_schedule
        write_auto_update_script "$install_dir" "$arch"
        setup_auto_update_cron "$install_dir/auto-update.sh" "$AUTO_UPDATE_EXPR"
    fi

    echo "  Starting services..."
    systemctl daemon-reload
    systemctl enable parley-relay && systemctl start parley-relay
    if [[ "${use_nginx,,}" != "n" ]]; then
        systemctl enable parley-relay-nginx && systemctl start parley-relay-nginx
    fi

    echo ""
    if [[ "${use_nginx,,}" != "n" ]]; then
        echo "Parley Chat Relay is running at https://$domain:$ext_port/$uri_prefix/"
        [ "$SSL_TYPE" = "self-signed" ] && echo "Your browser will show a certificate warning - click Advanced -> Proceed to continue."
        [ "$SSL_TYPE" = "letsencrypt-dns" ] && echo "Note: DNS-verified certificates must be renewed manually every 90 days."
    else
        echo "Parley Chat Relay is running on $relay_host:$int_port/"
        echo "Point your external reverse proxy to this address."
        echo "Make sure your proxy sets X-Forwarded-Proto and X-Real-IP headers."
    fi
    [[ "${auto_update,,}" == "y" ]] && echo "Auto-update is enabled and will run $AUTO_UPDATE_LABEL."
}

do_uninstall() {
    echo ""
    local install_dir; install_dir=$(ask "Install directory" "$DEFAULT_INSTALL_DIR")
    [ ! -f "$install_dir/relay" ] && { echo "No installation found at $install_dir."; exit 1; }
    local confirm; confirm=$(ask "This will permanently remove $install_dir and all its contents. Type 'yes' to confirm")
    [ "$confirm" != "yes" ] && { echo "Cancelled."; exit 0; }
    echo ""; echo "Uninstalling Parley Chat Relay..."; echo ""
    for svc in parley-relay-nginx parley-relay; do
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
    done
    rm -f /etc/systemd/system/parley-relay.service /etc/systemd/system/parley-relay-nginx.service
    systemctl daemon-reload
    remove_auto_update_cron "$install_dir"
    rm -rf "$install_dir"
    echo "Parley Chat Relay has been uninstalled."
}

main() {
    echo ""; echo "=== Parley Chat Relay Installer ==="; echo ""
    [ "$(id -u)" != "0" ] && { echo "Please run as root (sudo)."; exit 1; }
    echo "[I] Install"
    echo "[X] Uninstall"
    echo ""; read -rp "> " action
    case "${action,,}" in
        i) do_install ;;
        x) do_uninstall ;;
        *) echo "Invalid choice."; exit 1 ;;
    esac
}

main
