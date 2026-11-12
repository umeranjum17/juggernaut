# Machine enums

Machine enums: run `done-done run machine-enums` (which runs `tests/jg-machine-enum.test.sh` and writes its log into the run's folder); it loads the 21 `core/machines/*.states` files with `jg-machine.sh enum`, lints the ticket and delivering tables against their enums, and proves that a fixture table with a state outside its enum fails with the value named and that a fixture enum with two initial values fails; it reads only generated fixtures and the shipped files (screen: none).
