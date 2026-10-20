# swag-upstream-sync

Compares your local SWAG (linuxserver/swag) nginx configs against the upstream [reverse-proxy-confs](https://github.com/linuxserver/reverse-proxy-confs) samples and reports upstream changes you may have missed. A weekly GitHub Actions workflow opens an issue with the diffs.

A plain `diff` is noisy because every file differs in `server_name`, `set $upstream_*`, auth includes, and similar lines. The script filters those known customizations and reports only upstream lines you do not have, such as a new `location` block or a new directive.

## Quick Start

```bash
git clone --depth 1 https://github.com/linuxserver/reverse-proxy-confs.git /tmp/upstream
./scripts/upstream-diff.sh /tmp/upstream --config-dir /path/to/your/nginx/config
```

Requires bash and GNU grep (the script uses `grep -P`). Exit codes: `0` nothing actionable, `1` actionable changes, `2` error.

Local files named `<app>.subdomain.<label>.conf` (for example `sonarr.subdomain.example.conf`) are matched to the upstream `<app>.subdomain.conf.sample`.

## Configuration

| Option | Meaning |
| --- | --- |
| `<upstream-dir>` | Clone of reverse-proxy-confs (required) |
| `--config-dir DIR` | Directory searched recursively for `*.subdomain*.conf` and `*.subfolder*.conf` (default `.`) |
| `--map FILE` | Map file (default `scripts/upstream-map.conf`) |
| `--stock-dir DIR` | Clone of docker-swag or docker-baseimage-alpine-nginx; repeatable. Enables the `stock:` checks |
| `--output-json` | JSON output instead of markdown |
| `--help`, `-h` | Print usage |

### Map file

`scripts/upstream-map.conf` takes three kinds of lines:

| Line | Effect |
| --- | --- |
| `local.subdomain.conf=upstream.subdomain.conf` | Maps a renamed config to its upstream sample (no `.sample` extension) |
| `ignore:<name>=<reason>` | Skips a config you rewrote on purpose |
| `stock:<path under --config-dir>=<sample path under root/defaults/nginx>` | Compares a forked stock conf (such as `ssl.conf`) to upstream by its `## Version YYYY/MM/DD` header date |

## Usage

`.github/workflows/upstream-sync.yml` runs every Monday at 09:00 UTC and on manual dispatch. It:

1. Clones reverse-proxy-confs, docker-swag, and docker-baseimage-alpine-nginx.
2. Runs the script from the repository root with both stock clones.
3. If the script exits `1`, closes open issues labeled `upstream-sync` and opens a new one with the report.

Setup in your own copy:

- Put your configs in the repository so `--config-dir` (default `.`) finds them.
- Create the `upstream-sync` label before the first run.

The job is skipped in `baker-scripts/swag-upstream-sync` itself, which has no configs.

## Limits

The filter cannot detect a new upstream `location` block when every directive in it is a filtered type (`proxy_pass`, `set $upstream_*`, and similar). Spot-check occasionally with `diff -u upstream.sample your.conf`.

## License

[MIT](LICENSE)
