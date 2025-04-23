# ⚡ ZUN

> *Fiat lux* ☀️

From the blog:

* ["Zig Smart Lights"](https://dbushell.com/2025/04/23/zig-smart-lights/)

This is a hobby project for me to learn Zig software development.

## Configuration

There is no auto-discovery (yet/ever). Subject to change.

Zonfig location: `~/.config/zun/zun.zon`

```zon
.{
    .lights = .{
        .{
            .label = "Disco Light",
            .addr = "192.168.1.10",
        },
    },
}
```

* * *

[MIT License](/LICENSE) | Copyright © 2025 [David Bushell](https://dbushell.com)
