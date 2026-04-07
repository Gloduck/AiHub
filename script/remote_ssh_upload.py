#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from _lib.common import debug, error, from_cwd, info, setup_logging
from remote_ssh_exec import (
    HOST_ENV,
    PASSWORD_ENV,
    PORT_ENV,
    USER_ENV,
    build_ssh_options,
    create_askpass_script,
    get_port_default,
    print_password,
)


DESCRIPTION = "Upload local files or directories to a remote Linux server over SSH."


EPILOG = """Required inputs:
  --host, --user, --destination, and at least one --source

Behavior:
  Repeated --source flags are uploaded in order.
  Sources can be files or directories.
  The remote destination directory is created automatically when missing.
  All sources are copied into the destination directory and keep their local basenames.
  If --password and REMOTE_SSH_PASSWORD are both omitted, ssh key or ssh-agent authentication is used.

Requirements:
  Requires local Python, local ssh client, and local scp client.
  No interactive prompts are used.

Environment variables:
  REMOTE_SSH_HOST
  REMOTE_SSH_PORT
  REMOTE_SSH_USER
  REMOTE_SSH_PASSWORD
"""


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=DESCRIPTION,
        epilog=EPILOG,
        formatter_class=argparse.RawTextHelpFormatter,
    )
    parser.add_argument(
        "--host",
        required=HOST_ENV not in os.environ,
        default=os.environ.get(HOST_ENV),
        help=f"Target Linux server address. Fallback env: {HOST_ENV}.",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=get_port_default(),
        help=f"SSH port. Default: 22. Fallback env: {PORT_ENV}.",
    )
    parser.add_argument(
        "--user",
        required=USER_ENV not in os.environ,
        default=os.environ.get(USER_ENV),
        help=f"SSH username. Fallback env: {USER_ENV}.",
    )
    parser.add_argument(
        "--password",
        default=os.environ.get(PASSWORD_ENV),
        help=f"SSH password. Optional when using ssh key auth. Fallback env: {PASSWORD_ENV}.",
    )
    parser.add_argument(
        "--source",
        action="append",
        default=[],
        help="Local file or directory to upload. Can be provided multiple times.",
    )
    parser.add_argument(
        "--destination",
        required=True,
        help="Remote destination directory. Created automatically if missing.",
    )
    parser.add_argument(
        "--accept-host-key",
        action="store_true",
        help="Set StrictHostKeyChecking=accept-new.",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Print debug logs.",
    )
    return parser


def collect_sources(args: argparse.Namespace) -> list[Path]:
    if not args.source:
        raise SystemExit("[ERROR] at least one --source is required")

    sources: list[Path] = []
    for raw_path in args.source:
        path = from_cwd(raw_path)
        if not path.exists():
            raise SystemExit(f"[ERROR] source not found: {path}")
        sources.append(path)

    return sources


def build_remote_mkdir_command(args: argparse.Namespace) -> list[str]:
    remote_script = 'mkdir -p -- "$1"'
    remote_command = f"bash -lc {shlex.quote(remote_script)} bash {shlex.quote(args.destination)}"
    return [
        "ssh",
        "-p",
        str(args.port),
        *build_ssh_options(args.password, args.accept_host_key),
        f"{args.user}@{args.host}",
        remote_command,
    ]


def build_scp_command(args: argparse.Namespace, sources: list[Path]) -> list[str]:
    return [
        "scp",
        "-r",
        "-P",
        str(args.port),
        *build_ssh_options(args.password, args.accept_host_key),
        *(str(path) for path in sources),
        f"{args.user}@{args.host}:{args.destination}",
    ]


def run_command(command: list[str], env: dict[str, str], missing_name: str) -> int:
    try:
        completed = subprocess.run(command, env=env, stdin=subprocess.DEVNULL)
    except FileNotFoundError:
        error(f"missing command: {missing_name}")
        return 1
    except OSError as exc:
        error(f"failed to start {missing_name}: {exc}")
        return 1

    return completed.returncode


def run(args: argparse.Namespace) -> int:
    setup_logging("DEBUG" if args.verbose else "INFO")

    sources = collect_sources(args)

    with tempfile.TemporaryDirectory(prefix="remote-upload-") as temp_dir_str:
        env = os.environ.copy()

        if args.password:
            temp_dir = Path(temp_dir_str)
            askpass_path = create_askpass_script(temp_dir, Path(__file__).resolve())
            env[PASSWORD_ENV] = args.password
            env["SSH_ASKPASS"] = str(askpass_path)
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env.setdefault("DISPLAY", "remote-upload")

        mkdir_command = build_remote_mkdir_command(args)
        scp_command = build_scp_command(args, sources)

        info(f"connecting to {args.user}@{args.host}:{args.port}")
        info(f"uploading {len(sources)} source(s) to {args.destination}")
        debug(f"mkdir command: {mkdir_command}")
        debug(f"scp command: {scp_command}")

        mkdir_exit_code = run_command(mkdir_command, env, "ssh")
        if mkdir_exit_code != 0:
            return mkdir_exit_code

        return run_command(scp_command, env, "scp")


def main() -> int:
    if len(sys.argv) == 2 and sys.argv[1] == "--print-password":
        return print_password()

    parser = build_parser()
    args = parser.parse_args()
    return run(args)


if __name__ == "__main__":
    raise SystemExit(main())
