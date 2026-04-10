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


DESCRIPTION = "Transfer files or directories between local and remote Linux hosts over SSH."


EPILOG = """Required inputs:
  upload|download, --host, --user, --destination, and at least one --source

Behavior:
  Repeated --source flags are transferred in order.
  Sources can be files or directories.
  For upload, local sources are copied into the remote destination directory.
  For download, remote sources are copied into the local destination directory.
  The destination directory is created automatically when missing.
  Transferred sources keep their source basenames.
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


def add_common_arguments(parser: argparse.ArgumentParser) -> None:
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
        help="Source file or directory. Can be provided multiple times.",
    )
    parser.add_argument(
        "--destination",
        required=True,
        help="Destination directory. Created automatically if missing.",
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


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=DESCRIPTION,
        epilog=EPILOG,
        formatter_class=argparse.RawTextHelpFormatter,
    )
    subparsers = parser.add_subparsers(dest="direction", required=True)

    upload_parser = subparsers.add_parser(
        "upload",
        help="Upload local sources to the remote destination directory.",
    )
    add_common_arguments(upload_parser)

    download_parser = subparsers.add_parser(
        "download",
        help="Download remote sources to the local destination directory.",
    )
    add_common_arguments(download_parser)

    return parser


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


def collect_upload_sources(args: argparse.Namespace) -> list[Path]:
    if not args.source:
        raise SystemExit("[ERROR] at least one --source is required")

    sources: list[Path] = []
    for raw_path in args.source:
        path = from_cwd(raw_path)
        if not path.exists():
            raise SystemExit(f"[ERROR] source not found: {path}")
        sources.append(path)

    return sources


def collect_download_sources(args: argparse.Namespace) -> list[str]:
    if not args.source:
        raise SystemExit("[ERROR] at least one --source is required")
    return list(args.source)


def collect_local_destination(args: argparse.Namespace) -> Path:
    destination = from_cwd(args.destination)
    destination.mkdir(parents=True, exist_ok=True)

    if not destination.is_dir():
        raise SystemExit(f"[ERROR] destination is not a directory: {destination}")

    return destination


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


def build_upload_scp_command(args: argparse.Namespace, sources: list[Path]) -> list[str]:
    return [
        "scp",
        "-r",
        "-P",
        str(args.port),
        *build_ssh_options(args.password, args.accept_host_key),
        *(str(path) for path in sources),
        f"{args.user}@{args.host}:{args.destination}",
    ]


def build_download_scp_command(args: argparse.Namespace, sources: list[str], destination: Path) -> list[str]:
    return [
        "scp",
        "-r",
        "-P",
        str(args.port),
        *build_ssh_options(args.password, args.accept_host_key),
        *(f"{args.user}@{args.host}:{shlex.quote(source)}" for source in sources),
        str(destination),
    ]


def build_env(args: argparse.Namespace, temp_dir_str: str) -> dict[str, str]:
    env = os.environ.copy()

    if not args.password:
        return env

    temp_dir = Path(temp_dir_str)
    askpass_path = create_askpass_script(temp_dir, Path(__file__).resolve())
    env[PASSWORD_ENV] = args.password
    env["SSH_ASKPASS"] = str(askpass_path)
    env["SSH_ASKPASS_REQUIRE"] = "force"
    env.setdefault("DISPLAY", f"remote-{args.direction}")
    return env


def run_upload(args: argparse.Namespace, env: dict[str, str]) -> int:
    sources = collect_upload_sources(args)
    mkdir_command = build_remote_mkdir_command(args)
    scp_command = build_upload_scp_command(args, sources)

    info(f"connecting to {args.user}@{args.host}:{args.port}")
    info(f"uploading {len(sources)} source(s) to {args.destination}")
    debug(f"mkdir command: {mkdir_command}")
    debug(f"scp command: {scp_command}")

    mkdir_exit_code = run_command(mkdir_command, env, "ssh")
    if mkdir_exit_code != 0:
        return mkdir_exit_code

    return run_command(scp_command, env, "scp")


def run_download(args: argparse.Namespace, env: dict[str, str]) -> int:
    sources = collect_download_sources(args)
    destination = collect_local_destination(args)
    scp_command = build_download_scp_command(args, sources, destination)

    info(f"connecting to {args.user}@{args.host}:{args.port}")
    info(f"downloading {len(sources)} source(s) to {destination}")
    debug(f"scp command: {scp_command}")

    return run_command(scp_command, env, "scp")


def run(args: argparse.Namespace) -> int:
    setup_logging("DEBUG" if args.verbose else "INFO")

    with tempfile.TemporaryDirectory(prefix=f"remote-{args.direction}-") as temp_dir_str:
        env = build_env(args, temp_dir_str)
        if args.direction == "upload":
            return run_upload(args, env)
        return run_download(args, env)


def main() -> int:
    if len(sys.argv) == 2 and sys.argv[1] == "--print-password":
        return print_password()

    parser = build_parser()
    args = parser.parse_args()
    return run(args)


if __name__ == "__main__":
    raise SystemExit(main())
