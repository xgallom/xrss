const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const config = @import("config.zig");

gpa: Allocator,
aa: Allocator,
channels: std.ArrayList(Channel) = .empty,

const Data = @This();

pub fn init(gpa: Allocator, aa: Allocator) @This() {
    return .{
        .gpa = gpa,
        .aa = aa,
    };
}

pub fn deinit(self: *@This()) void {
    for (self.channels.items) |*channel| channel.deinit(self.gpa);
    self.channels.deinit(self.gpa);
}

pub fn activeChannel(self: *const @This()) *Channel {
    assert(self.channels.items.len > 0);
    return &self.channels.items[self.channels.items.len - 1];
}

pub fn read(self: *@This(), reader: *std.Io.Reader) !void {
    assert(self.channels.items.len == 0);
    const magic = try reader.take(config.XRSS_FILE_MAGIC.len);
    if (!std.mem.eql(u8, magic, config.XRSS_FILE_MAGIC)) return error.InvalidFormat;
    const channel_count = try reader.takeInt(u64, .little);
    if (channel_count > 8) return error.TooManyChannels;
    try self.channels.ensureUnusedCapacity(self.gpa, channel_count);
    for (0..channel_count) |_| {
        const channel = self.channels.addOneAssumeCapacity();
        channel.* = .{};
        {
            var iter = channel.props.iterator();
            while (iter.next()) |e| {
                const prop_len = try reader.takeInt(u64, .little);
                if (prop_len > 0) e.value.* = try self.aa.dupe(u8, try reader.take(prop_len));
            }
        }
        const item_count = try reader.takeInt(u64, .little);
        if (item_count > 1024) return error.TooManyItems;
        try channel.items.ensureUnusedCapacity(self.gpa, item_count);
        for (0..item_count) |_| {
            const item = channel.items.addOneAssumeCapacity();
            item.* = .{};
            var iter = item.props.iterator();
            while (iter.next()) |e| {
                const prop_len = try reader.takeInt(u64, .little);
                if (prop_len > 0) e.value.* = try self.aa.dupe(u8, try reader.take(prop_len));
            }
        }
    }
}

pub fn write(self: *const @This(), writer: *std.Io.Writer) !void {
    try writer.writeAll(config.XRSS_FILE_MAGIC);
    try writer.writeInt(u64, self.channels.items.len, .little);
    for (self.channels.items) |*channel| {
        {
            var iter = channel.props.iterator();
            while (iter.next()) |e| {
                if (e.value.*) |val| {
                    try writer.writeInt(u64, val.len, .little);
                    try writer.writeAll(val);
                } else try writer.writeInt(u64, 0, .little);
            }
        }
        try writer.writeInt(u64, channel.items.items.len, .little);
        for (channel.items.items) |*item| {
            var iter = item.props.iterator();
            while (iter.next()) |e| {
                if (e.value.*) |val| {
                    try writer.writeInt(u64, val.len, .little);
                    try writer.writeAll(val);
                } else try writer.writeInt(u64, 0, .little);
            }
        }
    }
}

pub const Property = enum {
    // TODO: Implement whole RSS
    null,
    title,
    link,
    description,
    language,
    pub_date,
    last_build_date,
    generator,
    guid,

    const tag_name: std.EnumArray(@This(), []const u8) = .init(.{
        .null = config.TAG_NAME_NULL,
        .title = config.TAG_NAME_TITLE,
        .link = config.TAG_NAME_LINK,
        .description = config.TAG_NAME_DESCRIPTION,
        .language = config.TAG_NAME_LANGUAGE,
        .pub_date = config.TAG_NAME_PUB_DATE,
        .last_build_date = config.TAG_NAME_LAST_BUILD_DATE,
        .generator = config.TAG_NAME_GENERATOR,
        .guid = config.TAG_NAME_GUID,
    });

    pub inline fn tagName(self: @This()) []const u8 {
        return tag_name.get(self);
    }

    const display_name: std.EnumArray(@This(), []const u8) = .init(.{
        .null = config.DISPLAY_NAME_NULL,
        .title = config.DISPLAY_NAME_TITLE,
        .link = config.DISPLAY_NAME_LINK,
        .description = config.DISPLAY_NAME_DESCRIPTION,
        .language = config.DISPLAY_NAME_LANGUAGE,
        .pub_date = config.DISPLAY_NAME_PUB_DATE,
        .last_build_date = config.DISPLAY_NAME_LAST_BUILD_DATE,
        .generator = config.DISPLAY_NAME_GENERATOR,
        .guid = config.DISPLAY_NAME_GUID,
    });

    pub inline fn displayName(self: @This()) []const u8 {
        return display_name.get(self);
    }
};

pub const Channel = struct {
    props: std.EnumArray(@This().Property, ?[]const u8) = .initFill(null),
    items: std.ArrayList(Item) = .empty,

    const required_all: []const @This().Property = &.{ .title, .link, .description };

    pub const Property = enum {
        title,
        link,
        description,
        language,
        pub_date,
        last_build_date,
        generator,

        pub fn generic(self: @This()) Data.Property {
            @setEvalBranchQuota(10000);
            return switch (self) {
                inline else => |prop| comptime std.meta.stringToEnum(
                    Data.Property,
                    @tagName(prop),
                ) orelse @compileError("Property mapping mismatch: " ++ @tagName(self)),
            };
        }

        pub fn fromGeneric(self: Data.Property) @This() {
            @setEvalBranchQuota(10000);
            return switch (self) {
                inline else => |prop| (comptime std.meta.stringToEnum(
                    @This(),
                    @tagName(prop),
                )) orelse @panic("Property mapping mismatch: " ++ @tagName(prop)),
            };
        }
    };

    pub fn deinit(self: *@This(), gpa: Allocator) void {
        self.items.deinit(gpa);
    }

    pub fn activeItem(self: *const @This()) *Item {
        assert(self.items.items.len > 0);
        return &self.items.items[self.items.items.len - 1];
    }
};

pub const Item = struct {
    props: std.EnumArray(@This().Property, ?[]const u8) = .initFill(null),

    const required_one_of: []const @This().Property = &.{ .title, .description };

    pub const Property = enum {
        title,
        link,
        description,
        pub_date,
        guid,

        pub fn generic(self: @This()) Data.Property {
            @setEvalBranchQuota(10000);
            return switch (self) {
                inline else => |prop| comptime std.meta.stringToEnum(
                    Data.Property,
                    @tagName(prop),
                ) orelse @compileError("Property mapping mismatch: " ++ @tagName(self)),
            };
        }

        pub fn fromGeneric(self: Data.Property) @This() {
            @setEvalBranchQuota(10000);
            return switch (self) {
                inline else => |prop| (comptime std.meta.stringToEnum(
                    @This(),
                    @tagName(prop),
                )) orelse @panic("Property mapping mismatch: " ++ @tagName(prop)),
            };
        }
    };
};
