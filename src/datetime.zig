const std = @import("std");

pub const DateParseError = error{
    InvalidLength,
    InvalidMonth,
    UnsupportedTimeZone,
} || std.fmt.ParseIntError;

pub fn parseRfc1123ToNanos(date_str: []const u8) !i64 {
    // RFC 1123 strings are exactly 29 characters long.
    // Example: "Sat, 07 Sep 2002 09:42:31 GMT"
    if (date_str.len < 29 or date_str.len > 31) {
        std.log.err("{s}", .{date_str});
        return error.InvalidLength;
    }

    const day = try std.fmt.parseInt(u8, std.mem.trim(u8, date_str[5..7], " "), 10);

    // 2. Extract and match Month
    const month_str = date_str[8..11];
    const month: u8 = blk: {
        if (std.mem.eql(u8, month_str, "Jan")) break :blk 1;
        if (std.mem.eql(u8, month_str, "Feb")) break :blk 2;
        if (std.mem.eql(u8, month_str, "Mar")) break :blk 3;
        if (std.mem.eql(u8, month_str, "Apr")) break :blk 4;
        if (std.mem.eql(u8, month_str, "May")) break :blk 5;
        if (std.mem.eql(u8, month_str, "Jun")) break :blk 6;
        if (std.mem.eql(u8, month_str, "Jul")) break :blk 7;
        if (std.mem.eql(u8, month_str, "Aug")) break :blk 8;
        if (std.mem.eql(u8, month_str, "Sep")) break :blk 9;
        if (std.mem.eql(u8, month_str, "Oct")) break :blk 10;
        if (std.mem.eql(u8, month_str, "Nov")) break :blk 11;
        if (std.mem.eql(u8, month_str, "Dec")) break :blk 12;
        return error.InvalidMonth;
    };

    const year = try std.fmt.parseInt(u16, date_str[12..16], 10);
    const hour = try std.fmt.parseInt(u8, date_str[17..19], 10);
    const minute = try std.fmt.parseInt(u8, date_str[20..22], 10);
    const second = try std.fmt.parseInt(u8, date_str[23..25], 10);

    if (!std.mem.eql(u8, date_str[26..29], "GMT") and
        !(date_str.len == 31 and std.mem.eql(u8, date_str[26..31], "+0000")))
    {
        return error.UnsupportedTimeZone;
    }

    const epoch_seconds = datetimeToEpochSeconds(year, month, day, hour, minute, second);
    return epoch_seconds * std.time.ns_per_s;
}

/// Converts a civil datetime to Unix Epoch Seconds.
/// Uses Howard Hinnant's algorithm to perfectly account for leap years.
fn datetimeToEpochSeconds(year: u16, month: u8, day: u8, hour: u8, minute: u8, second: u8) i64 {
    var y: i32 = @intCast(year);
    const m: i32 = @intCast(month);
    const d: i32 = @intCast(day);

    // Shift the year to start in March so leap day is neatly at the end
    if (m <= 2) {
        y -= 1;
    }

    const era = @divFloor(y, 400);
    const yoe = y - era * 400; // Year of era [0, 399]
    const m_adj = if (m > 2) m - 3 else m + 9; // Month of year [0, 11]
    const doy = @divFloor(153 * m_adj + 2, 5) + d - 1; // Day of year [0, 365]

    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy; // Day of era

    // Days since Jan 1, 1970
    const days_since_epoch = @as(i64, era) * 146097 + @as(i64, doe) - 719468;

    // Convert days + time into total seconds
    var secs = days_since_epoch * 24 + @as(i64, hour);
    secs = secs * 60 + @as(i64, minute);
    secs = secs * 60 + @as(i64, second);

    return secs;
}

test parseRfc1123ToNanos {
    const timestamp_str = "Sat, 07 Sep 2002 09:42:31 GMT";
    const nanos = try parseRfc1123ToNanos(timestamp_str);

    try std.testing.expectEqual(nanos, 1031391751000000000);
}
