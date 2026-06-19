const std = @import("std");

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

    const args = try init.minimal.args.toSlice(aa);
    if (args.len != 2) {
        std.log.err("Requires exactly one argument\n{s}", .{HELP_STR});
        return error.ArgumentCountMismatch;
    }

    const io = init.io;

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
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

    var client: rss.Client = try .init(gpa);
    defer client.deinit();

    try client.parse(response.written());
    for (client.parser.channels.items) |*channel| {
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

    // try stdout.writeAll(response.written());
    try stdout.flush();
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
