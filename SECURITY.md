# Security policy

## Supported versions

akkar has not reached 1.0. Security fixes are provided for the latest published
`0.x` minor release and for `main`. Older minors are unsupported.

| Version | Supported |
|---|---|
| latest `0.x` | yes |
| `main` | yes, pre-release |
| older minors | no |

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Use GitHub's private
vulnerability reporting for this repository. Include the affected revision,
deployment shape, reproduction, impact and any known workaround.

The maintainer will acknowledge a complete report within three business days,
provide an initial assessment within seven days, and coordinate disclosure
after a fix or mitigation is available. Those are response targets, not a bug
bounty or a guarantee of a particular resolution date.

Reports involving a deployed application should remove credentials, customer
data and production tokens. A minimal synthetic reproduction is preferred.

## Security boundary

`akkar.vm` isolates trusted extension code from accidental global access; it is
not an OS security boundary. Untrusted Lua or Python must run in a separate,
resource-limited process or container. Model artifacts are executable input
when their format uses pickle or equivalent deserialization and must therefore
come only from an authenticated, integrity-checked registry.
