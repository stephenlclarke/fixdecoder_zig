# fixdecoder_zig

Zig rewrite of the Rust `fixdecoder` app from
[`~/github/fixdecoder_rs`](/Users/sclarke/github/fixdecoder_rs).

The Zig version embeds the same QuickFIX XML dictionaries and keeps the
core CLI workflows:

- decode FIX messages from `stdin` or files
- inspect dictionaries with `--info`, `--message`, `--component`, and `--tag`
- validate messages with `--validate`
- summarise order state with `--summary`
- obfuscate sensitive identifiers with `--secret`
- load custom XML dictionaries with `--xml`

## Build

```sh
make build
```

## Test

```sh
make test
```

## Run

```sh
make run
```

Or pass arguments directly:

```sh
zig build run -- --fix=44 --info
printf '8=FIX.4.4\x019=5\x0135=0\x0110=161\x01\n' | zig build run -- --fix=44
```

## Examples

Decode a message:

```sh
printf '8=FIX.4.4\x019=5\x0135=0\x0110=161\x01\n' | zig build run -- --fix=44
```

Validate only broken messages:

```sh
printf '8=FIX.4.4\x019=0\x0110=000\x01\n' | zig build run -- --fix=44 --validate
```

Inspect a message schema:

```sh
zig build run -- --fix=44 --message 0 --header --trailer --verbose
```

Summarise order state from a file:

```sh
zig build run -- --fix=44 --summary orders.log
```

## Current Scope

Implemented:

- embedded built-in FIX dictionaries: `FIX27`, `FIX30`, `FIX40`, `FIX41`,
  `FIX42`, `FIX43`, `FIX44`, `FIX50`, `FIX50SP1`, `FIX50SP2`, `FIXT11`
- runtime XML loading for custom dictionaries
- `FIXT.1.1` app-version fallback via `ApplVerID` and stored
  `DefaultApplVerID`
- file banners, line numbering, and simple grid separators
- checksum, body-length, required-field, enum, and basic type validation

Not implemented yet:

- `--follow`
- active pager integration behind `--paging`, `--pager`, and `--nowrap`
- full parity with the Rust renderer’s deeply nested repeating-group
  layout

## Notes

- The embedded FIX XML specifications come from QuickFIX and are included
  under `resources/`.
- Licensing and notices from the source project are carried over in
  [LICENSE](/Users/sclarke/github/fixdecoder_zig/LICENSE) and
  [NOTICE.md](/Users/sclarke/github/fixdecoder_zig/NOTICE.md).
