# Merge-card post-merge hook wiring

Merge-card post-merge hook wiring: run `done-done run -- bash -c 'bash core/merge-card/tests/wiring.test.sh && bash tests/jg-host-wiring.test.sh'`; a fixture home's `config/post-merge` is rewritten from a stale add-on copy to its own `core/merge-card/merge-card`, keeps its board, reruns unchanged, and a hook that is not a merge-card hook is refused untouched.
