cat > /usr/local/bin/wnmp << 'EOF'
#!/bin/bash
# ==================================================
# WNMP 管理脚本 v3.5 (修复安装功能 + 权限自动修正)
# ==================================================

# --- 配置 ---
ACME_BASE="/root/.acme.sh"
ACME_SCRIPT="$ACME_BASE/acme.sh"
ACME_CONF="$ACME_BASE/account.conf"
NGINX_CONF_DIR="/etc/nginx/conf.d"
WEB_ROOT_BASE="/var/www"
SSL_DIR="/etc/nginx/ssl"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 需要 root 权限${PLAIN}" && exit 1

# -----------------------------------
# 功能 1: 环境安装 (找回丢失的功能)
# -----------------------------------
install_env() {
    echo -e "${YELLOW}>>> [1/4] 更新软件源...${PLAIN}"
    apt-get update -qq

    echo -e "${YELLOW}>>> [2/4] 安装 PHP 和 MariaDB...${PLAIN}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        php-fpm php-mysql php-cli php-curl php-gd php-mbstring php-xml php-zip \
        mariadb-server unzip curl socat > /dev/null

    echo -e "${YELLOW}>>> [3/4] 启动服务...${PLAIN}"
    systemctl enable --now mariadb
    PHP_VERSION=$(php -v | head -n 1 | cut -d " " -f 2 | cut -d "." -f 1,2)
    systemctl enable --now "php${PHP_VERSION}-fpm"
    
    echo -e "${YELLOW}>>> [4/4] 自动修正 Nginx 权限配置...${PLAIN}"
    # 强制将 Nginx 运行用户修改为 www-data (解决 404/Permission denied 问题)
    if grep -q "user nginx;" /etc/nginx/nginx.conf; then
        sed -i 's/^user nginx;/user www-data;/g' /etc/nginx/nginx.conf
        echo -e "已将 Nginx 用户修正为 www-data"
    elif grep -q "user root;" /etc/nginx/nginx.conf; then
        sed -i 's/^user root;/user www-data;/g' /etc/nginx/nginx.conf
        echo -e "已将 Nginx 用户从 root 修正为 www-data"
    fi
    
    # 确保 Web 目录属于 www-data
    chown -R www-data:www-data /var/www
    
    # 重启 Nginx
    systemctl restart nginx

    echo -e "${GREEN}=================================${PLAIN}"
    echo -e "${GREEN}环境安装完成 (PHP $PHP_VERSION)${PLAIN}"
    echo -e "${GREEN}Nginx 用户已统一为 www-data${PLAIN}"
    echo -e "${GREEN}=================================${PLAIN}"
}

# -----------------------------------
# 功能: 凭证加载
# -----------------------------------
load_cf_creds() {
    [ ! -f "$ACME_SCRIPT" ] && echo -e "${RED}未找到 acme.sh${PLAIN}" && exit 1
    "$ACME_SCRIPT" --set-default-ca --server letsencrypt >/dev/null 2>&1
    if [ -f "$ACME_CONF" ]; then
        LOCAL_KEY=$(grep "SAVED_CF_Key='" "$ACME_CONF" | cut -d "'" -f 2)
        LOCAL_EMAIL=$(grep "SAVED_CF_Email='" "$ACME_CONF" | cut -d "'" -f 2)
        LOCAL_TOKEN=$(grep "SAVED_CF_Token='" "$ACME_CONF" | cut -d "'" -f 2)
        LOCAL_ACCOUNT=$(grep "SAVED_CF_Account_ID='" "$ACME_CONF" | cut -d "'" -f 2)
        if [[ -n "$LOCAL_TOKEN" && -n "$LOCAL_ACCOUNT" ]]; then
            export CF_Token="$LOCAL_TOKEN"; export CF_Account_ID="$LOCAL_ACCOUNT"; return 0
        fi
        if [[ -n "$LOCAL_KEY" && -n "$LOCAL_EMAIL" ]]; then
            export CF_Key="$LOCAL_KEY"; export CF_Email="$LOCAL_EMAIL"; return 0
        fi
    fi
    echo -e "${RED}未检测到 CF 凭证，请检查 acme.sh 状态${PLAIN}"; return 1
}

# -----------------------------------
# 功能: 生成配置
# -----------------------------------
gen_nginx_conf() {
    local DOMAIN=$1
    local SOCKET=$2
    # 检测 Nginx 版本是否支持 http2 on 指令
    HTTP2_DIRECTIVE="listen 443 ssl http2;"
    HTTP2_ON=""
    NGINX_VER=$(nginx -v 2>&1 | cut -d '/' -f 2 | cut -d ' ' -f 1)
    if [[ "$(printf '%s\n' "1.25.1" "$NGINX_VER" | sort -V | head -n1)" == "1.25.1" ]]; then
        HTTP2_DIRECTIVE="listen 443 ssl;"
        HTTP2_ON="http2 on;"
    fi

    cat > ${NGINX_CONF_DIR}/${DOMAIN}.conf <<FINALCONF
server {
    listen 80;
    server_name ${DOMAIN};
    rewrite ^(.*) https://\$server_name\$1 permanent;
}
server {
    ${HTTP2_DIRECTIVE}
    ${HTTP2_ON}
    server_name ${DOMAIN};
    root ${WEB_ROOT_BASE}/${DOMAIN};
    index index.php index.html;

    ssl_certificate ${SSL_DIR}/${DOMAIN}/fullchain.pem;
    ssl_certificate_key ${SSL_DIR}/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;

    location ~ \.php$ {
        try_files \$uri =404;
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:${SOCKET};
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
    location / { try_files \$uri \$uri/ /index.php?\$args; }
    location ~ /\.ht { deny all; }
}
FINALCONF
}

# -----------------------------------
# 功能: 添加网站
# -----------------------------------
add_vhost() {
    DOMAIN=$1
    [ -z "$DOMAIN" ] && echo -e "${RED}用法: wnmp vhost add domain.com${PLAIN}" && exit 1
    
    PHP_V=$(php -v 2>/dev/null | head -n 1 | cut -d " " -f 2 | cut -d "." -f 1,2)
    PHP_SOCKET="/run/php/php${PHP_V}-fpm.sock"
    [ ! -S "$PHP_SOCKET" ] && PHP_SOCKET=$(find /run/php -name "php*-fpm.sock" | head -n 1)
    
    if [ -z "$PHP_SOCKET" ]; then
         echo -e "${RED}未检测到 PHP，正在尝试自动安装环境...${PLAIN}"
         install_env
         # 重新获取 socket
         PHP_V=$(php -v | head -n 1 | cut -d " " -f 2 | cut -d "." -f 1,2)
         PHP_SOCKET="/run/php/php${PHP_V}-fpm.sock"
    fi

    if [ ! -f "${SSL_DIR}/${DOMAIN}/fullchain.pem" ]; then
        load_cf_creds
        "$ACME_SCRIPT" --issue --dns dns_cf -d "${DOMAIN}" --force
        "$ACME_SCRIPT" --install-cert -d "${DOMAIN}" --key-file ${SSL_DIR}/${DOMAIN}/privkey.pem --fullchain-file ${SSL_DIR}/${DOMAIN}/fullchain.pem --reloadcmd "systemctl reload nginx"
    else
        echo -e "${GREEN}>>> 证书已存在${PLAIN}"
    fi

    gen_nginx_conf "$DOMAIN" "$PHP_SOCKET"
    nginx -t
    if [ $? -eq 0 ]; then
        systemctl reload nginx
        echo -e "${GREEN}SUCCESS! 网站地址: https://${DOMAIN}/info.php${PLAIN}"
    else
        echo -e "${RED}Nginx 配置错误，请检查端口冲突 (Xray vs Nginx)${PLAIN}"
    fi
}

# -----------------------------------
# 主路由
# -----------------------------------
case "$1" in
    install) install_env ;;
    vhost)
        if [ "$2" == "add" ]; then add_vhost "$3"; 
        elif [ "$2" == "del" ]; then rm -f "${NGINX_CONF_DIR}/$3.conf"; systemctl reload nginx; echo "Deleted $3";
        else echo "用法: wnmp vhost [add|del] domain.com"; fi ;;
    *) 
        echo "WNMP v3.5 (Fix Install)"
        echo "用法:"
        echo "  wnmp install             # 安装环境 (PHP/MySQL)"
        echo "  wnmp vhost add <域名>    # 添加网站"
        ;;
esac
EOF
chmod +x /usr/local/bin/wnmp
