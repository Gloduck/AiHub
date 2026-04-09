# 环境安装

+ 脚本名称[install_env.sh]：Linux 环境安装脚本，用于安装 node、maven、java、python。必填参数：`--env`、`--version`、`--install-dir`。可选参数：`--arch`、`--config`、`--force`、`--no-profile`、`--verbose`。示例：`script/install_env.sh --env node --version 20.18.0 --install-dir /opt/node`
+ 脚本名称[install_env.bat]：Windows 环境安装脚本，用于安装 node、maven、java、python。必填参数：`--env`、`--version`、`--install-dir`。可选参数：`--arch`、`--config`、`--force`、`--no-profile`。示例：`script\install_env.bat --env node --version 20.18.0 --install-dir D:\tools\node`

# 环境变量

+ 脚本名称[load_env.sh]：读取 env.ini 并加载到当前 shell 环境变量，默认读取脚本同目录或者当前工作目录下的env.ini。可选参数：`--file`、`--verbose`。示例：`source script/load_env.sh --file ./env.ini`
+ 脚本名称[load_env.bat]：读取 env.ini 并加载到当前 cmd 环境变量，默认读取脚本同目录或者当前工作目录下的env.ini。可选参数：`--file`、`--verbose`。示例：`call script\load_env.bat --file .\env.ini`

# 远程执行

+ 脚本名称[remote_ssh_exec.py]：跨平台通过 SSH 执行远程 Linux bash 命令，并实时输出结果。必填参数：`--host`、`--user`，以及 `--command` 或 `--command-file`，也可通过环境变量 `REMOTE_SSH_HOST`、`REMOTE_SSH_PORT`、`REMOTE_SSH_USER`、`REMOTE_SSH_PASSWORD` 提供连接参数。可选参数：`--password`、`--port`、`--accept-host-key`、`--tty`、`--verbose`。密码可省略，省略时使用 ssh key 或 ssh-agent。示例：`python script/remote_ssh_exec.py --command "pwd"`

# 网络调优

+ 脚本名称[switch_tcp_congestion_control.sh]：切换 Linux 系统 TCP 拥塞控制算法并写入持久化配置。必填参数：`--algorithm`。可选参数：`--verbose`。示例：`sudo script/switch_tcp_congestion_control.sh --algorithm bbr`
