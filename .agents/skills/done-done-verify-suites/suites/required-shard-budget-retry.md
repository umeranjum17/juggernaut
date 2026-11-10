# Required shard budget retry

Required shard budget retry: run `done-done run required-shard-retry` (`bash journeys/required-shard-retry.sh`, which runs `bash tests/jg-test-run.test.sh`); the real `bin/jg-test-run.sh --required-shards` gates three throwaway repositories with a 2000 ms shard budget and proves a shard that passes every script but runs over its budget once is run again and the gate passes, a shard over its budget twice stays red with the second overrun named final, and a shard with a failed test stays red and is never run again (screen: none).
