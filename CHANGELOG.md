# Changelog

## How to read this file

From the second release on, every entry classifies its changes so an existing
installation knows what `repomethod update` will do:

- **compatible** — additive or behaviour-preserving; update just refreshes files.
- **behavior-change** — a managed file behaves differently after the update;
  review if you depend on the old behaviour.
- **needs-migration** — an installed repo cannot move forward safely without a
  script in `migrations/`; update runs it automatically and aborts if it fails.

`update` records any managed file you have edited as a local fork (`source:
local` in the manifest) and never overwrites it again. When an entry touches a
script you have forked, re-apply the change to your fork by hand.

## [0.0.1]

First public release of RepoMethod.
