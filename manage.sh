#!/bin/bash

# ==========================================
# NXM: Nginx-Xray-Manager 自动化整合脚本
# 适配: mack-a v2ray-agent 脚本
# 功能: 自动适配端口、安装PHP、提供vhost管理
# ==========================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo -e "${YELLOW}>>> 开始执行 NXM 自动化部署...${NC}"

# 1. 检查 Xray 配置文件目录
XRAY_CONF_DIR="/etc/v2ray-agent/xray/conf"
if [ ! -d "$XRAY_CONF_DIR" ]; then
    echo -e "${RED}❌ 错误: 未找到 Xray 配置文件目录 ($XRAY_CONF_DIR)。${NC}"
    echo "请确认你已经安装了 mack-a 的脚本。"
    exit 1
fi

# 2. 安装/更新 PHP 环境
echo -e "${GREEN}>>> [1/4] 安装 PHP 环境...${NC}"
apt update -y > /dev/null 2>&1
apt install -y php-fpm php-mysql php-cli php-curl php-gd php-mbstring php-xml php-zip unzip nginx > /dev/null 2>&1

# 获取 PHP 版本和 Socket
PHP_VER=$(php -v | head -n 1 | cut -d " " -f 2 | cut -f1-2 -d".")
PHP_SOCK="/run/php/php${PHP_VER}-fpm.sock"
echo -e "   - 检测到 PHP 版本: ${GREEN}$PHP_VER${NC}"
echo -e "   - Socket 路径: ${GREEN}$PHP_SOCK${NC}"

# 修复 PHP 权限
sed -i "s/^listen.owner.*/listen.owner = www-data/" /etc/php/${PHP_VER}/fpm/pool.d/www.conf
sed -i "s/^listen.group.*/listen.group = www-data/" /etc/php/${PHP_VER}/fpm/pool.d/www.conf
sed -i "s/^;listen.mode.*/listen.mode = 0666/" /etc/php/${PHP_VER}/fpm/pool.d/www.conf
systemctl restart php${PHP_VER}-fpm
chmod 777 $PHP_SOCK

# 3. 智能分析 Xray 端口 (核心逻辑)
echo -e "${GREEN}>>> [2/4] 自动分析 Xray 回落端口...${NC}"

# 提取所有包含 "dest": 数字 的端口号，并去重
DETECTED_PORTS=$(grep -r "dest" $XRAY_CONF_DIR | grep -oE '"dest": ?[0-9]+' | grep -oE '[0-9]+' | sort -u)

if [ -z "$DETECTED_PORTS" ]; then
    echo -e "${RED}❌ 警告: 未在 Xray 配置中检测到回落端口！${NC}"
    echo "将使用默认端口 80 生成配置，可能导致伪装失效。"
    DETECTED_PORTS="80"
fi

# 开始构建 Nginx 监听指令
LISTEN_BLOCK=""
for PORT in $DETECTED_PORTS; do
    # 排除非本地端口 (有些 dest 可能是 ip:port，这里只取纯数字端口)
    if [[ "$PORT" -gt 0 && "$PORT" -lt 65535 ]]; then
        echo -e "   - 发现回落目标端口: ${YELLOW}$PORT${NC}"
        
        # 深度检测：这个端口在 Xray 里是否开启了 xver (Proxy Protocol)
        # 只要在任何文件中，这个端口旁边有 "xver": 1，就认为是开启的
        HAS_XVER=$(grep -r "$PORT" $XRAY_CONF_DIR -A 10 -B 10 | grep '"xver":.*1')
        
        if [ -n "$HAS_XVER" ]; then
            echo -e "     -> 启用 Proxy Protocol"
            LISTEN_BLOCK+=$'\n    listen 127.0.0.1:'$PORT' proxy_protocol;'
        else
            echo -e "     -> 普通 HTTP 模式"
            LISTEN_BLOCK+=$'\n    listen 127.0.0.1:'$PORT';'
        fi
    fi
done

# 4. 生成 Nginx 伪装站配置
echo -e "${GREEN}>>> [3/4] 生成 Nginx 伪装站配置...${NC}"

cat > /etc/nginx/conf.d/00_default_nxm.conf << EOF
server {
    # --- 自动生成的监听列表 --- $LISTEN_BLOCK
    
    # 额外监听 80 (用于本地测试/ACME)
    listen 80;

    # 开启 HTTP/2 支持 (解决 ERR_HTTP2_PROTOCOL_ERROR)
    http2 on;

    server_name _;
    root /usr/share/nginx/html;
    index index.php index.html index.htm;

    # --- 核心: 获取真实 IP ---
    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;

    # --- PHP 解析 ---
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

# 修复目录权限
chown -R www-data:www-data /usr/share/nginx/html
chmod -R 755 /usr/share/nginx/html

# 5. 安装 nxm 管理命令
echo -e "${GREEN}>>> [4/4] 安装 nxm 管理工具...${NC}"

cat > /usr/local/bin/nxm << 'SCRIPT_EOF'
#!/bin/bash
# NXM Manager Tool

function show_help() {
    echo "==============================================="
    echo "NXM 管理工具 (Based on mack-a script)"
    echo "==============================================="
    echo "nxm vhost add    -> 添加新网站 (80端口, 不走Xray)"
    echo "nxm fix          -> 一键修复 PHP/520 错误"
    echo "nxm status       -> 查看服务状态"
    echo "nxm log          -> 查看 Nginx 错误日志"
    echo "==============================================="
}

function add_vhost() {
    echo ">>> 添加新网站"
    read -p "请输入域名 (如 blog.test.com): " DOMAIN
    if [ -z "$DOMAIN" ]; then echo "❌ 域名不能为空"; exit 1; fi

    WEB_ROOT="/var/www/$DOMAIN"
    echo ">>> 网站目录: $WEB_ROOT"
    
    mkdir -p $WEB_ROOT
    echo "<?php phpinfo(); ?>" > $WEB_ROOT/phpinfo.php
    chown -R www-data:www-data $WEB_ROOT
    chmod -R 755 $WEB_ROOT

    # 获取 PHP Socket
    PHP_VER=$(php -v | head -n 1 | cut -d " " -f 2 | cut -f1-2 -d".")
    PHP_SOCK="/run/php/php${PHP_VER}-fpm.sock"

    # 生成配置
    cat > /etc/nginx/conf.d/${DOMAIN}.conf << EOF
server {
    listen 80;
    server_name $DOMAIN;
    root $WEB_ROOT;
    index index.php index.html;
    
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
    nginx -t && systemctl reload nginx
    echo "✅ 网站已添加! 访问 http://$DOMAIN/phpinfo.php 测试"
    echo "💡 提示: 申请证书请手动运行: certbot --nginx -d $DOMAIN"
}

function fix_system() {
    echo ">>>正在修复权限..."
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
    "log") tail -n 20 /var/log/nginx/error.log ;;
    *) show_help ;;
esac
SCRIPT_EOF

chmod +x /usr/local/bin/nxm

# 完成
systemctl restart nginx
echo -e "${GREEN}=============================================${NC}"
echo -e "${GREEN}✅ NXM 部署完成！${NC}"
echo -e "1. 伪装站 PHP 已就绪 (自适应端口: $DETECTED_PORTS)"
echo -e "2. 管理工具已安装，请输入 ${YELLOW}nxm${NC} 查看帮助"
echo -e "${GREEN}=============================================${NC}"
