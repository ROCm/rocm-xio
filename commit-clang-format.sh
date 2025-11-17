#!/bin/bash
# Commit script for clang-format fixes

git commit -S -m "style: Apply clang-format to all source files

- Fix all clang-format violations across 21 files
- Changes primarily break long lines to fit 80-column limit
- Adjust spacing and alignment per .clang-format configuration
- No functional changes, purely formatting

Files affected:
- gda-experiments/*.hip, *.cpp, *.h (18 files)
- tester/*.hip, *.cpp (3 files)

All files now pass clang-format --Werror check.
Resolves clang-format linting failures in CI."

echo ""
echo "✅ Commit created successfully!"
echo ""
echo "To push to remote:"
echo "  git push origin HEAD:dev/stebates/nvme-ep"

