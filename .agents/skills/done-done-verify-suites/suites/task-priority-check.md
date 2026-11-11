# Task priority check

Task priority check: run `bash task-priority/tests/task-priority.test.sh`; it installs the check into a throwaway `XDG_DATA_HOME`, proves a task add without `--priority 0-3` is refused naming the flag, that a priority passes with release `later`, and that an explicit `release:` line is kept.
