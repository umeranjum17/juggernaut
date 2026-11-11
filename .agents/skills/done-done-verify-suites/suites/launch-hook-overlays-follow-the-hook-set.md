# Launch hook overlays follow the hook set

Launch hook overlays follow the hook set: run `done-done run -- bash tests/jg-git-hooks-refresh.test.sh`; the real `jg-git-strip-ai-trailers.sh install` writes a `state/<id>.git-hooks` overlay, the test makes it stale (a wrapper gone, another with an old body), and `refresh` (which `jg-bootstrap.sh` runs at every locked session start) restores both, keeps the directory and wrappers read-only (mode 500), leaves a directory it did not write for that path unchanged, and changes nothing on a second run (screen: none).
