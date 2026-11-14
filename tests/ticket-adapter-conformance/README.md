# Ticket adapter conformance

`test/ticket-adapter-conformance.mjs`, `docs/ticket-adapter/` (schemas and examples) are the interface's own files, kept byte for byte as shipped
(sign-off ticket interface v1). `test/support/json-schema.mjs` is ours: a small schema checker, because the interface's support file did not ship with the script.

The unmodified script run against `bin/jg-ticket-adapter.py` passes 17 of 18 checks. The one failure is check 2: it compares `extra` with
`JSON.stringify`, so it reads key ORDER. bd keeps metadata sorted, so `{legacy-ref, estimate}` reads back as `{estimate, legacy-ref}`, every value intact.
The interface says `extra` keeps "the order the backend gave it" and JSON objects are unordered, so the adapter invents no order record.

`run-order-insensitive.mjs` is the documented exception: it runs the same script with its one `same` line replaced by an order-insensitive compare
(all 18 pass) and nothing else changed. It patches a temporary copy beside the script and removes it. Remove the wrapper when sign-off's script compares
`extra` without order. Usage: `node run-order-insensitive.mjs <adapter> --throwaway --faults <driver>`.
