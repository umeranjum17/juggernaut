# Backlog add and done mirror to the board

Backlog add and done mirror to the board: run `bash tests/jg-ticket-writeback.test.sh` (or `done-done run tickets-writeback`); on a throwaway board and backlog with the real Beads backlog and sign-off-axi (fixture ticket creation supplies a valid description and checks its exit), `bin/jg-backlog.sh add` puts the ticket on the board, `done` marks it done there, two explicit sync passes leave one card and no bounced state, and a board that errors leaves the backlog write standing with a `board mirror is behind` line on stderr (screen: none).
