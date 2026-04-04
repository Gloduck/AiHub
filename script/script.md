# 环境安装

+ 脚本名称[install_env.sh]：Linux 环境安装脚本，用于安装 node、maven、java、python。必填参数：`--env`、`--version`、`--install-dir`。可选参数：`--arch`、`--config`、`--force`、`--no-profile`、`--verbose`
+ 脚本名称[install_env.bat]：Windows 环境安装脚本，用于安装 node、maven、java、python。必填参数：`--env`、`--version`、`--install-dir`。可选参数：`--arch`、`--config`、`--force`、`--no-profile`

# 环境变量

+ 脚本名称[load_env.sh]：读取 env.ini 并加载到当前 shell 环境变量。可选参数：`--file`、`--verbose`
+ 脚本名称[load_env.bat]：读取 env.ini 并加载到当前 cmd 环境变量。可选参数：`--file`、`--verbose`

# 远程执行

+ 脚本名称[remote_ssh_exec.py]：跨平台通过 SSH 执行远程 Linux bash 命令，并实时输出结果。必填参数：`--host`、`--user`、`--password`，以及 `--command` 或 `--command-file`。可选参数：`--port`、`--accept-host-key`、`--tty`、`--verbose`
