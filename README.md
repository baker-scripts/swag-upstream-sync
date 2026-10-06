# swag-upstream-sync

Compares your local SWAG (linuxserver/swag) nginx configs against the upstream
[reverse-proxy-confs](https://github.com/linuxserver/reverse-proxy-confs) samples and
reports upstream changes you may have missed. A weekly GitHub Actions workflow opens an
issue with the diffs.

If you customize your proxy confs, upstream fixes are easy to miss. A plain `diff` is
noisy because every file differs in `server_name`, `set $upstream_*`, auth includes and
similar lines. The script filters those known customizations and reports only upstream
lines you do not have, such as a new `location` block or a new directive.

## Usage

```bash
git clone --depth 1 https://github.com/linuxserver/reverse-proxy-confs.git /tmp/upstream
./scripts/upstream-diff.sh /tmp/upstream --config-dir /path/to/your/nginx/config
```

| Option | Meaning |
| --- | --- |
| `<upstream-dir>` | Clone of reverse-proxy-confs (required) |
| `--config-dir DIR` | Directory searched recursively for `*.subdomain*.conf` and `*.subfolder*.conf` (default `.`) |
| `--map FILE` | Map file (default `scripts/upstream-map.conf`) |
| `--stock-dir DIR` | Clone of docker-swag or docker-baseimage-alpine-nginx; repeatable. Enables the `stock:` checks |
| `--output-json` | JSON output instead of markdown |

Exit codes: 0 nothing actionable, 1 actionable changes, 2 error.

Local files named `<app>.subdomain.<label>.conf` (for example `sonarr.subdomain.example.conf`)
are matched to the upstream `<app>.subdomain.conf.sample`.

## Map file

`scripts/upstream-map.conf` takes three kinds of lines:

- `local.subdomain.conf=upstream.subdomain.conf` maps a renamed config to its upstream sample.
- `ignore:<name>=<reason>` skips a config you rewrote on purpose.
- `stock:<path under --config-dir>=<sample path under root/defaults/nginx>` compares a forked stock conf
  (such as `ssl.conf`) to upstream by its `## Version YYYY/MM/DD` header date.

## Workflow

`.github/workflows/upstream-sync.yml` runs every Monday at 09:00 UTC and on manual dispatch. It clones the
upstream repos, runs the script from the repository root, closes older open issues labeled `upstream-sync`,
and opens a new one. Create the `upstream-sync` label before the first run, and put your configs in the
repository so `--config-dir` (default `.`) finds them.

## Limits

The filter cannot detect a new upstream `location` block when every directive in it is one of the filtered
types (`proxy_pass`, `set $upstream_*`, and similar). Spot-check occasionally with
`diff -u upstream.sample your.conf`.

## License

MIT
