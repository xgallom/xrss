# xrss

CLI RSS feed reader. Fetches a feed URL and prints channels and items to stdout.

## Usage

```
xrss [--help | <url>]
```

```
xrss https://example.com/feed.rss
```

Output format:

```
Channel <title> {
  <prop>           <value>
  Items [
    Item {
      <prop>       <value>
    }
  ]
}
```

## Install

Download a prebuilt binary from the [releases page](https://github.com/xgallom/xrss/releases).

| Platform        | Archive                      |
|-----------------|------------------------------|
| Linux x86_64    | `xrss-linux-x86_64.tar.gz`  |
| Windows x86_64  | `xrss-windows-x86_64.zip`   |
| macOS aarch64   | `xrss-macos-aarch64.tar.gz` |

Extract and put `xrss` (or `xrss.exe`) somewhere on your `PATH`.

## Build

Requires [Zig 0.16.0](https://ziglang.org/download/).

```
zig build -Doptimize=ReleaseSafe
```

Binary lands at `zig-out/bin/xrss`.

```
zig build test
```

## License

[MIT](LICENSE.md)
