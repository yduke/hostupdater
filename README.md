# Host Updater - OpenWrt hosts 订阅源管理器

Host Updater 用于管理多个 hosts 订阅源，定时或手动下载、解析并合并内容，然后以
dnsmasq `addnhosts` 文件的形式发布。它不会修改 `/etc/hosts`，因此系统自带解析记录
始终优先，也不会在卸载或升级时破坏系统 hosts。

## 功能

- 多订阅源管理，支持启用/禁用、单独更新和删除。
- 源按配置文件中的顺序合并，同一个主机名只保留第一次出现的记录。
- 每个源保留最近一次成功下载的缓存；下载失败时自动沿用缓存，避免解析记录突然消失。
- 生成文件默认位于 `/etc/hostupdater/hosts`，并登记到 dnsmasq `addnhosts`。
- 提供 LuCI 页面和命令行工具，支持状态、日志、生成文件查看和手动更新。
- 支持 IPv4、IPv6、CRLF、行内注释和重复主机名。
- 1.1.0-r3 及以后版本升级时保留源配置、缓存和生成文件；卸载时清理 addnhosts 登记和生成数据。
- 目标路径有安全校验，必须位于 `/etc/hostupdater/` 下，拒绝 `/etc/hosts`、相对路径、`..` 和空白字符。

## 安装

### 使用预编译 IPK

```sh
opkg update
opkg install /tmp/hostupdater_1.1.0-r8_all.ipk
```

依赖：`curl`、`ca-bundle`、`luci-base`、`luci-compat`。

### 从 OpenWrt SDK 编译

```sh
# 将本仓库放到 SDK 的 package/utils/hostupdater
make menuconfig     # Utilities -> hostupdater
make package/hostupdater/compile V=s
```

### 本地快速构建 IPK

不依赖 OpenWrt SDK，直接生成可安装的 IPK：

```sh
python tools/build-ipk.py
ls output/
```

## 配置

- UCI 配置：`/etc/config/hostupdater`
- 订阅源：`/etc/hostupdater/sources.conf`
- 生成文件：`/etc/hostupdater/hosts`（可在 UCI 中修改 `target`）
- 缓存：`/etc/hostupdater/cache/<源名>.hosts`
- 日志：`/var/log/hostupdater.log`

### UCI 选项

```sh
uci set hostupdater.main.enabled='1'          # 是否启用
uci set hostupdater.main.interval='24'        # 更新间隔（1-168 小时）
uci set hostupdater.main.target='/etc/hostupdater/hosts'  # 必须在 /etc/hostupdater/ 下
uci set hostupdater.main.manage_addnhosts='1' # 自动维护 dnsmasq addnhosts
uci set hostupdater.main.keep_backups='1'     # 写入前保留上一版目标文件
uci set hostupdater.main.log_max_kb='512'     # 日志轮转阈值
uci commit hostupdater
/etc/init.d/hostupdater restart
```

### 订阅源格式

每行一个源：

```
名称|URL|启用状态
```

示例：

```
github|https://hosts.gitcdn.top/hosts.txt|1
tmdb_ipv4|https://raw.githubusercontent.com/cnwikee/CheckTMDB/refs/heads/main/Tmdb_host_ipv4|0
```

- 名称只能包含字母、数字、下划线、点和短横线，最长 64 个字符。
- `1` 表示启用，`0` 表示禁用。
- 从上到下即优先级；同一个主机名在多个源中出现时，先出现的生效。
- 以 `#` 开头的行会被忽略。
- 支持任意纯文本 hosts 内容，包括 IPv4、IPv6、CRLF 和行内注释。

修改后执行：

```sh
/usr/bin/hostupdater update
```

## 使用

### LuCI

登录 LuCI，进入 **服务 -> Host Updater**。页面提供：

- 服务开关、更新间隔、目标文件路径；
- 源的添加、启用/禁用、单源更新、删除；
- 全量更新、状态轮询、日志查看、生成文件查看；
- 恢复默认（停止使用订阅源并清理生成文件）。

### 命令行

```sh
hostupdater update                 # 更新全部启用的源
hostupdater update-source github   # 只更新一个源
hostupdater status                 # 人类可读状态
hostupdater status --json          # JSON 状态（供 LuCI 使用）
hostupdater backup                 # 备份当前生成文件
hostupdater migrate                # 迁移/初始化，登记 addnhosts
hostupdater restore                # 停用服务并清理生成文件
hostupdater daemon                 # 前台运行调度循环
```

服务管理：

```sh
/etc/init.d/hostupdater enable
/etc/init.d/hostupdater start
/etc/init.d/hostupdater restart
/etc/init.d/hostupdater status
```

## dnsmasq 集成

软件包会把生成文件加入 `dhcp.@dnsmasq[0].addnhosts`，并通知 dnsmasq 重新加载。
不会覆盖 `/etc/hosts`，也不会改动其他已有的 addnhosts 条目。

查看登记：

```sh
uci show dhcp.@dnsmasq[0].addnhosts
```

如果关闭 `manage_addnhosts`，需要自行把生成文件加入 dnsmasq 配置。

## 文件结构

```
/etc/config/hostupdater              UCI 配置
/etc/hostupdater/sources.conf       订阅源配置
/etc/hostupdater/hosts              生成的 hosts 文件
/etc/hostupdater/cache/             每个源最近一次成功缓存
/etc/hostupdater/backup/hosts.prev  上一版生成文件
/usr/bin/hostupdater                主程序
/etc/init.d/hostupdater             procd 服务脚本
/usr/lib/lua/luci/controller/hostupdater.lua
/usr/lib/lua/luci/view/admin/services/hostupdater.htm
/usr/lib/lua/luci/i18n/hostupdater.zh-cn.lmo
/var/log/hostupdater.log            日志
```

## 构建与测试

运行 shell 单元测试（Git Bash / Linux 均可）：

```sh
bash tests/run-tests.sh
```

当前覆盖解析、CRLF、重复优先级、缓存回退、单源更新、HTML 错误页拒绝、无源、
目标路径安全和 addnhosts 清理，共 39 项。

翻译维护：

```sh
python tools/update-po.py          # 从模板提取字符串，更新 POT/PO
python tools/build-lmo.py          # 生成并校验 zh-cn LMO
```

使用 Docker/SDK 构建：

```sh
./build.sh          # 24.10 IPK
./build.sh apk      # SNAPSHOT APK（自动解析当前 SDK）
./test.sh           # 多版本 SDK 构建测试
```

### GitHub Actions 自动发布

推送 `main`/`master` 分支或 `v*` 标签，或手动运行 `Release packages` workflow，会：

1. 分别用 OpenWrt 24.10 SDK 和 SNAPSHOT SDK 编译 IPK、APK；
2. 校验 tag（如果本次是 tag 推送）与 `Makefile` 中的 `PKG_VERSION`、`PKG_RELEASE` 一致；
3. 创建或更新对应版本 Release，并上传两个安装包及 `sha256sums.txt`。

SNAPSHOT SDK 默认从 `downloads.openwrt.org` 的 `x86/64` 目标自动解析；也可通过
`SNAPSHOT_SDK_URL` 固定 SDK，或用 `SNAPSHOT_TARGET` 指定其他目标。

## 故障排除

**更新后 DNS 没有变化**

```sh
/usr/bin/hostupdater status --json
uci show dhcp.@dnsmasq[0].addnhosts
tail -n 50 /var/log/hostupdater.log
/etc/init.d/dnsmasq reload
```

确认 `target` 文件存在、`addnhosts` 已登记，并且源确实抓取到了有效记录。

**源下载失败**

每个源保留最近一次成功缓存。即使网络暂时失败，生成文件也不会被清空。查看日志中的
`stale` 或 `fail` 状态；如果从未成功过，该源不会产生记录。

**LuCI 页面 403**

确认已安装 `luci-compat`，并重新登录 LuCI（升级后 rpcd 会话会重建）。ACL 组名为
`luci-app-hostupdater`。必要时重启：

```sh
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
```

## 卸载

```sh
opkg remove hostupdater
```

卸载时会停止并禁用服务、移除指向 `/etc/hostupdater/` 的 addnhosts 条目，并删除
`/etc/hostupdater` 与 UCI 配置。不会修改 `/etc/hosts`。

## 升级说明

从 1.0.x 升级时，旧版本使用 `/etc/hosts` 重写模式，且旧包的卸载脚本可能在升级过程中
删除 `/etc/hostupdater`。升级前务必备份源配置：

```sh
cp /etc/hostupdater/sources.conf /tmp/sources.conf.bak
cp /etc/hostupdater/hosts /tmp/hosts.bak 2>/dev/null || true
```

升级到 1.1.0 后执行一次 `hostupdater update` 重建生成文件。1.1.0-r3 及以后版本的
升级会保留源配置、缓存和生成文件，不再需要手动恢复。

## 许可证

MIT，详见 [LICENSE](LICENSE)。

## 更新日志

### 1.1.0

- 改为 dnsmasq `addnhosts` 发布，彻底停止修改 `/etc/hosts`。
- 每个源独立缓存，下载失败时沿用最近成功内容。
- 重写 LuCI 页面和控制器，支持状态轮询、源管理、日志和生成文件查看。
- 新增 `luci-app-hostupdater` ACL、中文 LMO 和自定义图标。
- 目标路径安全校验，仅允许 `/etc/hostupdater/` 下的文件。
- 自动清理目标切换后遗留的 addnhosts 条目。
- 升级保留源配置、缓存和生成文件；卸载时安全清理。
- 新增 39 项 shell 单元测试、IPK 构建脚本和翻译工具。

### 1.0.0

- 初始版本：多源管理、定时/手动更新、Web 界面、备份还原。
