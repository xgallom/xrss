const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("expat.h");
});

pub const Data = @import("rss/Data.zig");
pub const Parse = @import("rss/Parse.zig");
pub const config = @import("rss/config.zig");

const XML_BUFFER_LENGTH = 512;

pub const Client = struct {
    parser: *Parse,
    xml_parser: c.XML_Parser,

    pub fn init(gpa: Allocator, aa: Allocator) !@This() {
        var self: @This() = .{
            .parser = try gpa.create(Parse),
            .xml_parser = c.XML_ParserCreate(null) orelse {
                std.log.err("Failed to create xml parser", .{});
                return error.XMLParserFailed;
            },
        };
        self.parser.* = .init(gpa, aa);
        errdefer self.deinit();
        c.XML_SetUserData(self.xml_parser, @ptrCast(self.parser));
        c.XML_SetElementHandler(self.xml_parser, &Parse.elementStart, &Parse.elementEnd);
        c.XML_SetCharacterDataHandler(self.xml_parser, &Parse.characterData);
        return self;
    }

    pub fn deinit(self: *@This()) void {
        const gpa = self.parser.gpaAllocator();
        self.parser.deinit();
        c.XML_ParserFree(self.xml_parser);
        gpa.destroy(self.parser);
    }

    pub fn parse(self: @This(), data: []const u8) !void {
        var body_reader: std.Io.Reader = .fixed(data);
        while (true) {
            const buf: [*]u8 = @ptrCast(c.XML_GetBuffer(self.xml_parser, XML_BUFFER_LENGTH) orelse {
                std.log.err("Failed obtaining xml buffer", .{});
                return error.XMLBufferFailed;
            });

            const len = try body_reader.readSliceShort(buf[0..XML_BUFFER_LENGTH]);
            const is_final = len == 0;

            if (c.XML_ParseBuffer(
                self.xml_parser,
                @intCast(len),
                @intFromBool(is_final),
            ) == c.XML_STATUS_ERROR) {
                std.log.err("XML parsing error at line {}, col {}: {s}", .{
                    c.XML_GetErrorLineNumber(self.xml_parser),
                    c.XML_GetErrorColumnNumber(self.xml_parser),
                    c.XML_ErrorString(c.XML_GetErrorCode(self.xml_parser)),
                });
                return error.XMLParsingError;
            }
            if (is_final) {
                if (self.parser.state == .err) return error.RSSParsingError;
                break;
            }
        }
    }
};
