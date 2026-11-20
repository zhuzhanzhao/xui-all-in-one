# xui-all-in-one

面向个人服务器的 3x-ui 菜单式安装和入站创建脚本。

## 功能

- 安装或接管官方 MHSanaei/3x-ui
- 创建 VMess TCP 入站
- 创建 VLESS REALITY 入站
- 创建 Mixed（SOCKS5/HTTP）入站
- 创建 Tunnel（dokodemo-door）端口中转
- 检查服务状态、端口占用和中转目标连通性

## 一键运行

使用 root 登录 Ubuntu、Debian、CentOS 或 RHEL 服务器，然后执行：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/zhuzhanzhao/xui-all-in-one/main/xui-all-in-one.sh)
```

脚本运行后按菜单数字选择功能。同一台服务器不需要反复上传脚本，每次重新执行上面的命令即可。

## 两台服务器的建议顺序

菲律宾落地机：

1. 选择 `1` 安装或接管 3x-ui。
2. 选择 `4` 创建 SOCKS5。

香港中转机：

1. 选择 `1` 安装或接管 3x-ui。
2. 选择 `5` 创建 Tunnel。
3. 将目标填写为菲律宾落地机的 IP 和 SOCKS5 端口。

## 重要限制

- 云厂商安全组无法由服务器脚本自动修改，仍需在云服务器网站放行面板和节点端口。
- Tunnel 是裸端口转发，不会加密中转机与落地机之间的流量。
- 面板采用 HTTP 根路径以简化访问。请使用强密码，并限制面板端口的来源 IP。
- VMess 选项是最简 TCP 配置；需要更强的传输安全时优先使用 VLESS REALITY。
- 脚本把生成的客户端配置保存到 `/root/3x-ui-profiles/`。
- 面板账号密码保存在 `/root/.xui-all-in-one.env`，权限为仅 root 可读。

## 来源

3x-ui 官方项目：<https://github.com/MHSanaei/3x-ui>

仅用于个人服务器和合法用途。
