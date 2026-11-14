# 安装标准版

发布包面向 Linux x86-64。包含编译后的 Worker、DeepSeek Harness 及 Node.js 运行时、Temporal Server、渠道服务和工作台界面。准备 Python 3、独立的 MySQL 8.4 实例或专用数据库，以及可用的 DeepSeek API 密钥。飞书、微信和企微按需配置。

## 1. 校验并解包

```sh
sha256sum -c workbench-standard-linux-amd64.tar.gz.sha256
mkdir workbench-standard
tar -xzf workbench-standard-linux-amd64.tar.gz -C workbench-standard
cd workbench-standard
```

## 2. 准备持久服务

准备一个空 MySQL 数据库供工作台使用，独立创建 Temporal 的默认库和可见性库。使用包中标注的 Temporal 版本对应的官方 SQL Schema 工具初始化两个库，再配置 Temporal Server 的 MySQL 持久化。MySQL 与 Temporal 可由已有的服务管理器托管。Worker 首次启动时创建工作台业务表。启动 Worker 前，使用官方 Temporal CLI 在已运行的 Temporal 服务中创建工作台命名空间。

- [Temporal 自托管部署](https://docs.temporal.io/self-hosted-guide/deployment)
- [Temporal CLI 安装](https://docs.temporal.io/cli)
- [Temporal SQL Schema 工具](https://github.com/temporalio/temporal/tree/v1.32.2/tools/sql)

```sh
temporal operator namespace create --address 127.0.0.1:7233 --namespace workbench --retention 168h
temporal operator namespace describe --address 127.0.0.1:7233 --namespace workbench
```

请按实际部署地址和命名空间修改上述参数，并在下一节使用相同的值。

## 3. 启动工作台

建议使用普通专用服务账号。将以下变量设置在服务账号的私有环境中，将示例地址和数据库连接串替换为本机配置。

```sh
export WORKBENCH_HOST_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
export WORKBENCH_CONNECTOR_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
export DSH_HOME="$PWD/data/harness"
export WORKBENCH_PERSONAL_WORKSPACE="$PWD/data/today"
export WORKBENCH_VAULT_ROOT="$PWD/data/vaults"
export WORKBENCH_CHANNEL_LINK_DIR="$PWD/data/channels"
export WORKBENCH_CHANNEL_CONFIG="$PWD/data/channels.json"
export WORKBENCH_RESOURCE_ACL_EDIT=1
export WORKBENCH_MYSQL_DSN='workbench:REPLACE_ME@tcp(127.0.0.1:3306)/workbench'
export TEMPORAL_ADDRESS='127.0.0.1:7233'
export TEMPORAL_NAMESPACE='workbench'
export WORKBENCH_PUBLIC_HOST='127.0.0.1'
export DSH_BUNDLED_SKILL_DIR="$PWD/skills"
export PATH="$PWD/node/bin:$PATH"
umask 077
mkdir -p "$DSH_HOME" "$WORKBENCH_PERSONAL_WORKSPACE" "$WORKBENCH_VAULT_ROOT" "$WORKBENCH_CHANNEL_LINK_DIR"
ln -sfn "$PWD/runtime/node_modules" "$DSH_HOME/node_modules"
test -e "$WORKBENCH_CHANNEL_CONFIG" || printf '[]\n' > "$WORKBENCH_CHANNEL_CONFIG"
```

Harness 从自己的配置目录加载工作台插件，`node_modules` 链接指向当前解包目录。切换到新版本时，同步更新这个链接。将私有环境持久保存并由以下三个服务共用。先启动 Worker，确认 `curl -fsS http://127.0.0.1:7381/health` 返回 `ready: true`，然后启动 Harness，最后按需启动渠道服务。以下三条命令各自持续运行，可由 systemd 等服务管理器启动。

```sh
bin/workbench-worker
node runtime/node_modules/@deepseek-ai/dsh/lib/bin.js web --patch "$PWD/runtime/harness/cordis.patch.yml" --no-open --host 127.0.0.1 --port 3082
node runtime/connectors/server.mjs
```

在浏览器打开 Harness 启动时输出的本人访问链接，在模型设置里填写并验证自己的 DeepSeek 密钥。远程部署可通过 SSH 转发 3082 访问。为公网域名自行配置 HTTPS 反向代理，并将 `WORKBENCH_PUBLIC_HOST` 设置成该域名。应用的 Worker、Harness bridge、渠道和数据库端口应保持在私有网络。

`data/`、MySQL 数据和私有环境应单独保存。升级时使用新目录解包，并让新服务继续使用原持久路径。知识库、专家包、自动应答和渠道操作见包内 `docs/`。
