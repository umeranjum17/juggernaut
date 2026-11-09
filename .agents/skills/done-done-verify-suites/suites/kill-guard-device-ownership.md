# Kill guard device ownership

Kill guard device ownership: run `bash kill-guard/tests/kill-guard.test.sh`; its fake adb joins shell arguments the way the real one does, and `own start` must record a running process whose kill the guard then allows. On the real test phone, run one journey under `jg-device-lock.sh <serial>`: `own start <serial> -- sleep 120` returns at once and records it, the guard allows `adb -s <serial> shell kill <pid>` and refuses device PID 1 and `pkill`, and the process is gone after the kill.
