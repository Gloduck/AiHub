#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import shlex
import stat
import subprocess
import sys
import tempfile
import threading
from pathlib import Path
from typing import BinaryIO

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from _lib.common import debug, error, from_cwd, info, setup_logging


DESCRIPTION = "Execute remote Linux bash commands over SSH and stream output in real time."
EPILOG = """Required inputs:
  --host, --user, --password, and at least one --command or --command-file

Behavior:
  Commands from repeated --command flags are appended in order.
  Commands from --command-file are appended after inline commands.
  Remote Linux commands run as: bash -se
  Remote stdout/stderr is streamed directly to the local console in real time.
  Use --tty for interactive commands such as top.
  This script runs remote Linux bash commands over SSH. It does not execute local Windows cmd or PowerShell commands.

Requirements:
  Requires local Python and local ssh client.
  No interactive prompts are used.
"""
def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=DESCRIPTION,
        epilog=EPILOG,
        formatter_class=argparse.RawTextHelpFormatter,
    )
    parser.add_argument("--host", required=True, help="Target Linux server address.")
    parser.add_argument("--port", type=int, default=22, help="SSH port. Default: 22.")
    parser.add_argument("--user", required=True, help="SSH username.")
    parser.add_argument("--password", required=True, help="SSH password.")
    parser.add_argument(
        "--command",
        action="append",
        default=[],
        help="Remote Linux bash command to run. Can be provided multiple times.",
    )
    parser.add_argument(
        "--command-file",
        action="append",
        default=[],
        help="Local file containing remote Linux bash commands. Can be provided multiple times.",
    )
    parser.add_argument(
        "--accept-host-key",
        action="store_true",
        help="Set StrictHostKeyChecking=accept-new.",
    )
    parser.add_argument(
        "--tty",
        action="store_true",
        help="Allocate a remote TTY for interactive commands like top.",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Print debug logs.",
    )
    return parser


def print_password() -> int:
    sys.stdout.write(os.environ.get("REMOTE_EXEC_SSH_PASSWORD", ""))
    sys.stdout.write("\n")
    sys.stdout.flush()
    return 0


def read_command_files(paths: list[str]) -> list[str]:
    commands: list[str] = []
    for raw_path in paths:
        path = from_cwd(raw_path)

        if not path.is_file():
            raise SystemExit(f"[ERROR] command file not found: {path}")

        commands.extend(path.read_text(encoding="utf-8").splitlines())

    return commands


def collect_commands(args: argparse.Namespace) -> list[str]:
    commands = list(args.command)
    commands.extend(read_command_files(args.command_file))
    if not commands:
        raise SystemExit("[ERROR] at least one --command or --command-file is required")
    return commands


def validate_tty_commands(args: argparse.Namespace, commands: list[str]) -> None:
    if not args.tty:
        return

    if args.command_file:
        raise SystemExit("[ERROR] --tty does not support --command-file; use a single --command")

    if len(commands) != 1:
        raise SystemExit("[ERROR] --tty requires exactly one --command")


def create_askpass_script(temp_dir: Path) -> Path:
    script_path = Path(__file__).resolve()
    python_path = Path(sys.executable).resolve()

    if os.name == "nt":
        askpass_path = temp_dir / "askpass.cmd"
        askpass_path.write_text(
            f'@echo off\r\n"{python_path}" "{script_path}" --print-password\r\n',
            encoding="utf-8",
        )
        return askpass_path

    askpass_path = temp_dir / "askpass.sh"
    askpass_path.write_text(
        "#!/usr/bin/env sh\n"
        f'exec "{python_path}" "{script_path}" --print-password\n',
        encoding="utf-8",
    )
    askpass_path.chmod(askpass_path.stat().st_mode | stat.S_IXUSR)
    return askpass_path


def stream_bytes(source: BinaryIO, destination: BinaryIO) -> None:
    while True:
        chunk = source.read(1)
        if not chunk:
            break
        destination.write(chunk)
        destination.flush()


def build_ssh_command(args: argparse.Namespace) -> list[str]:
    command = [
        "ssh",
        "-tt" if args.tty else "-T",
        "-p",
        str(args.port),
        "-o",
        "BatchMode=no",
        "-o",
        "PreferredAuthentications=password,keyboard-interactive",
        "-o",
        "PubkeyAuthentication=no",
        "-o",
        "NumberOfPasswordPrompts=1",
        "-o",
        f"StrictHostKeyChecking={'accept-new' if args.accept_host_key else 'yes'}",
        f"{args.user}@{args.host}",
    ]

    if args.tty:
        command.extend(["bash", "-lc", shlex.quote(args.command[0])])
    else:
        command.extend(["bash", "-se"])

    return command


def run_tty(process: subprocess.Popen[bytes]) -> int:
    return process.wait()


def run_batch(process: subprocess.Popen[bytes], remote_script: str) -> int:
    assert process.stdin is not None
    assert process.stdout is not None
    assert process.stderr is not None

    stdout_thread = threading.Thread(
        target=stream_bytes,
        args=(process.stdout, sys.stdout.buffer),
        daemon=True,
    )
    stderr_thread = threading.Thread(
        target=stream_bytes,
        args=(process.stderr, sys.stderr.buffer),
        daemon=True,
    )
    stdout_thread.start()
    stderr_thread.start()

    try:
        process.stdin.write(remote_script.encode("utf-8"))
        process.stdin.close()
    except OSError as exc:
        error(f"failed to send remote commands: {exc}")
        process.kill()
        stdout_thread.join()
        stderr_thread.join()
        return 1

    exit_code = process.wait()
    stdout_thread.join()
    stderr_thread.join()
    return exit_code


def run(args: argparse.Namespace) -> int:
    setup_logging("DEBUG" if args.verbose else "INFO")

    commands = collect_commands(args)
    validate_tty_commands(args, commands)
    remote_script = "\n".join(commands) + "\n"

    with tempfile.TemporaryDirectory(prefix="remote-exec-") as temp_dir_str:
        temp_dir = Path(temp_dir_str)
        askpass_path = create_askpass_script(temp_dir)
        env = os.environ.copy()
        env["REMOTE_EXEC_SSH_PASSWORD"] = args.password
        env["SSH_ASKPASS"] = str(askpass_path)
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env.setdefault("DISPLAY", "remote-exec")

        ssh_command = build_ssh_command(args)
        info(f"connecting to {args.user}@{args.host}:{args.port}")
        debug(f"ssh command: {ssh_command}")
        debug(f"command count: {len(commands)}")

        try:
            process = subprocess.Popen(
                ssh_command,
                stdin=None if args.tty else subprocess.PIPE,
                stdout=None if args.tty else subprocess.PIPE,
                stderr=None if args.tty else subprocess.PIPE,
                env=env,
            )
        except FileNotFoundError:
            error("missing command: ssh")
            return 1
        except OSError as exc:
            error(f"failed to start ssh: {exc}")
            return 1

        if args.tty:
            return run_tty(process)

        return run_batch(process, remote_script)


def main() -> int:
    if len(sys.argv) == 2 and sys.argv[1] == "--print-password":
        return print_password()

    parser = build_parser()
    args = parser.parse_args()
    return run(args)


if __name__ == "__main__":
    raise SystemExit(main())
