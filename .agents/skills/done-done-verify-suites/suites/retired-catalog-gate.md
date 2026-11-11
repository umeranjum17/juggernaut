# Retired catalog gate

Retired catalog gate: run `bash tests/jg-retired-catalog-check.test.sh` and `bash bin/jg-retired-catalog-check.sh --self-test`; they prove a new path under the retired `addons/` root is refused by name, that a clean checkout tracks nothing there at all, and that a change adding only core paths passes. Live: `bin/jg-retired-catalog-check.sh` on this checkout prints nothing and exits 0 (screen: none).
