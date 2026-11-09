# Chat gateway Dapr envelope

Chat gateway Dapr envelope: run `done-done run -- bash -c 'cd core/bus && go test -count=1 ./cmd/jg-bus -run TestGatewayEnvelope -v'` (log into `$DONE_DONE_EVIDENCE_ROOT`); a fake Telegram Bot API proves an outcome and an alert wrapped in the CloudEvent envelope the Dapr sidecar publishes reach the owner's chat once each, an enveloped inbound event does not, and the reply router routes an enveloped answer; before the fix the consumer read no kind, acknowledged the event and sent nothing.
