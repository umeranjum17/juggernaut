# Lookout adapter

Run `done-done run core-lookout-adapter-test` for the [Lookout adapter](../../../../core/lookout-adapter/README.md).
The fixture document served at `/fleet.json` passes the pinned `lookout-axi@0.1.0` contract check and omits private lane metadata.
The HTTP journey counts full builds through the quota view and proves an idle tick skips the build, a ledger change updates the response and a repair finds an unlogged change.
Run `bash core/lookout-adapter/tests/wiring.test.sh` for the install probe, which accepts a late answer within `PROBE_WAIT` and names a silent port or dead unit.
The optional live journey `JG_HOME=<home> LOOKOUT_DIR=<lookout clone> done-done run lookout-adapter-live` serves the adapter read-only and captures Overview, Lanes, Flow and Capacity from fleet data.
