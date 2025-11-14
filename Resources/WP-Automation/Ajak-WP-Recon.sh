#!/bin/bash
#========================================#
#   AJAK CYBERACADEMY - WP Recon Tool    #
#   Author: Akash.P (enhanced by ChatGPT)#
#========================================#

set -o pipefail

# -------------------------
# Configurable globals
# -------------------------
DEFAULT_TIMEOUT=12
PARALLELISM=10

# -------------------------
# Banner Function
# -------------------------
banner() {
    echo
    echo -e "\e[38;5;198m    ___     _   _     _              \e[38;5;199m ____          _                _            "
    echo -e "\e[38;5;198m   / _ \   | | | |   | |            \e[38;5;199m/ ___|   _   _| |__   _   _  __| | ___  _ __ "
    echo -e "\e[38;5;200m  | | | |  | |_| | __| | __ _  __ _ \e[38;5;201m\___ \  | | | | '_ \ | | | |/ _  |/ _ \| '__|"
    echo -e "\e[38;5;200m  | |_| |  |  _  |/ _  |/ _  |/ _  | \e[38;5;201m___) | | |_| | |_) || |_| | (_| | (_) | |   "
    echo -e "\e[38;5;202m   \___/   |_| |_|\__,_|\__, |\__,_| \e[38;5;203m____/   \__,_|_.__/  \__,_|\__,_|\___/|_|   "
    echo -e "\e[38;5;202m                         __/ |                                                   "
    echo -e "\e[38;5;203m                        |___/                                                    "
    echo -e "\e[0m"
    echo -e "\e[1;38;5;207m     🚀 AJAK Cyberacademy | WordPress Recon Tool"
    echo -e "\e[1;38;5;213m     📝 Author: Akash.P"
    echo
}

# -------------------------
# Helpers
# -------------------------
_trim_protocol() {
    # remove protocol and trailing path, keep domain
    echo "$1" | sed -E 's~https?://~~' | sed 's#/.*##'
}

_fetch_html_once() {
    host="$1"
    timeout="${2:-$DEFAULT_TIMEOUT}"
    # try https then http
    out=$(curl -s -L --max-time "$timeout" "https://$host" 2>/dev/null || true)
    if [ -z "$out" ]; then
        out=$(curl -s -L --max-time "$timeout" "http://$host" 2>/dev/null || true)
    fi
    printf "%s" "$out"
}

_fetch_try() {
    # path must be a full URL
    path="$1"
    timeout="${2:-6}"
    for i in 1 2; do
        out=$(curl -s --max-time "$timeout" "$path" 2>/dev/null || true)
        if [ -n "$out" ]; then
            printf "%s" "$out"
            return 0
        fi
        sleep 1
    done
    return 1
}

# -------------------------
# WP Version Detection
# -------------------------
wp_version_detect() {
    url="$1"
    url="${url%/}"
    html=$(curl -s -L --max-time 20 "$url" 2>/dev/null || echo "")
    # 1 meta generator
    version=$(printf "%s" "$html" | tr '\n' ' ' | sed -n -E 's/.*<meta[^>]*name=["'"'"']?generator["'"'"']?[^>]*content=["'"'"']?[Ww]ord[Pp]ress[[:space:]]*([^"'"'"'> ]+).*/\1/p')
    if [ -n "$version" ]; then
        echo "WordPress $version (from meta generator tag)"
        return
    fi
    # 2 asset ver=
    version=$(printf "%s" "$html" | grep -oE 'ver=[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 | sed 's/ver=//')
    if [ -n "$version" ]; then
        echo "WordPress $version (from asset version string)"
        return
    fi
    # 3 RSS feed
    feed=$(curl -s -L --max-time 10 "${url%/}/feed/" 2>/dev/null || echo "")
    version=$(printf "%s" "$feed" | grep -oE '<generator>https?://wordpress.org/\?v=[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 | sed -E 's/.*v=([0-9.]+).*/\1/')
    if [ -n "$version" ]; then
        echo "WordPress $version (from RSS feed)"
        return
    fi
    # 4 readme.html
    readme=$(curl -s -L --max-time 10 "${url%/}/readme.html" 2>/dev/null || echo "")
    version=$(printf "%s" "$readme" | grep -oE 'Version [0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 | awk '{print $2}')
    if [ -n "$version" ]; then
        echo "WordPress $version (from readme.html)"
        return
    fi
    echo "Could not detect WordPress version."
}

# -------------------------
# WP Subdomain Detection (uses subfinder)
# -------------------------
wp_detect() {
    read -p "Enter target domain: " target
    target=$(_trim_protocol "$target")
    echo -e "\n[+] Scanning for WordPress installations under: $target ..."
    subfinder -d "$target" -silent 2>/dev/null | \
    xargs -P"$PARALLELISM" -I{} bash -c '
        html=$(curl -s -L --max-time 10 "https://{}" 2>/dev/null || curl -s -L --max-time 10 "http://{}" 2>/dev/null)
        if printf "%s" "$html" | grep -qi "wp-content"; then
            echo "[+] WordPress: https://{} or http://{}"
        fi
    '
}

# -------------------------
# Enumerate Plugins (improved detection)
# -------------------------
wp_plugins() {
    if [ -n "$1" ]; then
        target="$1"
    else
        read -p "Enter target domain: " target
    fi
    target=$(_trim_protocol "$target")
    echo -e "\n[+] Enumerating WordPress plugins for domain list: $target ..."
    subfinder -d "$target" -silent 2>/dev/null | \
    xargs -P"$PARALLELISM" -I{} bash -c '
        host="{}"
        html=$(curl -s -L --max-time 12 "https://$host" 2>/dev/null || curl -s -L --max-time 12 "http://$host" 2>/dev/null || echo "")
        printf "%s" "$html" | grep -oE "wp-content/plugins/[^/\"'"'"' ]+" | sed "s|wp-content/plugins/||" | sort -u | while read -r plugin; do
            ver=""
            # 1) look for ver= in page assets
            v1=$(printf "%s" "$html" | grep -oE "wp-content/plugins/'"$plugin"'/[^\"'"'"' ]*ver=[0-9.]+" | sed -nE "s/.*ver=([0-9.]+).*/\1/p" | head -n1)
            [ -n "$v1" ] && ver="$v1"
            # helper in container: try fetching style.css, main php, readme.txt
            fetch_try() {
                path="$1"
                for i in 1 2; do
                    out=$(curl -s --max-time 6 "$path" 2>/dev/null || true)
                    if [ -n "$out" ]; then
                        printf "%s" "$out"
                        return 0
                    fi
                    sleep 1
                done
                return 1
            }
            if [ -z "$ver" ]; then
                css=$(fetch_try "https://$host/wp-content/plugins/$plugin/style.css" || fetch_try "http://$host/wp-content/plugins/$plugin/style.css" || true)
                if [ -n "$css" ]; then
                    v2=$(printf "%s" "$css" | grep -i -m1 "^ *Version:" | sed -E "s/^[^0-9]*([0-9]+(\.[0-9]+)*).*/\1/" | tr -d " ")
                    [ -n "$v2" ] && ver="$v2"
                fi
            fi
            if [ -z "$ver" ]; then
                phpfile=$(fetch_try "https://$host/wp-content/plugins/$plugin/$plugin.php" || fetch_try "http://$host/wp-content/plugins/$plugin/$plugin.php" || true)
                if [ -n "$phpfile" ]; then
                    v3=$(printf "%s" "$phpfile" | sed -nE "s/^[[:space:]]*\/*\*.*[Vv]ersion[:[:space:]]*([0-9]+(\.[0-9]+)*).*/\1/p" | head -n1)
                    [ -n "$v3" ] && ver="$v3"
                fi
            fi
            if [ -z "$ver" ]; then
                rtxt=$(fetch_try "https://$host/wp-content/plugins/$plugin/readme.txt" || fetch_try "http://$host/wp-content/plugins/$plugin/readme.txt" || true)
                if [ -n "$rtxt" ]; then
                    v4=$(printf "%s" "$rtxt" | grep -i -m1 "Stable tag" | sed -E "s/.*Stable tag[:[:space:]]*([0-9]+(\.[0-9]+)*).*/\1/" || true)
                    [ -n "$v4" ] && ver="$v4"
                fi
            fi
            if [ -z "$ver" ]; then
                # fallback: look for any ver= occurrences for this plugin in page
                v5=$(printf "%s" "$html" | grep -oE "wp-content/plugins/$plugin/[^\"'"'"' ]*ver=[0-9.]+" | sed -nE "s/.*ver=([0-9.]+).*/\1/p" | head -n1)
                [ -n "$v5" ] && ver="$v5"
            fi
            [ -z "$ver" ] && ver="unknown"
            echo "{\"domain\":\"$host\",\"plugin\":\"$plugin\",\"version\":\"$ver\"}"
        done
    ' | jq -s .
}

# -------------------------
# Enumerate Themes (improved detection)
# -------------------------
wp_themes() {
    if [ -n "$1" ]; then
        target="$1"
    else
        read -p "Enter target domain: " target
    fi
    target=$(_trim_protocol "$target")
    echo -e "\n[+] Enumerating WordPress themes for domain list: $target ..."
    subfinder -d "$target" -silent 2>/dev/null | \
    xargs -P"$PARALLELISM" -I{} bash -c '
        host="{}"
        html=$(curl -s -L --max-time 12 "https://$host" 2>/dev/null || curl -s -L --max-time 12 "http://$host" 2>/dev/null || echo "")
        printf "%s" "$html" | grep -oE "wp-content/themes/[^/\"'"'"' ]+" | sed "s|wp-content/themes/||" | sort -u | while read -r theme; do
            ver=""
            v1=$(printf "%s" "$html" | grep -oE "wp-content/themes/'"$theme"'/[^\"'"'"' ]*ver=[0-9.]+" | sed -nE "s/.*ver=([0-9.]+).*/\1/p" | head -n1)
            [ -n "$v1" ] && ver="$v1"
            fetch_try() {
                path="$1"
                for i in 1 2; do
                    out=$(curl -s --max-time 6 "$path" 2>/dev/null || true)
                    if [ -n "$out" ]; then
                        printf "%s" "$out"
                        return 0
                    fi
                    sleep 1
                done
                return 1
            }
            if [ -z "$ver" ]; then
                css=$(fetch_try "https://$host/wp-content/themes/$theme/style.css" || fetch_try "http://$host/wp-content/themes/$theme/style.css" || true)
                if [ -n "$css" ]; then
                    v2=$(printf "%s" "$css" | grep -i -m1 "^ *Version:" | sed -E "s/^[^0-9]*([0-9]+(\.[0-9]+)*).*/\1/" | tr -d " ")
                    [ -n "$v2" ] && ver="$v2"
                fi
            fi
            if [ -z "$ver" ]; then
                rtxt=$(fetch_try "https://$host/wp-content/themes/$theme/readme.txt" || fetch_try "http://$host/wp-content/themes/$theme/readme.txt" || true)
                if [ -n "$rtxt" ]; then
                    v3=$(printf "%s" "$rtxt" | grep -i -m1 "Version" | sed -nE "s/.*([0-9]+(\.[0-9]+)*).*/\1/p" || true)
                    [ -n "$v3" ] && ver="$v3"
                fi
            fi
            [ -z "$ver" ] && ver="unknown"
            echo "{\"domain\":\"$host\",\"theme\":\"$theme\",\"version\":\"$ver\"}"
        done
    ' | jq -s .
}

# -------------------------
# Check Sensitive Directories
# -------------------------
check_sensitive_dirs() {
    read -p "Enter target URL (with https/http): " TARGET
    TARGET=$(echo "$TARGET" | sed 's:/*$::')
    DIRS=(
        "/wp-admin.php"
        "/wp-config.php"
        "/wp-content/uploads/"
        "/wp-load.php"
        "/wp-signup.php"
        "/wp-json/"
        "/wp-includes/"
        "/wp-login.php"
        "/wp-links-opml.php"
        "/wp-activate.php"
        "/wp-blog-header.php"
        "/wp-cron.php"
        "/wp-links.php"
        "/wp-mail.php"
        "/xmlrpc.php"
        "/wp-settings.php"
        "/wp-trackback.php"
        "/wp-json/wp/v2/users/"
        "/wp-json/wp/v2/plugins/"
        "/wp-json/wp/v2/themes/"
        "/wp-json/wp/v2/comments/"
    )
    echo -e "\n[+] Checking sensitive directories on $TARGET ..."
    RESULTS="["
    for DIR in "${DIRS[@]}"; do
        STATUS=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 8 "$TARGET$DIR" 2>/dev/null || echo "000")
        if [ "$STATUS" == "200" ] || [ "$STATUS" == "403" ]; then
            RESULTS+="{\"path\": \"$DIR\", \"status\": $STATUS},"
        fi
    done
    RESULTS=${RESULTS%,}
    RESULTS+="]"
    echo "$RESULTS" | jq .
}

# -------------------------
# Run All
# -------------------------
run_all() {
    read -p "Enter main URL (for banner & dirs check, e.g. https://example.com): " main_url
    read -p "Enter target domain (for subfinder scans, e.g. example.com): " target_domain

    echo -e "\n========== WP VERSION BANNER =========="
    wp_version_detect "$main_url"

    echo -e "\n========== WP DETECTION =========="
    subfinder -d "$target_domain" -silent 2>/dev/null | \
    xargs -P"$PARALLELISM" -I{} bash -c '
        html=$(curl -s -L --max-time 10 "https://{}" 2>/dev/null || curl -s -L --max-time 10 "http://{}" 2>/dev/null)
        if printf "%s" "$html" | grep -qi "wp-content"; then
            echo "[+] WordPress: https://{} or http://{}"
        fi
    '

    echo -e "\n========== WP PLUGINS =========="
    wp_plugins "$target_domain"

    echo -e "\n========== WP THEMES =========="
    wp_themes "$target_domain"

    echo -e "\n========== SENSITIVE DIRS =========="
    # call function but provide main_url as input for prompt bypass
    echo "$main_url" | { read -r url; check_sensitive_dirs <<< "$url"; } 2>/dev/null
}

# -------------------------
# Menu
# -------------------------
menu() {
    banner
    echo "1) Grab WP Version Banner"
    echo "2) Detect WordPress on Subdomains"
    echo "3) Enumerate Plugins & Versions"
    echo "4) Enumerate Themes & Versions"
    echo "5) Check Sensitive WP Directories"
    echo "6) Run All Above"
    echo "7) Exit"
    read -p "Select an option: " choice

    case $choice in
        1) read -p "Enter URL (with http/https): " url; echo -e "\n[+] Fetching WordPress Version from $url..."; wp_version_detect "$url" ;;
        2) wp_detect ;;
        3) read -p "Enter target domain: " td; wp_plugins "$td" ;;
        4) read -p "Enter target domain: " td; wp_themes "$td" ;;
        5) check_sensitive_dirs ;;
        6) run_all ;;
        7) exit 0 ;;
        *) echo "Invalid choice" ;;
    esac
}

# -------------------------
# Run loop
# -------------------------
while true; do
    menu
done
