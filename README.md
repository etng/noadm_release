# noadm

noadm 是 HLS 广告注入工具：把广告按规则插入已有的 HLS 视频流，输出可独立播放的带广告切片，
支持批量处理（`-all`）与常驻服务（`-watch`）。本仓库发布各平台二进制与安装脚本 `install.sh`，
每个版本附 `sha256sums.txt`（安装脚本强制校验），最新版本信息见 `latest.json`。

## 安装

```sh
# curl
curl -fsSL https://raw.githubusercontent.com/etng/noadm_release/main/install.sh | sudo bash -s -- http://<noadc 主机>:8090

# wget
wget -qO- https://raw.githubusercontent.com/etng/noadm_release/main/install.sh | sudo bash -s -- http://<noadc 主机>:8090
```

唯一的位置参数是 noadc 广告中心地址（其余信息从本机自动探测）。**必须写 `bash -s --`**——
`bash - 参数` 会把参数当成脚本文件名执行。先看将做什么可加 `--dry-run`，其余选项见 `--help`。
