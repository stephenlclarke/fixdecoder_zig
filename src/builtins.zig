pub const BuiltinDictionary = struct {
    key: []const u8,
    alias_of: ?[]const u8 = null,
    xml: []const u8,
    source: []const u8,
};

pub const builtin_dictionaries = [_]BuiltinDictionary{
    .{ .key = "FIX27", .alias_of = "FIX40", .xml = @embedFile("resources/FIX40.xml"), .source = "resources/FIX40.xml" },
    .{ .key = "FIX30", .alias_of = "FIX40", .xml = @embedFile("resources/FIX40.xml"), .source = "resources/FIX40.xml" },
    .{ .key = "FIX40", .xml = @embedFile("resources/FIX40.xml"), .source = "resources/FIX40.xml" },
    .{ .key = "FIX41", .xml = @embedFile("resources/FIX41.xml"), .source = "resources/FIX41.xml" },
    .{ .key = "FIX42", .xml = @embedFile("resources/FIX42.xml"), .source = "resources/FIX42.xml" },
    .{ .key = "FIX43", .xml = @embedFile("resources/FIX43.xml"), .source = "resources/FIX43.xml" },
    .{ .key = "FIX44", .xml = @embedFile("resources/FIX44.xml"), .source = "resources/FIX44.xml" },
    .{ .key = "FIX50", .xml = @embedFile("resources/FIX50.xml"), .source = "resources/FIX50.xml" },
    .{ .key = "FIX50SP1", .xml = @embedFile("resources/FIX50SP1.xml"), .source = "resources/FIX50SP1.xml" },
    .{ .key = "FIX50SP2", .xml = @embedFile("resources/FIX50SP2.xml"), .source = "resources/FIX50SP2.xml" },
    .{ .key = "FIXT11", .xml = @embedFile("resources/FIXT11.xml"), .source = "resources/FIXT11.xml" },
};

pub fn findBuiltin(key: []const u8) ?BuiltinDictionary {
    for (builtin_dictionaries) |entry| {
        if (std.mem.eql(u8, entry.key, key)) {
            return entry;
        }
    }
    return null;
}

pub fn canonicalBuiltinKey(key: []const u8) []const u8 {
    if (findBuiltin(key)) |entry| {
        if (entry.alias_of) |alias| {
            return alias;
        }
    }
    return key;
}

const std = @import("std");
