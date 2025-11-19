# Local Testing Guide

This guide explains how to run the same linting and formatting checks locally
that are performed in CI, so you can catch issues before pushing.

## Prerequisites

Install the required tools:

```bash
# Formatting tool
sudo apt-get install clang-format

# Spell checking tools (optional, but recommended)
pip install pyspelling[all]
sudo apt-get install aspell aspell-en
```

## Formatting Checks

### Check formatting (without fixing)

```bash
make lint-format
```

This runs `clang-format --dry-run --Werror` on all source files and reports
any formatting issues.

### Auto-fix formatting issues

```bash
make format
```

This automatically formats all source files according to `.clang-format`.

**Tip**: Run `make format` before committing to ensure consistent formatting.

## Spell Checking

### Check spelling in markdown files

```bash
make lint-spell
```

This uses `pyspelling` with the `.spellcheck.yml` configuration to check all
markdown files against `.wordlist.txt`.

**Note**: If `pyspelling` is not installed, the command will provide
installation instructions.

### Adding words to the dictionary

If you encounter false positives (technical terms, code identifiers, etc.),
add them to `.wordlist.txt`:

```bash
echo "your-word-here" >> .wordlist.txt
```

## Run All Checks

Run both formatting and spell checking:

```bash
make lint-all
```

This is equivalent to running both `make lint-format` and `make lint-spell`.

## Pre-Commit Workflow

Recommended workflow before committing:

```bash
# 1. Auto-fix formatting
make format

# 2. Check formatting (should pass now)
make lint-format

# 3. Check spelling
make lint-spell

# 4. Build and test
make all

# 5. Commit
git add .
git commit -S -m "Your commit message"
```

## CI Checks

The following checks run in CI:

1. **Formatting** (`.github/workflows/build-check.yml`):
   - Uses `DoozyX/clang-format-lint-action@v0.18.2`
   - Checks: `*.cpp`, `*.h`, `*.hpp`, `*.c`, `*.cc`, `*.hip`
   - Style: `.clang-format` (80-column limit)

2. **Spell Checking** (`.github/workflows/spell-check.yml`):
   - Uses `rojopolis/spellcheck-github-actions@v0.52.0`
   - Checks: `*.md` files
   - Dictionary: `.wordlist.txt`

## Troubleshooting

### clang-format version mismatch

If CI uses a different version of clang-format, you can specify the path:

```bash
CLANG_FORMAT=/usr/bin/clang-format-18 make lint-format
```

### pyspelling not found

Install it with:

```bash
pip install pyspelling[all]
```

Or use the GitHub Actions workflow for spell checking instead.

### Formatting issues persist after `make format`

1. Ensure `.clang-format` exists in the project root
2. Check that `clang-format` version matches CI (version 18)
3. Try running `make format` again
4. If issues persist, check `.clang-format` configuration

