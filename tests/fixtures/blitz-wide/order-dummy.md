# Work order: a dummy note lane

## Goal

Write one line `done <slice id>` to notes/<slice id>.txt, commit it once, append your status line, report done.

## Files

notes/<slice id>.txt (new)

## Steps

Name the slice id from the task you were given; it is the part of the title after "slice". Write the line, commit once, append your status line, report done.

## Acceptance

`cat notes/<slice id>.txt` prints `done <slice id>`.
