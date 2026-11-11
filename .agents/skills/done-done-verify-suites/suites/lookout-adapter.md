# Lookout adapter

[Lookout adapter](../../../../core/lookout-adapter/README.md): run `bash lookout-adapter/tests/test.sh`; fixture `jg-flow` output must map into a document accepted by the pinned `lookout-axi@0.1.0` CLI, with no `.meta` secret, and be served at `/fleet.json`. Live: `JG_HOME=<home> LOOKOUT_DIR=<lookout clone> done-done run lookout-adapter-live` (`lookout-adapter/run-proof.sh`) serves the adapter on the real home read-only, points the clone at it and captures Overview, Lanes, Flow and Capacity; the header must not say Sample fleet.
