# Claude accounts refresh timer

[Claude accounts refresh timer](../features/claude-accounts-timer.md): run `bash claude-accounts/tests/claude-accounts-timer.test.sh`; it installs the units into a throwaway tree with a stub systemctl, proves dry run, rerun and uninstall, and never touches the host's timers.
