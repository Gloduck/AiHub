from pathlib import Path


SCRIPT_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = SCRIPT_ROOT.parent


def script_root() -> Path:
    return SCRIPT_ROOT


def repo_root() -> Path:
    return REPO_ROOT


def from_cwd(raw_path: str) -> Path:
    path = Path(raw_path).expanduser()
    if path.is_absolute():
        return path.resolve()
    return (Path.cwd() / path).resolve()


def from_repo(*parts: str) -> Path:
    return REPO_ROOT.joinpath(*parts).resolve()


def ensure_parent(path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    return path
