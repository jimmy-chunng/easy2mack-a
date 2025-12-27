#!/bin/bash

# ====================================================
# NXM v4.0: Nginx-Xray-Manager (Final Stable)
# 架构: Xray (443 Front) -> Nginx (31302 Back)
# 功能: 自动环境修复、双模式建站、冲突自动清洗
# ====================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}>>> 正在部署 NXM v4.0 (终极稳定版)...${NC}"

# ----------------------------------------------------
# 1. 强力清洗 (解决 Nginx 启动失败/端口占用的根源)
# ----------------------------------------------------
echo -e "${GREEN}>>> [1/5] 清理残留进程与配置...${NC}"
killall -9 nginx >/dev/null 2>&1
systemctl stop nginx >/dev/null 2>&1

# 备份并清空现有配置，防止 alone.conf 等旧文件冲突
mkdir -p /etc/nginx/conf.d/bak
mv /etc/nginx/conf.d/*.conf /etc/nginx/conf.d/bak/ >/dev/null 2>&1
echo -e "   - 旧配置已备份至 /etc/nginx/conf.d/bak/"

# ----------------------------------------------------
# 2. 基础环境与 PHP 修复 (解决 520/权限错误)
# ----------------------------------------------------
echo -e "${GREEN}>>> [2/5] 检查与修复运行环境...${NC}"
apt update -y > /dev/null 2>&1
apt install -y php-fpm php-mysql php-cli php-curl php-gd php-mbstring php-xml php-zip unzip nginx curl socat > /dev/null 2>&1

PHP_VER=$(php -v | head -n 1 | cut -d " " -f 2 | cut -f1-2 -d".")
PHP_SOCK="/run/php/php${PHP_VER}-fpm.sock"

# 强制修正 PHP 权限为 www-data
sed -i "s/^listen.owner.*/listen.owner = www-data/" /etc/php/${PHP_VER}/fpm/pool.d/www.conf
sed -i "s/^listen.group.*/listen.group = www-data/" /etc/php/${PHP_VER}/fpm/pool.d/www.conf
sed -i "s/^;listen.mode.*/listen.mode = 0666/" /etc/php/${PHP_VER}/fpm/pool.d/www.conf
systemctl restart php${PHP_VER}-fpm
chmod 777 $PHP_SOCK

# ----------------------------------------------------
# 3. 安装 acme.sh (解决 SSL 申请依赖)
# ----------------------------------------------------
echo -e "${GREEN}>>> [3/5] 配置 acme.sh 证书工具...${NC}"
if ! command -v acme.sh &> /dev/null; then
    curl https://get.acme.sh | sh -s email=admin@iddns.xyz > /dev/null 2>&1
    ln -s /root/.acme.sh/acme.sh /usr/local/bin/acme.sh
fi
# 预注册 ZeroSSL 防止报错
/root/.acme.sh/acme.sh --register-account -m admin@iddns.xyz --server zerossl > /dev/null 2>&1

# ----------------------------------------------------
# 4. 生成 Nginx 主配置 (锁定黄金端口 31302)
# ----------------------------------------------------
echo -e "${GREEN}>>> [4/5] 部署 Nginx 核心架构...${NC}"

# 定义唯一的、安全的内部回落通道
# 包含 proxy_protocol (获取真实IP) 和 http2 (匹配 Xray 转发)
INTERNAL_LISTEN="listen 127.0.0.1:31302 http2 proxy_protocol;"

# 保存模板供 nxm 工具调用
echo "$INTERNAL_LISTEN" > /etc/nginx/nxm_internal_listen

# 生成伪装站配置
cat > /etc/nginx/conf.d/00_default_nxm.conf << EOF
server {
    $INTERNAL_LISTEN
    
    listen 80;
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
    location / { try_files \$uri \$uri/ /index.php?\$args; }
}
EOF
chown -R www-data:www-data /usr/share/nginx/html

# ----------------------------------------------------
# 5. 安装 nxm 管理工具 (双模式逻辑)
# ----------------------------------------------------
echo -e "${GREEN}>>> [5/5] 安装 nxm 管理工具...${NC}"

cat > /usr/local/bin/nxm << 'SCRIPT_EOF'
#!/bin/bash
# NXM Manager Tool v4.0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

function add_vhost() {
    echo -e "${GREEN}=== 添加新网站 (NXM v4.0) ===${NC}"
    echo "1. Xray 分流模式 (推荐): 复用 443 端口，无需 Nginx 证书，必须是 *.iddns.xyz 的子域。"
    echo "2. 独立 SSL 模式: 使用 8443 端口，使用 CF API 申请证书，适合任意域名。"
    echo ""
    read -p "请选择模式 [1/2]: " MODE

    if [[ "$MODE" != "1" && "$MODE" != "2" ]]; then
        echo "❌ 选择无效"; exit 1
    fi

    read -p "请输入域名: " DOMAIN
    [ -z "$DOMAIN" ] && exit 1

    WEB_ROOT="/var/www/$DOMAIN"
    mkdir -p $WEB_ROOT
    echo "<?php phpinfo(); ?>" > $WEB_ROOT/phpinfo.php
    chown -R www-data:www-data $WEB_ROOT
    chmod -R 755 $WEB_ROOT

    # 获取 PHP 环境
    PHP_VER=$(php -v | head -n 1 | cut -d " " -f 2 | cut -f1-2 -d".")
    PHP_SOCK="/run/php/php${PHP_VER}-fpm.sock"

    # --- 模式 1: Xray 分流 (内部监听) ---
    if [[ "$MODE" == "1" ]]; then
        INTERNAL_LISTEN=$(cat /etc/nginx/nxm_internal_listen)
        
        cat > /etc/nginx/conf.d/${DOMAIN}.conf << EOF
server {
    # 监听内部 31302，等待 Xray 转发
    $INTERNAL_LISTEN
    
    server_name $DOMAIN;
    root $WEB_ROOT;
    index index.php index.html;

    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;

    # 日志
    access_log /var/log/nginx/${DOMAIN}.access.log;
    error_log /var/log/nginx/${DOMAIN}.error.log;

    location ~ \.php$ {
        try_files \$uri =404;
        fastcgi_pass unix:$PHP_SOCK;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTPS on;
    }
    location / { try_files \$uri \$uri/ /index.php?\$args; }
}
EOF
        nginx -t && systemctl reload nginx
        echo -e "${GREEN}🎉 [分流模式] 部署成功!${NC}"
        echo "请确保 Xray 证书已包含此域名，访问: https://$DOMAIN/phpinfo.php"
    fi

    # --- 模式 2: 独立 SSL (8443 端口) ---
    if [[ "$MODE" == "2" ]]; then
        read -p "请输入 Cloudflare API Token: " CF_TOKEN
        export CF_Token="$CF_TOKEN"
        
        echo ">>> 正在申请证书..."
        /root/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --server zerossl
        
        if [ $? -ne 0 ]; then echo -e "${RED}❌ 证书申请失败${NC}"; exit 1; fi

        SSL_DIR="/etc/nginx/ssl/$DOMAIN"
        mkdir -p $SSL_DIR
        /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
            --key-file       $SSL_DIR/private.key  \
            --fullchain-file $SSL_DIR/fullchain.cer \
            --reloadcmd     "systemctl reload nginx"

        cat > /etc/nginx/conf.d/${DOMAIN}.conf << EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host:8443\$request_uri;
}
server {
    listen 8443 ssl http2;
    server_name $DOMAIN;
    root $WEB_ROOT;
    index index.php index.html;

    ssl_certificate $SSL_DIR/fullchain.cer;
    ssl_certificate_key $SSL_DIR/private.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    location ~ \.php$ {
        try_files \$uri =404;
        fastcgi_pass unix:$PHP_SOCK;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
    location / { try_files \$uri \$uri/ /index.php?\$args; }
}
EOF
        nginx -t && systemctl reload nginx
        echo -e "${GREEN}🎉 [独立模式] 部署成功!${NC}"
        echo "访问地址: https://$DOMAIN:8443/phpinfo.php"
    fi
}

case "$1" in
    "vhost") [ "$2" == "add" ] && add_vhost ;;
    "fix") systemctl restart php*-fpm nginx; echo "修复完成" ;;
    *) echo "Usage: nxm vhost add" ;;
esac
SCRIPT_EOF
chmod +x /usr/local/bin/nxm

# 启动 Nginx
systemctl restart nginx

echo -e "${GREEN}✅ NXM v4.0 部署完成！(已重置为最简架构)${NC}"
echo "请运行 nxm vhost add 开始建站。"
