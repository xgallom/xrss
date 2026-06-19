const std = @import("std");
const base64 = std.base64.url_safe_no_pad;

const base64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._".*;

const url_safe_no_pad = std.base64.Codecs{
    .alphabet_chars = base64_alphabet,
    .pad_char = null,
    .decoderWithIgnore = undefined,
    .Encoder = std.base64.Base64Encoder.init(base64_alphabet, null),
    .Decoder = std.base64.Base64Decoder.init(base64_alphabet, null),
};

const datetime = @import("datetime.zig");
const rss = @import("rss.zig");

const HELP_STR =
    \\xrss [--help | {url}]
    \\
;

const FMT_CHANNEL =
    \\Channel {s} {{
    \\
;

const FMT_CHANNEL_PROP =
    \\  {s:<16} {s}
    \\
;

const FMT_CHANNEL_PROP_END =
    \\  Items [
    \\
;

const FMT_CHANNEL_END =
    \\  ]
    \\}}
    \\
;

const FMT_ITEM =
    \\    Item {{
    \\
;

const FMT_ITEM_PROP =
    \\      {s:<16} {s}
    \\
;

const FMT_ITEM_END =
    \\    }}
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const aa: std.mem.Allocator = init.arena.allocator();

    const env = init.environ_map;

    const args = try init.minimal.args.toSlice(aa);
    if (args.len != 2) {
        std.log.err("Requires exactly one argument\n{s}", .{HELP_STR});
        return error.ArgumentCountMismatch;
    }
    if (args[1].len > 255) {
        std.log.err("Limit to url length is 255 characters", .{});
        return error.URLTooLong;
    }

    const io = init.io;

    const io_buf = try aa.alloc(u8, 1024);
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, io_buf);
    const stdout = &stdout_writer.interface;

    if (std.mem.eql(u8, args[1], "--help")) {
        try stdout.writeAll(HELP_STR);
        try stdout.flush();
        return;
    }

    var http: std.http.Client = .{
        .allocator = gpa,
        .io = io,
    };
    defer http.deinit();

    var response: std.Io.Writer.Allocating = .init(gpa);
    defer response.deinit();

    const feed = try http.fetch(.{
        .location = .{ .url = args[1] },
        .response_writer = &response.writer,
    });
    switch (feed.status.class()) {
        .success => {},
        else => |class| {
            std.log.err("request failed: {s}", .{feed.status.phrase() orelse @tagName(class)});
            return error.RequestFailed;
        },
    }

    var client: rss.Client = try .init(gpa, aa);
    defer client.deinit();

    try client.parse(response.written());

    var output: rss.Data = .init(gpa, aa);
    defer output.deinit();
    {
        std.Io.Dir.createDirAbsolute(
            io,
            try appDir(env, aa),
            .default_dir,
        ) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        const cache_dir = try std.Io.Dir.openDirAbsolute(io, try appDir(env, aa), .{
            .access_sub_paths = true,
        });
        defer cache_dir.close(io);
        const buf_len = base64.Encoder.calcSize(args[1].len) + rss.config.XRSS_FILE_EXT.len;
        const name_buf = try aa.alloc(u8, buf_len);
        const basename = base64.Encoder.encode(name_buf, args[1]);
        @memcpy(name_buf[basename.len..], rss.config.XRSS_FILE_EXT);
        var cache: rss.Data = .init(gpa, aa);
        defer cache.deinit();
        const has_cache = blk: {
            const file = cache_dir.openFile(io, name_buf, .{
                .allow_directory = false,
            }) catch |err| switch (err) {
                error.FileNotFound => break :blk false,
                else => return err,
            };
            defer file.close(io);
            var file_r = file.reader(io, io_buf);
            try cache.read(&file_r.interface);
            break :blk true;
        };
        {
            const file = try cache_dir.createFile(io, name_buf, .{});
            defer file.close(io);
            var file_w = file.writer(io, io_buf);
            try client.parser.data.write(&file_w.interface);
            try file_w.flush();
        }
        if (has_cache) {
            var to_delete: std.ArrayList(u64) = .empty;
            defer to_delete.deinit(gpa);
            loop: for (client.parser.data.channels.items) |*channel| {
                for (cache.channels.items) |*cache_channel| {
                    if (std.mem.eql(
                        u8,
                        channel.props.get(.title).?,
                        cache_channel.props.get(.title).?,
                    )) {
                        const cache_build_date = try datetime.parseRfc1123ToNanos(
                            cache_channel.props.get(
                                .last_build_date,
                            ) orelse return error.MissingBuildDate,
                        );
                        const channel_build_date = try datetime.parseRfc1123ToNanos(
                            channel.props.get(
                                .last_build_date,
                            ) orelse return error.MissingBuildDate,
                        );
                        if (cache_build_date <= channel_build_date) {
                            to_delete.clearRetainingCapacity();
                            try to_delete.ensureUnusedCapacity(gpa, channel.items.items.len);
                            for (channel.items.items, 0..) |*item, item_idx| {
                                for (cache_channel.items.items) |*cache_item| {
                                    if (std.mem.eql(
                                        u8,
                                        item.props.get(.guid) orelse return error.MissingGUID,
                                        cache_item.props.get(.guid) orelse return error.MissingGUID,
                                    )) {
                                        const cache_pub_date = try datetime.parseRfc1123ToNanos(
                                            cache_item.props.get(
                                                .pub_date,
                                            ) orelse return error.MissingPubDate,
                                        );
                                        const item_pub_date = try datetime.parseRfc1123ToNanos(
                                            item.props.get(
                                                .pub_date,
                                            ) orelse return error.MissingPubDate,
                                        );
                                        if (cache_pub_date >= item_pub_date) {
                                            to_delete.appendAssumeCapacity(item_idx);
                                        }
                                    }
                                }
                            }
                            std.mem.sort(u64, to_delete.items, {}, std.sort.asc(u64));
                            channel.items.orderedRemoveMany(to_delete.items);
                            try output.channels.append(gpa, channel.*);
                            channel.items = .empty;
                        }
                        continue :loop;
                    }
                }
                try output.channels.append(gpa, channel.*);
                channel.items = .empty;
            }
        } else {
            output = client.parser.data;
            client.parser.data = .init(gpa, aa);
        }
    }

    for (output.channels.items) |*channel| {
        try stdout.print(FMT_CHANNEL, .{channel.props.get(.title).?});
        {
            var iter = channel.props.iterator();
            while (iter.next()) |e| {
                if (e.key == .title) continue;
                if (e.value.*) |val| try stdout.print(
                    FMT_CHANNEL_PROP,
                    .{ e.key.generic().displayName(), val },
                );
            }
        }
        try stdout.print(FMT_CHANNEL_PROP_END, .{});
        for (channel.items.items) |*item| {
            try stdout.print(FMT_ITEM, .{});
            {
                var iter = item.props.iterator();
                while (iter.next()) |e| {
                    if (e.value.*) |val| try stdout.print(
                        FMT_ITEM_PROP,
                        .{ e.key.generic().displayName(), val },
                    );
                }
            }
            try stdout.print(FMT_ITEM_END, .{});
        }
        try stdout.print(FMT_CHANNEL_END, .{});
    }
    try stdout.flush();
}

fn appDir(env: *const std.process.Environ.Map, aa: std.mem.Allocator) ![]const u8 {
    const home = env.get("USERPROFILE") orelse env.get("HOME") orelse {
        std.log.err("Could not determine home directory", .{});
        return error.EnvFailed;
    };
    return std.fs.path.join(aa, &.{ home, ".cache", "xrss" });
}

test {
    _ = datetime;
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    try std.testing.fuzz({}, testOne, .{});
}

fn testOne(context: void, smith: *std.testing.Smith) !void {
    _ = context;
    // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!

    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    while (!smith.eos()) switch (smith.value(enum { add_data, dup_data })) {
        .add_data => {
            const slice = try list.addManyAsSlice(gpa, smith.value(u4));
            smith.bytes(slice);
        },
        .dup_data => {
            if (list.items.len == 0) continue;
            if (list.items.len > std.math.maxInt(u32)) return error.SkipZigTest;
            const len = smith.valueRangeAtMost(u32, 1, @min(32, list.items.len));
            const off = smith.valueRangeAtMost(u32, 0, @intCast(list.items.len - len));
            try list.appendSlice(gpa, list.items[off..][0..len]);
            try std.testing.expectEqualSlices(
                u8,
                list.items[off..][0..len],
                list.items[list.items.len - len ..],
            );
        },
    };
}
