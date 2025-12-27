#!/bin/bash

# ====================================================
# NXM v2.0: Nginx-Xray-Manager (SSL Enhanced Edition)
# 功能: 自动适配端口、PHP环境、vhost管理(含CF SSL)
# ====================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}>>> 正在部署 NXM v2.0 (集成 Cloudflare SSL 自动化)...${NC}"

# ----------------------------------------------------
# 1. 基础环境与 PHP 安装
# ----------------------------------------------------
echo -e "${GREEN}>>> [1/5] 检查并安装基础环境 (PHP & ACME依赖)...${NC}"
apt update -y > /dev/null 2>&1
apt install -y php-fpm php-mysql php-cli php-curl php-gd php-mbstring php-xml php-zip unzip nginx curl socat > /dev/null 2>&1

# 获取 PHP 版本和 Socket
PHP_VER=$(php -v | head -n 1 | cut -d " " -f 2 | cut -f1-2 -d".")
PHP_SOCK="/run/php/php${PHP_VER}-fpm.sock"
echo -e "   - PHP 版本: ${GREEN}$PHP_VER${NC}"
echo -e "   - Socket: ${GREEN}$PHP_SOCK${NC}"

# 修复 PHP 权限
sed -i "s/^listen.owner.*/listen.owner = www-data/" /etc/php/${PHP_VER}/fpm/pool.d/www.conf
sed -i "s/^listen.group.*/listen.group = www-data/" /etc/php/${PHP_VER}/fpm/pool.d/www.conf
sed -i "s/^;listen.mode.*/listen.mode = 0666/" /etc/php/${PHP_VER}/fpm/pool.d/www.conf
systemctl restart php${PHP_VER}-fpm
chmod 777 $PHP_SOCK

# ----------------------------------------------------
# 2. 安装 acme.sh (如果不存在)
# ----------------------------------------------------
echo -e "${GREEN}>>> [2/5] 检查 acme.sh 证书工具...${NC}"
if ! command -v acme.sh &> /dev/null; then
    if [ -f "/root/.acme.sh/acme.sh" ]; then
        # 如果已安装但不在 path 中，建立软链接
        ln -s /root/.acme.sh/acme.sh /usr/local/bin/acme.sh
        echo -e "   - 发现已有 acme.sh，已建立链接"
    else
        echo -e "   - 正在安装 acme.sh..."
        curl https://get.acme.sh | sh -s email=my@example.com > /dev/null 2>&1
        ln -s /root/.acme.sh/acme.sh /usr/local/bin/acme.sh
    fi
else
    echo -e "   - acme.sh 已安装"
fi

# ----------------------------------------------------
# 3. 自动侦测 Xray 回落端口
# ----------------------------------------------------
echo -e "${GREEN}>>> [3/5] 自动分析 Xray 回落端口...${NC}"
XRAY_CONF_DIR="/etc/v2ray-agent/xray/conf"
DETECTED_PORTS=$(grep -r "dest" $XRAY_CONF_DIR 2>/dev/null | grep -oE '"dest": ?[0-9]+' | grep -oE '[0-9]+' | sort -u)

if [ -z "$DETECTED_PORTS" ]; then
    DETECTED_PORTS="80"
    echo -e "${YELLOW}   ! 未检测到 Xray 端口，默认使用 80${NC}"
fi

LISTEN_BLOCK=""
for PORT in $DETECTED_PORTS; do
    if [[ "$PORT" -gt 0 && "$PORT" -lt 65535 ]]; then
        HAS_XVER=$(grep -r "$PORT" $XRAY_CONF_DIR -A 10 -B 10 2>/dev/null | grep '"xver":.*1')
        if [ -n "$HAS_XVER" ]; then
            LISTEN_BLOCK+=$'\n    listen 127.0.0.1:'$PORT' proxy_protocol;'
        else
            LISTEN_BLOCK+=$'\n    listen 127.0.0.1:'$PORT';'
        fi
    fi
done

# ----------------------------------------------------
# 4. 生成默认伪装站配置
# ----------------------------------------------------
echo -e "${GREEN}>>> [4/5] 刷新 Nginx 伪装站配置...${NC}"
cat > /etc/nginx/conf.d/00_default_nxm.conf << EOF
server {
    # 自动适配的端口
    $LISTEN_BLOCK
    
    # listen 80;
    http2 on;
    server_name _;
    root /usr/share/nginx/html;
    index index.php index.html index.htm;
    
    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;

    location ~ \.php$ {
        try_files \$uri =404;
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:$PHP_SOCK;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
}
EOF
chown -R www-data:www-data /usr/share/nginx/html

# ----------------------------------------------------
# 5. 生成 nxm 管理脚本 (核心升级部分)
# ----------------------------------------------------
echo -e "${GREEN}>>> [5/5] 安装 nxm 管理工具...${NC}"

cat > /usr/local/bin/nxm << 'SCRIPT_EOF'
#!/bin/bash
# NXM Manager Tool v2.0

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

function show_help() {
    echo "==============================================="
    echo "NXM 管理工具 (SSL 增强版)"
    echo "==============================================="
    echo "nxm vhost add    -> 添加新网站 (支持 CF DNS SSL)"
    echo "nxm fix          -> 一键修复 PHP/520 错误"
    echo "nxm status       -> 查看服务状态"
    echo "==============================================="
}

function add_vhost() {
    echo -e "${GREEN}=== 添加新网站 (SSL 向导) ===${NC}"
    
    # 1. 输入域名
    read -p "请输入域名 (如 blog.test.com): " DOMAIN
    if [ -z "$DOMAIN" ]; then echo "❌ 域名不能为空"; exit 1; fi

    WEB_ROOT="/var/www/$DOMAIN"
    mkdir -p $WEB_ROOT
    echo "<?php phpinfo(); ?>" > $WEB_ROOT/phpinfo.php
    chown -R www-data:www-data $WEB_ROOT
    chmod -R 755 $WEB_ROOT

    # 2. 询问 SSL
    read -p "是否需要自动申请 SSL 证书 (使用 Cloudflare DNS)? [y/n]: " NEED_SSL
    
    PHP_VER=$(php -v | head -n 1 | cut -d " " -f 2 | cut -f1-2 -d".")
    PHP_SOCK="/run/php/php${PHP_VER}-fpm.sock"

    if [[ "$NEED_SSL" == "y" ]]; then
        # 3. SSL 申请流程
        echo "-----------------------------------------------"
        echo "请提供 Cloudflare API Token (需要 Zone.DNS 编辑权限)"
        echo "如果没有，请去 CF 后台 -> 我的个人资料 -> API 令牌 -> 创建令牌 -> 编辑区域 DNS"
        echo "-----------------------------------------------"
        read -p "请输入 CF API Token: " CF_TOKEN
        
        if [ -z "$CF_TOKEN" ]; then echo "❌ Token 不能为空"; exit 1; fi

        echo ">>> 正在使用 acme.sh 申请证书 (这可能需要几分钟)..."
        export CF_Token="$CF_TOKEN"
        
        # 申请证书
        /root/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN"
        
        if [ $? -ne 0 ]; then
            echo -e "${RED}❌ 证书申请失败，请检查 Token 权限或域名解析是否托管在该账号下。${NC}"
            exit 1
        fi

        # 安装证书
        SSL_DIR="/etc/nginx/ssl/$DOMAIN"
        mkdir -p $SSL_DIR
        /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
            --key-file       $SSL_DIR/private.key  \
            --fullchain-file $SSL_DIR/fullchain.cer \
            --reloadcmd     "systemctl reload nginx"

        echo -e "${GREEN}✅ 证书已获取并安装到 $SSL_DIR${NC}"

        # 生成 HTTPS 配置
        cat > /etc/nginx/conf.d/${DOMAIN}.conf << EOF
server {
    listen 80;
    server_name $DOMAIN;
    # 强制跳转 HTTPS
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    http2 on;
    server_name $DOMAIN;
    root $WEB_ROOT;
    index index.php index.html;

    ssl_certificate $SSL_DIR/fullchain.cer;
    ssl_certificate_key $SSL_DIR/private.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    access_log /var/log/nginx/${DOMAIN}.access.log;
    error_log /var/log/nginx/${DOMAIN}.error.log;

    location ~ \.php$ {
        try_files \$uri =404;
        fastcgi_pass unix:$PHP_SOCK;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
    
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
}
EOF

    else
        # 4. 仅 HTTP 模式
        cat > /etc/nginx/conf.d/${DOMAIN}.conf << EOF
server {
    listen 80;
    server_name $DOMAIN;
    root $WEB_ROOT;
    index index.php index.html;

    location ~ \.php$ {
        try_files \$uri =404;
        fastcgi_pass unix:$PHP_SOCK;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
}
EOF
    fi

    nginx -t && systemctl reload nginx
    echo -e "${GREEN}🎉 网站部署成功!${NC}"
    if [[ "$NEED_SSL" == "y" ]]; then
        echo "访问地址: https://$DOMAIN/phpinfo.php"
    else
        echo "访问地址: http://$DOMAIN/phpinfo.php"
    fi
}

function fix_system() {
    echo ">>> 正在修复权限..."
    PHP_VER=$(php -v | head -n 1 | cut -d " " -f 2 | cut -f1-2 -d".")
    chmod 777 /run/php/php${PHP_VER}-fpm.sock
    systemctl restart php${PHP_VER}-fpm
    systemctl restart nginx
    echo "✅ 修复完成"
}

case "$1" in
    "vhost") [ "$2" == "add" ] && add_vhost || show_help ;;
    "fix") fix_system ;;
    "status") systemctl status nginx xray | grep Active ;;
    *) show_help ;;
esac
SCRIPT_EOF

chmod +x /usr/local/bin/nxm
systemctl restart nginx
echo -e "${GREEN}✅ NXM v2.0 部署完成！${NC}"
echo -e "使用方法: 输入 ${YELLOW}nxm vhost add${NC} 添加带 SSL 的网站"
