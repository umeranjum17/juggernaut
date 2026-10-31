# Feature map

- [Shared model pool helper](model-pool-helper.md): `jg-model-pool` pick/next JSON over the account pool with forced-limit A/B and Sol/Goat/Cursor fallovers.
- [quota-axi-pool](quota-axi-pool.md): PATH wrapper so dispatch `quota-axi --json` Claude runway matches jg-model-pool's account reading.
- [Incremental fleet-pulse chat export](incremental-fleet-pulse-chat-export.md): the refresh entry point appends only unseen redacted messages and filters injected wake lines.
- [Fleet flow lane cap](fleet-flow-lane-cap.md): the home flow check counts live lanes only; a kept copy of a stopped lane stays listed but occupies no working slot.
