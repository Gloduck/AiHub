# 环境安装

+ 脚本名称[install_env.sh]：Linux 环境安装脚本，用于安装 node、maven、java、python、golang。必填参数：`--env`、`--version`、`--install-dir`。可选参数：`--arch`、`--config`、`--force`、`--no-profile`、`--verbose`。示例：`script/install_env.sh --env golang --version 1.26.2 --install-dir /opt/golang`
+ 脚本名称[install_env.bat]：Windows 环境安装脚本，用于安装 node、maven、java、python、golang。必填参数：`--env`、`--version`、`--install-dir`。可选参数：`--arch`、`--config`、`--force`、`--no-profile`。示例：`script\install_env.bat --env golang --version 1.26.2 --install-dir D:\tools\golang`
+ 脚本名称[install_playwright_cli.sh]：管理 `@playwright/cli` 的全局安装与卸载、Playwright 系统依赖安装，以及按全局或项目 scope 初始化或清理 skills 和 `.playwright/` 工作区。必填参数：子命令 `install`、`uninstall`、`install-deps`、`init` 或 `clean`。可选参数：`--scope`、`--target`、`--version`、`--project-dir`、`--verbose`。示例：`script/install_playwright_cli.sh install-deps`

# 脚本执行

+ 脚本名称[115_cli.sh]：调用 115 非 OpenAPI 的私有 Web/离线下载和文件接口，支持云下载任务添加/列表/删除/清空、登录检查、版本查询、新建目录、列目录、获取信息、搜索、删除、移动、复制、重命名、上传；默认输出人类友好文本，添加 `--json` 时输出 JSON（AI调用建议默认加上）；添加云下载任务使用网页端离线下载表单接口，上传命令需要 `python3` 或 `python` 实现 ec115/OSS 流程并支持串行 multipart。必填参数：子命令 `add`、`list`、`delete`、`clear`、`login-check`、`version`、`mkdir`、`ls`、`info`、`search`、`rm`、`mv`、`cp`、`rename` 或 `upload`，除 `version` 外需要 `--cookie` 或 `PAN115_COOKIE` 环境变量，目录参数使用绝对路径，`upload` 需要 `--dir`、`--file`；`ls`/`search` 默认 `--limit 100`。可选参数：`--dir`、`--path`、`--target-dir`、`--url`、`--keyword`、`--name`、`--page`、`--offset`、`--limit`、`--all`、`--hash`、`--delete-files`、`--flag`、`--multipart-threshold`、`--part-size`、`--json`、`--raw-response`、`--verbose`。示例：`PAN115_COOKIE="UID=...;CID=...;SEID=...;KID=..." script/115_cli.sh add --dir "/下载" --url "https://example.com/file.zip"`
+ 脚本名称[mxecy_aggregate_magnet_search-cli.sh]：调用 `tool.mxecy.cn/torrent` 对应的 mxecy 聚合磁力/种子搜索接口，支持搜索源列表、关键词搜索、详情查询、磁力链接输出；默认输出人类友好文本，添加 `--json` 输出原始接口响应；指定排序但搜索源不支持时仅输出 warning 并忽略排序参数。必填参数：子命令 `sources`、`search`、`detail` 或 `magnet`，`search` 需要 `--keyword`、`--source`，`detail` 需要 `--source`、`--id`，`magnet` 需要 `--hash` 或 `--source`、`--id`。可选参数：`--page-index`、`--page-size`、`--sort`、`--sort-field`、`--sort-order`、`--base-url`、`--json`、`--raw-response`、`--verbose`。示例：`script/mxecy_aggregate_magnet_search-cli.sh search --keyword ubuntu --source btsow --page-size 5`
+ 脚本名称[run_temp_script_with_deps.sh]：在临时目录中执行 Python 或 Node 脚本，并按需安装第三方依赖；支持使用 `--` 将后续参数原样透传给目标脚本。必填参数：子命令 `python` 或 `node`、`--script`。可选参数：`--deps`、`--dir`、`--auto-clean`、`--verbose`，以及分隔符 `--` 后的目标脚本参数。示例：`script/run_temp_script_with_deps.sh python --script ./demo.py --deps "requests" --auto-clean -- --host example.com --port 8080`
+ 脚本名称[upload_images_to_image_server.sh]：将一个或多个本地图片上传到 ImgBB 或 Postimages，并输出图片名称、`original_url`、`display_url`；添加 `--raw-response` 时输出 JSON 结构。必填参数：至少一个图片路径。可选参数：`--site`、`--expire`、`--raw-response`、`--verbose`。示例：`script/upload_images_to_image_server.sh --site imgbb --expire 1d ./demo.png`

# 环境变量

+ 脚本名称[load_env.sh]：读取 env.ini 并加载到当前 shell 环境变量，默认读取脚本同目录或者当前工作目录下的env.ini；添加 `--verbose` 时打印已加载变量的 key。可选参数：`--file`、`--verbose`。示例：`source script/load_env.sh --file ./env.ini`
+ 脚本名称[load_env.bat]：读取 env.ini 并加载到当前 cmd 环境变量，默认读取脚本同目录或者当前工作目录下的env.ini；添加 `--verbose` 时打印已加载变量的 key。可选参数：`--file`、`--verbose`。示例：`call script\load_env.bat --file .\env.ini`

# AI 请求

+ 脚本名称[request_thirdparty_ai_platform.sh]：按 OpenAI 官方或 Claude 官方请求格式调用三方 AI 接口，支持图片理解输入、OpenAI 官方图片生成、基于一个或多个本地图片的 OpenAI 官方图片编辑，以及请求 `/v1/models` 获取可用模型，并从环境变量 `THIRDPARTY_AI_PLATFORM_API_KEY`、`THIRDPARTY_AI_PLATFORM_BASE_URL`、`THIRDPARTY_AI_PLATFORM_FORMAT` 或 provider 专属变量读取配置，支持输出 AI 文本、模型 ID 列表、原始响应，或将生成图片解码到文件。必填参数：子命令 `message`、`image` 或 `models`，其中 `message` 和 `image` 需要位置参数 `PROMPT` 和 `--model`。可选参数：`--format`、`--image`、`--mask`、`--size`、`--background`、`--quality`、`--output-format`、`--image-output`、`--base-url`、`--api-key`、`--max-tokens`、`--temperature`、`--raw-response`、`--output`、`--dry-run`、`--verbose`。示例：图片理解 `script/request_thirdparty_ai_platform.sh message "请描述这张图片" --format openai --model gpt-5.4-mini --image ./logo.png`；图片生成 `script/request_thirdparty_ai_platform.sh image "生成一个极简风格的红黑企业 logo" --format openai --model gpt-image-2 --size 1024x1024 --image-output /tmp/generated.png`；图片编辑 `script/request_thirdparty_ai_platform.sh image "把背景改成深色" --format openai --model gpt-image-2 --image ./input1.png --image ./input2.png --image-output /tmp/edited.png`

# 远程执行

+ 脚本名称[remote_ssh_exec.sh]：通过 SSH 执行远程 Linux bash 命令，并实时输出结果，可在 Linux Shell 与 Git Bash 中使用。必填参数：`--host`、`--user`，以及 `--command` 或 `--command-file`，也可通过环境变量 `REMOTE_SSH_HOST`、`REMOTE_SSH_PORT`、`REMOTE_SSH_USER`、`REMOTE_SSH_PASSWORD` 提供连接参数。可选参数：`--password`、`--port`、`--accept-host-key`、`--tty`、`--verbose`。示例：`script/remote_ssh_exec.sh --command "pwd"`
+ 脚本名称[remote_ssh_transfer.sh]：通过 SSH 在本地与远程 Linux 服务器之间传输文件或目录，可在 Linux Shell 与 Git Bash 中使用。必填参数：子命令 `upload` 或 `download`、`--host`、`--user`、`--destination`，以及至少一个 `--source`，也可通过环境变量 `REMOTE_SSH_HOST`、`REMOTE_SSH_PORT`、`REMOTE_SSH_USER`、`REMOTE_SSH_PASSWORD` 提供连接参数。可选参数：`--password`、`--port`、`--accept-host-key`、`--verbose`。示例：`script/remote_ssh_transfer.sh upload --source ./dist --destination /tmp/deploy`

# 网络调优

+ 脚本名称[switch_tcp_congestion_control.sh]：切换 Linux 系统 TCP 拥塞控制算法并写入持久化配置。必填参数：`--algorithm`。可选参数：`--verbose`。示例：`sudo script/switch_tcp_congestion_control.sh --algorithm bbr`

# 打包解压

+ 脚本名称[tar_path_map.sh]：按映射规则打包或解压 tar 压缩包，并支持在同一规则文件中定义 `include(...)`、`exclude(...)` 规则，可在 Linux Shell 和 Git Bash on Windows 中使用。必填参数：子命令 `pack` 或 `unpack`、`--archive`，`pack` 还需要至少一个 `--map` 或 `--map-file`，`unpack` 需要 `--output` 或至少一个 `--map`/`--map-file`。可选参数：`--map`、`--map-file`、`--output`、`--verbose`。映射格式统一为 `archive/path|local/path`。示例：`script/tar_path_map.sh pack --archive backup.tar.gz --map code|C:\work\code`
