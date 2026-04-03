from argparse import ArgumentParser, Namespace
from collections.abc import Callable

from _lib.logging import setup_logging


def build_parser(description: str) -> ArgumentParser:
    parser = ArgumentParser(description=description)
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print actions without writing changes.",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Enable verbose logs.",
    )
    return parser


def run_cli(
    description: str,
    configure_parser: Callable[[ArgumentParser], None],
    runner: Callable[[Namespace], int],
) -> int:
    parser = build_parser(description)
    configure_parser(parser)
    args = parser.parse_args()
    setup_logging(args.verbose)
    return runner(args)
