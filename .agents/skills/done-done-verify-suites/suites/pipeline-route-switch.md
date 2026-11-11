# Pipeline route switch

[Pipeline route switch](../features/pipeline-route-switch.md): run `bash pipeline-quota-failover/tests/switch-route.test.sh`; it uses a fixture config and a stub pi, proves that a switch edits only the agent and model keys, writes a backup first and restores it, and never touches a real config or model.
