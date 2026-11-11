# A test that is red on the base without the change never blocks the worker's proof

A test that is red on the base without the change never blocks the worker's proof: run `done-done run -- bash tests/jg-trunk-proof-same-change.test.sh`; it drives the real `bin/jg-local-suite.sh` over a lane whose base already fails one script, and shows the receipt exit 0 with `tip_red=` naming that script and `verify` printing it, while a new case in that script, a different exit, and a new failing script each still leave the failing exit (screen: none).
