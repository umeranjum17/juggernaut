# Route-chain probe on change only

Route-chain probe on change only: run `done-done run -- bash core/account-pool/tests/route-chain.test.sh`; the real `jg-route-probe` over a stub quota reader and Ollama balance proves an unchanged route state prints nothing, a changed state prints one line with no epoch, and `bash tests/jg-wake-route.test.sh` proves that line routes `now` while other route-chain output routes `batch` (screen: none).
