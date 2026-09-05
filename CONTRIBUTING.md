# Contributing

akkar is pre-1.0 and changes its stable surface only deliberately. Before
opening a pull request, read `docs/COMPATIBILITY.md` and add a changelog entry
for every observable change.

## Required checks

Run the focused specs for the code changed, then the complete suite:

```sh
busted
```

Changes to the vendored HTTP stack also update
`akkar/vendor/http/PROVENANCE.md` and `spec/vendor_provenance_spec.lua`. Changes
to allocation-sensitive request paths run `spec/allocation_spec.lua`; protocol
changes run the relevant hostile-input and conformance checks.

Every bug fix includes a regression test that fails without the fix. New public
settings are validated at boot, documented in English and Portuguese, and use
safe defaults.

## Pull requests

- Keep changes scoped and explain the failure mode, not only the implementation.
- Do not include credentials, production data or generated build artifacts.
- Wait for the full required CI matrix. A skipped or cancelled job is not green.
- Security-sensitive reports follow `SECURITY.md`, not a public pull request.
