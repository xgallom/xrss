const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Data = @import("Data.zig");
const config = @import("config.zig");

data: Data,
depth: u8 = 0,
state: State = .init,
active_property: Data.Property = .null,
active_sink: ?[]const u8 = null,
active_data: std.ArrayList(u8) = .empty,

pub const Error = error{
    OutOfMemory,
    ExpectedRSSTag,
    MissingRSSVersion,
    UnsupportedRSSVersion,
    ExpectedChannelTag,
    ExpectedItemTag,
    ExpectedPropertyTag,
    InvalidProperty,
    DuplicateProperty,
    MissingRequiredProperty,
    AttributeCountMismatch,
    DuplicateAttribute,
    ParsingEnded,
};

const Parser = @This();

pub const State = enum {
    init,
    rss,
    channel,
    item,
    end,
    err,
};

pub const Attr = struct {
    name: []const u8,
    value: []const u8,
};

pub fn init(gpa: Allocator, aa: Allocator) @This() {
    return .{ .data = .init(gpa, aa) };
}

pub fn deinit(self: *@This()) void {
    const gpa = self.gpaAllocator();
    self.data.deinit();
    self.active_data.deinit(gpa);
}

pub fn gpaAllocator(self: *const @This()) Allocator {
    return self.data.gpa;
}

pub fn arenaAllocator(self: *@This()) Allocator {
    return self.data.aa;
}

pub fn elementStart(
    user_data: ?*anyopaque,
    name: [*c]const u8,
    atts: [*c][*c]const u8,
) callconv(.c) void {
    const self: *@This() = @ptrCast(@alignCast(user_data));
    const attrs = self.processAttrs(@ptrCast(atts)) catch |err| {
        std.log.err("Failed processing element attributes: {t}", .{err});
        self.state = .err;
        return;
    };
    const state = self.state;
    const active_property = self.active_property;
    std.log.debug("{s}", .{name});
    self.elementStartImpl(std.mem.span(name), attrs) catch |err| {
        std.log.err("Failed starting element {s}: {t}", .{ name, err });
        self.state = .err;
    };
    if (self.state != .err) std.log.debug(
        "{s}Start element: {s} ({t}, {t}) -> ({t}, {t})",
        .{
            config.SPACES[0..self.depth],
            name,
            state,
            active_property,
            self.state,
            self.active_property,
        },
    );
}

fn elementStartImpl(self: *@This(), name: []const u8, attrs: []const Attr) !void {
    switch (self.state) {
        .init => if (std.mem.eql(u8, name, config.TAG_NAME_RSS)) {
            for (attrs) |attr| {
                if (std.mem.eql(u8, attr.name, config.ATTR_NAME_VERSION)) {
                    if (std.mem.eql(u8, attr.value, config.RSS_SUPPORTED_VERSION)) break;
                    return Error.UnsupportedRSSVersion;
                }
            } else return Error.MissingRSSVersion;
            self.state = .rss;
            self.depth += config.DEPTH_STEP;
        } else return Error.ExpectedRSSTag,
        .rss => if (std.mem.eql(u8, name, config.TAG_NAME_CHANNEL)) {
            try self.data.channels.append(self.gpaAllocator(), .{});
            self.state = .channel;
            self.depth += config.DEPTH_STEP;
        } else return Error.ExpectedChannelTag,
        .channel => {
            if (self.active_sink != null) return Error.ExpectedPropertyTag;
            if (self.active_property != .null) return Error.ExpectedPropertyTag;
            var iter = self.data.activeChannel().props.iterator();
            if (std.mem.eql(u8, name, config.TAG_NAME_ITEM)) {
                try self.data.activeChannel().items.append(self.gpaAllocator(), .{});
                self.state = .item;
                self.depth += config.DEPTH_STEP;
                return;
            }
            while (iter.next()) |e| if (try self.startProperty(
                name,
                e.key.generic(),
                e.value.*,
            )) return;
            self.active_sink = name;
            std.log.warn("Skipping unknown element: {s}", .{name});
        },
        .item => {
            if (self.active_sink != null) return Error.ExpectedPropertyTag;
            if (self.active_property != .null) return Error.ExpectedPropertyTag;
            var iter = self.data.activeChannel().activeItem().props.iterator();
            while (iter.next()) |e| if (try self.startProperty(
                name,
                e.key.generic(),
                e.value.*,
            )) return;
            self.active_sink = name;
            std.log.warn("Skipping unknown element: {s}", .{name});
        },
        .end => return Error.ParsingEnded,
        .err => return,
    }
}

pub fn characterData(user_data: ?*anyopaque, s: [*c]const u8, len: c_int) callconv(.c) void {
    const self: *@This() = @ptrCast(@alignCast(user_data));
    const data = std.mem.trim(u8, s[0..@intCast(len)], &std.ascii.whitespace);
    self.characterDataImpl(data) catch |err| {
        std.log.err("Failed appending character data: {t}", .{err});
        self.state = .err;
    };
}

fn characterDataImpl(self: *@This(), data: []const u8) !void {
    if (data.len == 0) return;
    switch (self.state) {
        .init => return Error.ExpectedRSSTag,
        .rss => return Error.ExpectedChannelTag,
        .channel => if (self.active_property == .null and
            self.active_sink == null) return Error.ExpectedPropertyTag,
        .item => if (self.active_property == .null and
            self.active_sink == null) return Error.ExpectedPropertyTag,
        .end => return Error.ParsingEnded,
        .err => return,
    }
    if (self.active_sink != null) {
        assert(self.active_property == .null);
        std.log.debug(
            "{s}Sink character data ({t}, {s}): \"{s}\"",
            .{ config.SPACES[0..self.depth], self.state, self.active_sink.?, data },
        );
    } else {
        std.log.debug(
            "{s}Append character data ({t}, {t}): \"{s}\"",
            .{ config.SPACES[0..self.depth], self.state, self.active_property, data },
        );
        try self.active_data.appendSlice(self.gpaAllocator(), data);
    }
}

pub fn elementEnd(user_data: ?*anyopaque, name: [*c]const u8) callconv(.c) void {
    const self: *@This() = @ptrCast(@alignCast(user_data));
    const state = self.state;
    const active_property = self.active_property;
    self.elementEndImpl(std.mem.span(name)) catch |err| {
        std.log.err("Failed ending element {s}: {t}", .{ name, err });
        self.state = .err;
    };
    if (self.state != .err) std.log.debug(
        "{s}End element: {s} ({t}, {t}) -> ({t}, {t})",
        .{
            config.SPACES[0..self.depth],
            name,
            state,
            active_property,
            self.state,
            self.active_property,
        },
    );
}

fn elementEndImpl(self: *@This(), name: []const u8) !void {
    switch (self.state) {
        .init => return Error.ExpectedRSSTag,
        .rss => if (std.mem.eql(u8, name, config.TAG_NAME_RSS)) {
            self.state = .end;
            self.depth -= config.DEPTH_STEP;
        } else return Error.ExpectedRSSTag,
        .channel => if (self.active_property != .null) {
            if (std.mem.eql(u8, name, self.active_property.tagName())) {
                const target = self.data.activeChannel().props.getPtr(
                    .fromGeneric(self.active_property),
                );
                try self.endProperty(target);
            } else return Error.ExpectedPropertyTag;
        } else if (self.active_sink != null) {
            if (std.mem.eql(u8, name, self.active_sink.?)) {
                self.active_sink = null;
            } else return Error.ExpectedPropertyTag;
        } else if (std.mem.eql(u8, name, config.TAG_NAME_CHANNEL)) {
            self.state = .rss;
            self.depth -= config.DEPTH_STEP;
        } else return Error.ExpectedChannelTag,
        .item => if (self.active_property != .null) {
            if (std.mem.eql(u8, name, self.active_property.tagName())) {
                const target = self.data.activeChannel().activeItem().props.getPtr(
                    .fromGeneric(self.active_property),
                );
                try self.endProperty(target);
            } else return Error.ExpectedPropertyTag;
        } else if (self.active_sink != null) {
            if (std.mem.eql(u8, name, self.active_sink.?)) {
                self.active_sink = null;
            } else return Error.ExpectedPropertyTag;
        } else if (std.mem.eql(u8, name, config.TAG_NAME_ITEM)) {
            self.state = .channel;
            self.depth -= config.DEPTH_STEP;
        } else return Error.ExpectedItemTag,
        .end => return Error.ParsingEnded,
        .err => return,
    }
}

fn processAttrs(self: *@This(), atts: [*]const ?[*:0]const u8) ![]const Attr {
    const attrs_len = blk: {
        var n: usize = 0;
        while (atts[n] != null) : (n += 1) {}
        break :blk n;
    };
    if (attrs_len == 0) return &.{};
    const len = std.math.divExact(usize, attrs_len, 2) catch return Error.AttributeCountMismatch;
    const aa = self.arenaAllocator();
    const result = try aa.alloc(Attr, len);
    for (result, 0..) |*attr, n| {
        attr.name = try aa.dupe(u8, std.mem.span(atts[n * 2].?));
        attr.value = try aa.dupe(u8, std.mem.span(atts[n * 2 + 1].?));
        for (0..n) |m| if (std.mem.eql(u8, attr.name, result[m].name)) {
            return Error.DuplicateAttribute;
        };
    }
    return result;
}

fn startProperty(self: *@This(), name: []const u8, key: Data.Property, target: ?[]const u8) !bool {
    const tag_name = key.tagName();
    if (std.mem.eql(u8, name, tag_name)) {
        if (target != null) {
            std.log.err(
                "Parsing {t}: duplicate property {s}",
                .{ self.state, tag_name },
            );
            return Error.DuplicateProperty;
        }
        self.active_property = key;
        self.depth += config.DEPTH_STEP;
        return true;
    } else return false;
}

fn endProperty(self: *@This(), target: *?[]const u8) !void {
    assert(target.* == null);
    target.* = try self.arenaAllocator().dupe(u8, self.active_data.items);
    self.active_data.clearRetainingCapacity();
    self.active_property = .null;
    self.depth -= config.DEPTH_STEP;
}
