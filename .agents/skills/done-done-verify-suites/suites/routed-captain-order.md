# Routed captain order

Run `done-done run -- bash journeys/routed-captain-order.sh` from the repository root.
It captures the real filing, routing, brief, and auto-dispatch commands in isolated Main and lead homes.
The fixture checks that Main signs the row while filing, that the lead refuses a missing signature, and that Main's reroute restores it.
It advances the clock to prove the ten-minute resend and lead alert, then the twenty-minute notification and automatic start.
The worker spawn and lead message transport use recorders.
The output is `routed-captain-order.log`.
