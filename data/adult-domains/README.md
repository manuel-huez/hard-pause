# Adult domain data

Hard Pause uses the domain-only [Block List Project porn list](https://blocklistproject.github.io/Lists/alt-version/porn-nl.txt) as its maintained upstream source. Its generated file identifies its license as MIT. macOS downloads and validates it at runtime; the repository does not copy the large list.

`supplement.txt` is a reviewed overlay for confirmed omissions. It starts empty. Entries are lowercase ASCII or punycode domains, one per line, with no scheme, path, wildcard, IP address, or leading sink address. The supplement is offered under CC0-1.0.

Portable contract:

- Inputs are UTF-8, comments start with `#`, and `Entries` equals the number of non-comment lines.
- The upstream file is at most 32 MiB and 1,500,000 lines. At most 0.1% of its lines can be unsupported.
- The supplement uses `Format: hard-pause-domain-list-v1`, category, ISO revision date, license, and provenance fields. It is at most 1 MiB and 10,000 unique valid domains.
- Consumers canonicalize Unicode hosts to lowercase ASCII/punycode, merge the two sets, and match an exact domain or its parent at label boundaries.

For each change:

1. Record the review date in `Revision` and the exact line count in `Entries`.
2. Add only domains confirmed by direct review. Do not infer related subdomains or claim complete coverage.
3. Prefer reporting suitable domains upstream. Remove an overlay entry after the maintained upstream list includes it.
4. Run `swift test --package-path core` and the native tests.

Android and Windows ports can consume the same two domain-only inputs and must implement whole-label parent matching. Native adapters remain responsible for fetching, caching, and enforcement.
