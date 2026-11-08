#!/usr/bin/env bash
set -euo pipefail

sdk=$1
pkg=$2
box=openwrt-luci-smoke
jar=$(mktemp)
response=$(mktemp)
cleanup() {
    docker rm -f "$box" >/dev/null 2>&1 || true
    rm -f "$jar" "$response"
}
trap cleanup EXIT

docker run -d --name "$box" -p 127.0.0.1:18080:80 \
    --entrypoint /bin/sh "openwrt/rootfs:$sdk" -c 'sleep 1200' >/dev/null
docker cp "$pkg" "$box:/tmp/plugin.${pkg##*.}"

docker exec -e SMOKE_HASH="$(openssl passwd -6 luci-smoke)" "$box" sh -ec '
    mkdir -p /var/lock /var/run/ubus
    if command -v apk >/dev/null; then
        apk update
        apk add luci-base luci-mod-admin-full luci-theme-bootstrap uhttpd
    else
        opkg update
        opkg install luci-base luci-mod-admin-full luci-theme-bootstrap uhttpd
    fi
    sed -i "s#^root:[^:]*:#root:${SMOKE_HASH}:#" /etc/shadow
'
docker exec -d "$box" /sbin/ubusd -s /var/run/ubus/ubus.sock
docker exec "$box" sh -ec 'for n in 1 2 3 4 5; do ubus list && exit 0; sleep 1; done; exit 1'
docker exec -d "$box" /sbin/procd -s /var/run/ubus/ubus.sock
docker exec -d "$box" /sbin/rpcd
docker exec "$box" ubus -t 15 wait_for system session
docker exec "$box" sh -ec '
    if command -v apk >/dev/null; then
        apk add --allow-untrusted /tmp/plugin.apk
    else
        opkg install /tmp/plugin.ipk
    fi
    # 确认主题在原版 LuCI 上注册并作为实际渲染模板。
    if [ -f /etc/uci-defaults/95-apollo-theme ]; then sh /etc/uci-defaults/95-apollo-theme; fi
    test "$(uci get luci.themes.Apollo)" = /luci-static/apollo
    uci set luci.main.mediaurlbase=/luci-static/apollo
    uci commit luci
'
docker exec -d "$box" /usr/sbin/uhttpd -f -p 0.0.0.0:80 -h /www -x /cgi-bin

url=http://127.0.0.1:18080/cgi-bin/luci
curl -fsS --retry 8 --retry-connrefused --retry-delay 1 "$url/" -o "$response"
grep -q 'luci_password' "$response"
curl -fsS -c "$jar" -d 'luci_username=root&luci_password=luci-smoke' "$url/" -o "$response"
curl -fsSL -b "$jar" "$url/admin/system/system" -o "$response"
grep -q 'npt-navigation' "$response"
grep -q '/luci-static/apollo/theme.css' "$response"
curl -fsS http://127.0.0.1:18080/luci-static/resources/menu-apollo.js -o /dev/null
