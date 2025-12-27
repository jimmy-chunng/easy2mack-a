cat > /usr/local/bin/wnmp << 'EOF'
#!/bin/bash

# ==================================================
# WNMP 管理脚本 v3.1 (全能版)
# 功能: 
#   1. install : 一键安装 PHP/MariaDB 环境
#   2. vhost   : 管理网站 (自动复用 CF Token)
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
CYAN='\033[0;36m'
PLAIN='\033[0m'

# Root 检查
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 需要 root 权限${PLAIN}" && exit 1

# -----------------------------------
# 功能 1: 环境安装 (发动机)
# -----------------------------------
install_env() {
    echo -e "${YELLOW}>>> [1/3] 更新软件源...${PLAIN}"
    apt-get update -qq

    echo -e "${YELLOW}>>> [2/3] 安装 PHP 和 MariaDB (可能需要几分钟)...${PLAIN}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        php-fpm php-mysql php-cli php-curl php-gd php-mbstring php-xml php-zip \
        mariadb-server unzip curl > /dev/null

    echo -e "${YELLOW}>>> [3/3] 启动服务...${PLAIN}"
    systemctl enable --now mariadb
    
    # 自动判断 PHP 版本并启动
    PHP_VERSION=$(php -v | head -n 1 | cut -d " " -f 2 | cut -d "." -f 1,2)
    systemctl enable --now "php${PHP_VERSION}-fpm"

    echo -e "${GREEN}=================================${PLAIN}"
    echo -e "${GREEN}环境安装完成！${PLAIN}"
    echo -e "PHP 版本: $PHP_VERSION"
    echo -e "数据库: MariaDB (默认密码为空)"
    echo -e "${GREEN}=================================${PLAIN}"
}

# -----------------------------------
# 功能 2: Cloudflare 凭证加载
# -----------------------------------
load_cf_creds() {
    if [ ! -f "$ACME_SCRIPT" ]; then
        echo -e "${RED}错误: 未找到 mack-a 安装的 acme.sh，请先安装 Xray 脚本。${PLAIN}"
        exit 1
    fi

    # 尝试读取 mack-a 保存的凭证
    if [ -f "$ACME_CONF" ]; then
        LOCAL_KEY=$(grep "SAVED_CF_Key='" "$ACME_CONF" | cut -d "'" -f 2)
        LOCAL_EMAIL=$(grep "SAVED_CF_Email='" "$ACME_CONF" | cut -d "'" -f 2)
        LOCAL_TOKEN=$(grep "SAVED_CF_Token='" "$ACME_CONF" | cut -d "'" -f 2)
        LOCAL_ACCOUNT=$(grep "SAVED_CF_Account_ID='" "$ACME_CONF" | cut -d "'" -f 2)
        
        if [[ -n "$LOCAL_TOKEN" && -n "$LOCAL_ACCOUNT" ]]; then
            echo -e "${CYAN}>>> ⚡️ 自动复用 Cloudflare Token${PLAIN}"
            export CF_Token="$LOCAL_TOKEN"
            export CF_Account_ID="$LOCAL_ACCOUNT"
            return 0
        fi
        if [[ -n "$LOCAL_KEY" && -n "$LOCAL_EMAIL" ]]; then
            echo -e "${CYAN}>>> ⚡️ 自动复用 Cloudflare Key${PLAIN}"
            export CF_Key="$LOCAL_KEY"
            export CF_Email="$LOCAL_EMAIL"
            return 0
        fi
    fi

    # 回退手动输入
    echo -e "${YELLOW}>>> 未检测到 CF 凭证，请输入:${PLAIN}"
    read -p "CF Global API Key: " INPUT_KEY
    read -p "CF Login Email: " INPUT_EMAIL
    [[ -z "$INPUT_KEY" || -z "$INPUT_EMAIL" ]] && return 1
    export CF_Key="$INPUT_KEY"
    export CF_Email="$INPUT_EMAIL"
}

# -----------------------------------
# 功能 3: 生成 Nginx 配置
# -----------------------------------
gen_nginx_conf() {
    local DOMAIN=$1
    local SOCKET=$2
    cat > ${NGINX_CONF_DIR}/${DOMAIN}.conf <<FINALCONF
server {
    listen 80;
    server_name ${DOMAIN};
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

# -----------------------------------
# 功能 4: 添加网站
# -----------------------------------
add_vhost() {
    DOMAIN=$1
    [ -z "$DOMAIN" ] && echo -e "${RED}用法: wnmp vhost add domain.com${PLAIN}" && exit 1
    
    # 检测 PHP
    PHP_V=$(php -v 2>/dev/null | head -n 1 | cut -d " " -f 2 | cut -d "." -f 1,2)
    PHP_SOCKET="/run/php/php${PHP_V}-fpm.sock"
    [ ! -S "$PHP_SOCKET" ] && PHP_SOCKET=$(find /run/php -name "php*-fpm.sock" | head -n 1)
    
    if [ -z "$PHP_SOCKET" ]; then
        echo -e "${RED}错误: 未检测到 PHP 环境！${PLAIN}"
        echo -e "${YELLOW}请先执行命令安装环境:  wnmp install${PLAIN}"
        exit 1
    fi

    echo -e "${YELLOW}>>> [1/3] 准备目录: $DOMAIN${PLAIN}"
    mkdir -p ${WEB_ROOT_BASE}/${DOMAIN}
    mkdir -p ${SSL_DIR}/${DOMAIN}
    echo "<?php phpinfo(); ?>" > ${WEB_ROOT_BASE}/${DOMAIN}/info.php
    chown -R www-data:www-data ${WEB_ROOT_BASE}/${DOMAIN}

    echo -e "${YELLOW}>>> [2/3] 申请证书...${PLAIN}"
    load_cf_creds || exit 1
    "$ACME_SCRIPT" --issue --dns dns_cf -d "${DOMAIN}"
    
    # 如果申请失败，可能是已经申请过，尝试直接安装
    if [ $? -ne 0 ]; then
        echo -e "${YELLOW}证书申请返回非0，尝试直接安装证书...${PLAIN}"
    fi

    "$ACME_SCRIPT" --install-cert -d "${DOMAIN}" \
        --key-file       ${SSL_DIR}/${DOMAIN}/privkey.pem  \
        --fullchain-file ${SSL_DIR}/${DOMAIN}/fullchain.pem \
        --reloadcmd     "systemctl reload nginx"

    echo -e "${YELLOW}>>> [3/3] 配置生效...${PLAIN}"
    gen_nginx_conf "$DOMAIN" "$PHP_SOCKET"
    
    if nginx -t > /dev/null 2>&1; then
        systemctl reload nginx
        echo -e "${GREEN}SUCCESS! 网站地址: https://${DOMAIN}/info.php${PLAIN}"
    else
        echo -e "${RED}Nginx 配置错误，已回滚${PLAIN}"
        rm -f ${NGINX_CONF_DIR}/${DOMAIN}.conf
        systemctl reload nginx
    fi
}

# -----------------------------------
# 主路由
# -----------------------------------
case "$1" in
    install)
        install_env
        ;;
    vhost)
        if [ "$2" == "add" ]; then add_vhost "$3"; 
        elif [ "$2" == "del" ]; then 
            rm -f "${NGINX_CONF_DIR}/$3.conf"; systemctl reload nginx; echo "Deleted $3";
        else echo "用法: wnmp vhost [add|del] domain.com"; fi
        ;;
    *)
        echo -e "WNMP Tool v3.1 (全能版)"
        echo -e "-------------------------"
        echo -e "1. 初始化环境(仅需一次):  wnmp install"
        echo -e "2. 添加网站:              wnmp vhost add domain.com"
        echo -e "3. 删除网站:              wnmp vhost del domain.com"
        ;;
esac
EOF

chmod +x /usr/local/bin/wnmp
