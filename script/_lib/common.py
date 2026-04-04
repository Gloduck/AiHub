from pathlib import Path
import sys


SCRIPT_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = SCRIPT_ROOT.parent
LOG_LEVELS = {"DEBUG": 10, "INFO": 20, "ERROR": 30}
CURRENT_LOG_LEVEL = LOG_LEVELS["INFO"]


def script_root() -> Path:
    return SCRIPT_ROOT


def repo_root() -> Path:
    return REPO_ROOT


def from_cwd(raw_path: str) -> Path:
    path = Path(raw_path).expanduser()
    if path.is_absolute():
        return path.resolve()
    return (Path.cwd() / path).resolve()


def ensure_parent(path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    return path


def setup_logging(level: str = "INFO") -> None:
    global CURRENT_LOG_LEVEL
    normalized_level = level.upper()
    if normalized_level not in LOG_LEVELS:
        raise ValueError(f"unsupported log level: {level}")
    CURRENT_LOG_LEVEL = LOG_LEVELS[normalized_level]


def log(level: str, message: str) -> None:
    if LOG_LEVELS[level] < CURRENT_LOG_LEVEL:
        return
    print(f"[{level}] {message}", file=sys.stderr)


def info(message: str) -> None:
    log("INFO", message)


def error(message: str) -> None:
    log("ERROR", message)


def debug(message: str) -> None:
    log("DEBUG", message)
