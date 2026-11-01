# Owner rules

Standing decisions the owner has made, in his own words, one entry per decision, each naming the code or contract that enforces it.
Every entry carries `- Kind: owner`: his own taste and authority, the thing only he decides.
An engineering default any Juggernaut user should get is a product rule and never belongs here; it is a ticket and a change to what ships.
`bin/jg-owner-rules.sh add --kind owner` appends one entry, `bin/jg-owner-rules.sh split` reports the split by kind, and `bin/jg-owner-rules.sh audit` finds a decision still trapped in a private note.
Every session start prints this file, so a rule written here reaches every future session of this home.

This file starts empty on purpose.
An entry is the owner's own call, and the installer never infers one.
