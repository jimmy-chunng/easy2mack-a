cat > /usr/local/bin/wnmp << 'EOF'
#!/bin/bash

# ==================================================
# WNMP 管理脚本 v2.0 (适配 mack-a / Cloudflare API)
# 功能: 
#   1. 复用 /root/.acme.sh 环境
#   2. 支持 HTTP 自动验证 (原有)
#   3. 支持 Cloudflare DNS API 验证 (新增/推荐)
# ==================================================

# --- 配置区域 ---
ACME_SCRIPT="/root/.acme.sh/acme.sh"
NGINX_CONF_DIR="/etc/nginx/conf.d"
WEB_ROOT_BASE="/var/www"
SSL_DIR="/etc/nginx/ssl"
CONFIG_FILE="/etc/wnmp_config"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# 检查 root
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须 root 权限。${PLAIN}" && exit 1

# 检查 acme.sh 是否存在 (复用 mack-a 的安装)
if [ ! -f "$ACME_SCRIPT" ]; then
    echo -e "${RED}未找到 acme.sh，请先运行 mack-a 安装脚本或手动安装。${PLAIN}"
    exit 1
fi

# 探测 PHP
detect_php_socket() {
    PHP_VERSION=$(php -v 2>/dev/null | head -n 1 | cut -d " " -f 2 | cut -d "." -f 1,2)
    PHP_SOCKET="/run/php/php${PHP_VERSION}-fpm.sock"
    [ ! -S "$PHP_SOCKET" ] && PHP_SOCKET=$(find /run/php -name "php*-fpm.sock" | head -n 1)
    if [ -z "$PHP_SOCKET" ]; then
        echo -e "${RED}错误: 未检测到 PHP-FPM。${PLAIN}"
        exit 1
    fi
}

# 配置 Cloudflare API
setup_cf_api() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi

    if [[ -z "$CF_Key" || -z "$CF_Email" ]]; then
        echo -e "${YELLOW}>>> 检测到使用 DNS 模式，首次需配置 Cloudflare API (将被保存)${PLAIN}"
        read -p "请输入 Cloudflare Global API Key: " CF_Key_Input
        read -p "请输入 Cloudflare Login Email: " CF_Email_Input
        
        if [[ -z "$CF_Key_Input" || -z "$CF_Email_Input" ]]; then
            echo -e "${RED}API Key 或 Email 不能为空!${PLAIN}"
            exit 1
        fi
        
        # 保存配置
        echo "export CF_Key=\"$CF_Key_Input\"" > "$CONFIG_FILE"
        echo "export CF_Email=\"$CF_Email_Input\"" >> "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
        source "$CONFIG_FILE"
        echo -e "${GREEN}>>> 配置已保存至 $CONFIG_FILE${PLAIN}"
    else
        echo -e "${CYAN}>>> 自动读取已保存的 Cloudflare API 配置...${PLAIN}"
    fi
}

# 生成 Nginx 配置 (核心逻辑)
gen_nginx_conf() {
    local DOMAIN=$1
    local SOCKET=$2
    
    cat > ${NGINX_CONF_DIR}/${DOMAIN}.conf <<FINALCONF
server {
    listen 80;
    server_name ${DOMAIN};
    # 强制跳转 HTTPS
    rewrite ^(.*) https://\$server_name\$1 permanent;
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN};
    root ${WEB_ROOT_BASE}/${DOMAIN};
    index index.php index.html;

    ssl_certificate ${SSL_DIR}/${DOMAIN}/fullchain.pem;
    ssl_certificate_key ${SSL_DIR}/${DOMAIN}/privkey.pem;
    
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${SOCKET};
    }

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
    
    location ~ /\.ht { deny all; }
}
FINALCONF
}

# 添加网站主逻辑
add_vhost() {
    DOMAIN=$1
    MODE=$2 # "dns" or "http"
    
    if [ -z "$DOMAIN" ]; then
        echo -e "${RED}用法: wnmp vhost add <域名> [dns|http]${PLAIN}"
        echo -e "示例: wnmp vhost add blog.xx.com dns (推荐)"
        exit 1
    fi
    
    # 默认为 http 模式
    [ -z "$MODE" ] && MODE="http"

    echo -e "${YELLOW}>>> [1/4] 准备环境 ($DOMAIN) - 模式: $MODE ...${PLAIN}"
    detect_php_socket
    mkdir -p ${WEB_ROOT_BASE}/${DOMAIN}
    echo "<?php phpinfo(); ?>" > ${WEB_ROOT_BASE}/${DOMAIN}/info.php
    chown -R www-data:www-data ${WEB_ROOT_BASE}/${DOMAIN}
    mkdir -p ${SSL_DIR}/${DOMAIN}

    # SSL 申请逻辑
    if [ "$MODE" == "dns" ]; then
        setup_cf_api
        echo -e "${YELLOW}>>> [2/4] 使用 Cloudflare API 申请证书...${PLAIN}"
        export CF_Key="$CF_Key"
        export CF_Email="$CF_Email"
        "$ACME_SCRIPT" --issue --dns dns_cf -d "${DOMAIN}"
    else
        echo -e "${YELLOW}>>> [2/4] 使用 HTTP 验证申请证书...${PLAIN}"
        # HTTP 模式需要先有 80 端口配置
        cat > ${NGINX_CONF_DIR}/${DOMAIN}.conf <<TEMPN
server { listen 80; server_name ${DOMAIN}; root ${WEB_ROOT_BASE}/${DOMAIN}; }
TEMPN
        systemctl reload nginx
        "$ACME_SCRIPT" --issue -d "${DOMAIN}" --nginx
    fi

    if [ $? -ne 0 ]; then
        echo -e "${RED}证书申请失败！请检查报错信息。${PLAIN}"
        [ "$MODE" == "http" ] && rm -f ${NGINX_CONF_DIR}/${DOMAIN}.conf
        exit 1
    fi

    echo -e "${YELLOW}>>> [3/4] 安装证书...${PLAIN}"
    "$ACME_SCRIPT" --install-cert -d "${DOMAIN}" \
        --key-file       ${SSL_DIR}/${DOMAIN}/privkey.pem  \
        --fullchain-file ${SSL_DIR}/${DOMAIN}/fullchain.pem \
        --reloadcmd     "systemctl reload nginx"

    echo -e "${YELLOW}>>> [4/4] 生成最终 Nginx 配置...${PLAIN}"
    gen_nginx_conf "$DOMAIN" "$PHP_SOCKET"
    
    nginx -t
    if [ $? -eq 0 ]; then
        systemctl reload nginx
        echo -e "${GREEN}SUCCESS! 网站已添加: https://${DOMAIN}${PLAIN}"
    else
        echo -e "${RED}Nginx 配置错误，已回滚${PLAIN}"
        rm -f ${NGINX_CONF_DIR}/${DOMAIN}.conf
        systemctl reload nginx
    fi
}

# 删除网站
del_vhost() {
    DOMAIN=$1
    [ -z "$DOMAIN" ] && echo -e "${RED}请输入域名${PLAIN}" && exit 1
    
    echo -e "${YELLOW}>>> 删除网站配置: $DOMAIN${PLAIN}"
    rm -f "${NGINX_CONF_DIR}/${DOMAIN}.conf"
    
    # 尝试吊销证书 (可选)
    # "$ACME_SCRIPT" --remove -d "$DOMAIN"
    
    systemctl reload nginx
    echo -e "${GREEN}网站已下线 (文件保留)${PLAIN}"
}

# 菜单路由
case "$1" in
    vhost)
        case "$2" in
            add) add_vhost "$3" "$4" ;;
            del) del_vhost "$3" ;;
            *) echo -e "用法: \n  wnmp vhost add domain.com [dns|http]\n  wnmp vhost del domain.com" ;;
        esac
        ;;
    *)
        echo -e "WNMP 管理脚本 v2.0"
        echo -e "-------------------"
        echo -e "用法: wnmp vhost add <域名> [模式]"
        echo -e "模式: dns (需要Cloudflare Key, 推荐) | http (默认)"
        ;;
esac
EOF

chmod +x /usr/local/bin/wnmp
