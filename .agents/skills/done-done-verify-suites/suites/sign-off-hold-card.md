# Sign-off hold card

Sign-off hold card: run `JG_CODE_ROOT=<Juggernaut checkout> bash signoff/tests/jg-procevent-signoff.test.sh`; it uses a stub sign-off-axi that rejects a raise without `--ask-ref` (the real VALIDATION_ERROR), proves a hold raises its card with the hold task id as ask reference, and never touches a real board.
