<div align="center">

<h1 align="center">NaiveProxy Server</h1>

[English](README.md) / 简体中文

[Caddy](https://github.com/caddyserver/caddy) with [forward proxy](https://github.com/klzgrad/forwardproxy/tree/naive)

<p>
<a href="https://www.gnu.org/licenses/gpl-3.0.html"><img src="https://img.shields.io/github/license/jonssonyan/naive" alt="License: GPL-3.0"></a>
<a href="https://github.com/jonssonyan/naive/stargazers"><img src="https://img.shields.io/github/stars/jonssonyan/naive" alt="GitHub stars"></a>
<a href="https://github.com/jonssonyan/naive/forks"><img src="https://img.shields.io/github/forks/jonssonyan/naive" alt="GitHub forks"></a>
<a href="https://github.com/jonssonyan/naive/releases"><img src="https://img.shields.io/github/v/release/jonssonyan/naive" alt="GitHub release"></a>
</p>

</div>

## 主要功能

1. 极简部署（安装仅需绑定域名）
2. 全局快捷管理命令 `nv`
3. 多端口节点管理与一键新增（随机5位数端口、5位字母用户名、5位数字密码）
4. 单端口多用户支持（已有端口最多容纳20个节点）
5. 流量到期自动换算（标准档位 50G=1月, 150G=3月, 300G=半年, 600G=1年；非标流量自定义日期如 27.5.3）
6. 硬件级流量统计（基于 iptables/nftables 统计各端口进出流量）
7. 节点修改与维护（解析节点链接一键删除、改时间、改流量）
8. 域名动态换绑（自动 ACME 申请或本地域名证书）
9. 数据备份与还原（备份至 `/root/nvback`）

## 建议系统

系统: CentOS 8+/Ubuntu 20+/Debian 11+

CPU: x86_64/amd64 arm64/aarch64

内存: ≥ 128MB

## 部署

### 快速安装 (推荐)

安装最新版 (仅需绑定域名，自动生成 `nv` 快捷命令):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/jonssonyan/naive/main/install.sh)
```

安装[自定义版本](https://github.com/jonssonyan/naive/releases)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/jonssonyan/naive/main/install.sh) v2.7.6
```

## 管理面板 (nv)

安装完成后，在终端任意位置输入 `nv` 即可打开可视化交互管理面板：

```text
==============================================================
                   NaiveProxy 管理系统 (nv)
==============================================================
 1、服务器控制 (暂停/重启/状态查看)
 2、新增用户 (一键随机/手动端口/单端口多用户/修改节点)
 3、显示所有用户流量 (端口消耗总计/多用户标记/下钻查看节点)
 4、绑定域名 (换绑新域名/指定本地域名证书)
 5、程序管理 (备份数据到 /root/nvback / 还原历史备份)
 0、退出菜单
==============================================================
```


### systemd

下载可执行文件: https://github.com/jonssonyan/naive/releases

新建配置文件 naive.json, 示例: [naive.json](naive.json)

```bash
mkdir -p /usr/local/naive/
curl -fsSL https://github.com/jonssonyan/naive/releases/latest/download/naive-linux-amd64 -o /usr/local/naive/naive && chmod +x /usr/local/naive/naive
curl -fsSL https://raw.githubusercontent.com/jonssonyan/naive/main/naive.service -o /etc/systemd/system/naive.service
sed -i "s|^ExecStart=.*|ExecStart=/usr/local/naive/naive run --config naive.json|" "/etc/systemd/system/naive.service"
systemctl daemon-reload
systemctl enable naive
systemctl restart naive
```

卸载

```bash
systemctl stop naive
rm -rf /etc/systemd/system/naive.service /usr/local/naive/
```

### 容器部署

1. 安装 Docker

   https://docs.docker.com/engine/install/

   ```bash
   bash <(curl -fsSL https://get.docker.com)
   ```

2. 启动容器

   新建配置文件 naive.json, 示例: [naive.json](naive.json)

   ```bash
   docker pull jonssonyan/naive

   docker run -d \
     --name naive --restart always \
     --network=host \
     -v /naive/html/:/naive/html/ \
     -v /naive/config/:/naive/config/ \
     jonssonyan/naive \
     ./naive run --config /naive/naive.json
   ```

卸载

```bash
docker rm -f naive
docker rmi jonssonyan/naive
rm -rf /naive
```

## 性能优化

- https://github.com/klzgrad/naiveproxy/wiki/Performance-Tuning

- 定时重启服务器

    ```bash
    0 4 * * * /sbin/reboot
    ```

- 安装网络加速
    - [TCP Brutal](https://github.com/apernet/tcp-brutal) (推荐)
    - [teddysun/across#bbrsh](https://github.com/teddysun/across#bbrsh)
    - [Chikage0o0/Linux-NetSpeed](https://github.com/ylx2016/Linux-NetSpeed)
    - [ylx2016/Linux-NetSpeed](https://github.com/ylx2016/Linux-NetSpeed)

## 构建

- 编译最新版

  Windows: [build.bat](build.bat)

  Linux: [build.sh](build.sh)

- 编译历史版本

  [klzgrad/forwardproxy](https://github.com/klzgrad/forwardproxy)
  和 [caddyserver/caddy](https://github.com/caddyserver/caddy)
  版本之间存在兼容关系，可以在[这里](https://github.com/klzgrad/forwardproxy/blob/b12c33ecb72c78f652b88e697cf8eec4a8cb6373/go.mod#L6)
  查看 klzgrad/forwardproxy 支持最低的 caddyserver/caddy 版本。[quic-go/quic-go](https://github.com/quic-go/quic-go)
  的版本可以在[这里](https://github.com/caddyserver/caddy/blob/21f9c20a04ec5c2ac430daa8e4ba8fbdef67f773/go.mod#L22)查看。

  在 https://github.com/klzgrad/naiveproxy/releases 下载指定版本
  Source code 到本地，例如将Source code 解压至 naive 文件夹内。

  例如：编译 v2.7.x

  ```bash
  CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  xcaddy build v2.7.0 --output build/naive-linux-amd64 \
  --with github.com/caddyserver/forwardproxy=./naive \
  --replace github.com/quic-go/quic-go=github.com/quic-go/quic-go@v0.40.0
  ```

  需要注意 [golang/go](https://github.com/golang/go) klzgrad/forwardproxy quic-go/quic-go 的版本

## 其他

Telegram Channel: https://t.me/jonssonyan_channel

你可以在 YouTube 上订阅我的频道: https://www.youtube.com/@jonssonyan

如果这个项目对你有帮助，你可以请我喝杯咖啡:

<img src="https://github.com/jonssonyan/install-script/assets/46235235/cce90c48-27d3-492c-af3e-468b656bdd06" width="150" alt="微信赞赏码" title="微信赞赏码"/>

## 开源协议

[GPL-3.0](LICENSE)