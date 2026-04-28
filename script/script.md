# 环境安装

+ 脚本名称[install_env.sh]：Linux 环境安装脚本，用于安装 node、maven、java、python、golang。必填参数：`--env`、`--version`、`--install-dir`。可选参数：`--arch`、`--config`、`--force`、`--no-profile`、`--verbose`。示例：`script/install_env.sh --env golang --version 1.26.2 --install-dir /opt/golang`
+ 脚本名称[install_env.bat]：Windows 环境安装脚本，用于安装 node、maven、java、python、golang。必填参数：`--env`、`--version`、`--install-dir`。可选参数：`--arch`、`--config`、`--force`、`--no-profile`。示例：`script\install_env.bat --env golang --version 1.26.2 --install-dir D:\tools\golang`
+ 脚本名称[install_playwright_cli.sh]：管理 `@playwright/cli` 的全局安装与卸载、Playwright 系统依赖安装，以及按全局或项目 scope 初始化或清理 skills 和 `.playwright/` 工作区。必填参数：子命令 `install`、`uninstall`、`install-deps`、`init` 或 `clean`。可选参数：`--scope`、`--target`、`--version`、`--project-dir`、`--verbose`。示例：`script/install_playwright_cli.sh install-deps`

# 环境变量

+ 脚本名称[load_env.sh]：读取 env.ini 并加载到当前 shell 环境变量，默认读取脚本同目录或者当前工作目录下的env.ini，加载后打印已加载变量的 key。可选参数：`--file`、`--verbose`。示例：`source script/load_env.sh --file ./env.ini`
+ 脚本名称[load_env.bat]：读取 env.ini 并加载到当前 cmd 环境变量，默认读取脚本同目录或者当前工作目录下的env.ini，加载后打印已加载变量的 key。可选参数：`--file`、`--verbose`。示例：`call script\load_env.bat --file .\env.ini`

# AI 请求

+ 脚本名称[request_thirdparty_ai_platform.sh]：按 OpenAI 官方或 Claude 官方请求格式调用三方 AI 接口，支持图片输入，也支持请求 `/v1/models` 获取可用模型，并从环境变量 `THIRDPARTY_AI_PLATFORM_API_KEY`、`THIRDPARTY_AI_PLATFORM_BASE_URL`、`THIRDPARTY_AI_PLATFORM_FORMAT` 或 provider 专属变量读取配置，支持输出 AI 文本、模型 ID 列表或原始响应。必填参数：子命令 `message` 或 `models`，其中 `message` 需要位置参数 `PROMPT` 和 `--model`。可选参数：`--format`、`--image`、`--base-url`、`--api-key`、`--max-tokens`、`--temperature`、`--raw-response`、`--output`、`--dry-run`、`--verbose`。示例：`script/request_thirdparty_ai_platform.sh message "你好" --model gpt-5.4-mini`

# 远程执行

+ 脚本名称[remote_ssh_exec.sh]：通过 SSH 执行远程 Linux bash 命令，并实时输出结果，可在 Linux Shell 与 Git Bash 中使用。必填参数：`--host`、`--user`，以及 `--command` 或 `--command-file`，也可通过环境变量 `REMOTE_SSH_HOST`、`REMOTE_SSH_PORT`、`REMOTE_SSH_USER`、`REMOTE_SSH_PASSWORD` 提供连接参数。可选参数：`--password`、`--port`、`--accept-host-key`、`--tty`、`--verbose`。示例：`script/remote_ssh_exec.sh --command "pwd"`
+ 脚本名称[remote_ssh_transfer.sh]：通过 SSH 在本地与远程 Linux 服务器之间传输文件或目录，可在 Linux Shell 与 Git Bash 中使用。必填参数：子命令 `upload` 或 `download`、`--host`、`--user`、`--destination`，以及至少一个 `--source`，也可通过环境变量 `REMOTE_SSH_HOST`、`REMOTE_SSH_PORT`、`REMOTE_SSH_USER`、`REMOTE_SSH_PASSWORD` 提供连接参数。可选参数：`--password`、`--port`、`--accept-host-key`、`--verbose`。示例：`script/remote_ssh_transfer.sh upload --source ./dist --destination /tmp/deploy`

# 网络调优

+ 脚本名称[switch_tcp_congestion_control.sh]：切换 Linux 系统 TCP 拥塞控制算法并写入持久化配置。必填参数：`--algorithm`。可选参数：`--verbose`。示例：`sudo script/switch_tcp_congestion_control.sh --algorithm bbr`

# 打包解压

+ 脚本名称[tar_path_map.sh]：按映射规则打包或解压 tar 压缩包，并支持在同一规则文件中定义 `include(...)`、`exclude(...)` 规则，可在 Linux Shell 和 Git Bash on Windows 中使用。必填参数：子命令 `pack` 或 `unpack`、`--archive`，`pack` 还需要至少一个 `--map` 或 `--map-file`，`unpack` 需要 `--output` 或至少一个 `--map`/`--map-file`。可选参数：`--map`、`--map-file`、`--output`、`--verbose`。映射格式统一为 `archive/path|local/path`。示例：`script/tar_path_map.sh pack --archive backup.tar.gz --map code|C:\work\code`
