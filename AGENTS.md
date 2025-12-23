# Repository Guidelines

## Project Structure & Module Organization
This repository is a single-file CLI tool. The main executable is `qs`, which
contains the HTTP server implementation and CLI parsing. Packaging metadata
lives in `setup.py`. Project docs are in `README.rst` and licensing is in
`LICENSE`. There is no dedicated `src/` or `tests/` directory today.

## Build, Test, and Development Commands
- `python setup.py install` installs the `qs` script locally.
- `./qs -h` prints CLI help and confirms the script is runnable.
- `./qs [path]` serves the current directory or a specific file/directory.
- `./qs -p 9000 -r 256` serves on port 9000 with a 256 KB/s rate limit.

There is no build step; changes are picked up by running the script directly.

## Coding Style & Naming Conventions
Use 4-space indentation and Python standard naming: `snake_case` for functions
and `UPPER_CASE` for constants (see `VERSION`). Keep the module docstring in
`qs` in sync with CLI behavior because `docopt` reads from it. Maintain Python
2/3 compatibility in the script (avoid Python 3-only syntax such as f-strings).

## Testing Guidelines
There is no automated test suite. Validate changes manually by running `./qs`
and fetching a file via a browser or `curl http://localhost:8000/`. If you add
tests, place them under `tests/` and name them `test_*.py`.

## Commit & Pull Request Guidelines
Commit messages are short, sentence-case summaries (e.g., "Update README",
"Fix get_ip once and for all"). For PRs, include a clear description, mention
any linked issues, and add a short "Testing" note (manual steps are fine).
Update `README.rst` when CLI flags or usage text changes.

## Security & Configuration Tips
`qs` serves files over plain HTTP without authentication. Use it on trusted
networks, share only intended files, and consider `--rate` to limit bandwidth.
