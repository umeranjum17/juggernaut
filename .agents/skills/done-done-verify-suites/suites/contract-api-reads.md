# Contract API reads

Run `done-done run -- bash core/agent-cli/tests/api-reads.test.sh` from the repository root.
The real loopback API and command dispatcher run against a throwaway home and token.
The journey compares the four legacy responses byte for byte, compares contract reads with the CLI, and checks arguments, read-only routing and authentication.
