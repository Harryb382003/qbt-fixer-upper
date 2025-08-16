# TODO

## 1. Functional Behavior
- Ensure `--scan` and `--dezombify` have contextual behavior.
- Prevent zombie scan if `dezombify=0`.

## 2. Code Structure & Maintainability
- Extract repeated patterns (e.g., cache handling) into `Utils.pm`.
- Move timestamp generation to a common helper.

## 3. Future Additions
- Create a `scripts/tools` directory for dev utilities (e.g., TODO auto-updater).
- Store `TODO.md` in repo root and auto-update during dev cycles.
- Add optional color palettes for Logger output.
- Consider command-line switches for debug modes:
  - `--debug` → enable sprinkles + Dumper.
  - `--verbose` → extra Logger detail.
  
