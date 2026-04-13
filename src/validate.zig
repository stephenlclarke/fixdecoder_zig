const dictionary = @import("dictionary.zig");
const fix_message = @import("fix_message.zig");
const std = @import("std");

pub const ValidationReport = struct {
    arena: std.heap.ArenaAllocator,
    errors: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) ValidationReport {
        const arena = std.heap.ArenaAllocator.init(allocator);
        return .{
            .arena = arena,
            .errors = .empty,
        };
    }

    pub fn deinit(self: *ValidationReport) void {
        self.errors.deinit(self.arena.allocator());
        self.arena.deinit();
    }

    pub fn isClean(self: *const ValidationReport) bool {
        return self.errors.items.len == 0;
    }

    fn addError(self: *ValidationReport, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.allocPrint(self.arena.allocator(), fmt, args);
        try self.errors.append(self.arena.allocator(), text);
    }
};

pub fn validateMessage(
    allocator: std.mem.Allocator,
    message: []const u8,
    fields: []const fix_message.FieldValue,
    lookup: dictionary.Lookup,
) !ValidationReport {
    var report = ValidationReport.init(allocator);
    errdefer report.deinit();

    const msg_type = fix_message.findTagValue(fields, 35);
    if (msg_type == null) {
        try report.addError("Missing required tag 35 (MsgType)", .{});
    } else if (lookup.messageByType(msg_type.? ) == null) {
        try report.addError("Unknown MsgType: {s}", .{msg_type.?});
    }

    for (fields) |field| {
        const field_def = lookup.fieldByTag(field.tag);
        if (field_def == null) {
            try report.addError("Unknown tag {d}", .{field.tag});
            continue;
        }
        if (field_def.?.values.len != 0 and lookup.enumDescription(field.tag, field.value) == null) {
            try report.addError("Invalid enum for tag {d} ({s}): {s}", .{ field.tag, field_def.?.name, field.value });
        }
        try validateFieldType(&report, field_def.?.name, field.tag, field.value, field_def.?.field_type);
    }

    if (fix_message.bodyLengthField(message)) |body_length_text| {
        const expected = fix_message.computeBodyLength(message) orelse 0;
        const actual = std.fmt.parseUnsigned(usize, body_length_text, 10) catch 0;
        if (expected != actual) {
            try report.addError("Invalid BodyLength: expected {d}, got {d}", .{ expected, actual });
        }
    }

    if (fix_message.checksumField(message)) |checksum_text| {
        const expected_checksum = fix_message.computeChecksum(message) orelse 0;
        const actual_checksum = std.fmt.parseUnsigned(u8, checksum_text, 10) catch 0;
        if (expected_checksum != actual_checksum) {
            try report.addError("Invalid CheckSum: expected {d:0>3}, got {d:0>3}", .{ expected_checksum, actual_checksum });
        }
    }

    if (msg_type) |msg_type_value| {
        if (lookup.messageByType(msg_type_value)) |message_def| {
            const meta = try dictionary.buildMessageMeta(report.arena.allocator(), lookup, message_def);
            for (meta.required_tags) |tag| {
                if (fix_message.findTagValue(fields, tag) == null) {
                    try report.addError("Missing required tag {d} ({s})", .{ tag, lookup.fieldName(tag) orelse "Unknown" });
                }
            }
        }
    }

    return report;
}

fn validateFieldType(
    report: *ValidationReport,
    name: []const u8,
    tag: u32,
    value: []const u8,
    field_type: []const u8,
) !void {
    if (std.mem.eql(u8, field_type, "INT") or
        std.mem.eql(u8, field_type, "SEQNUM") or
        std.mem.eql(u8, field_type, "NUMINGROUP") or
        std.mem.eql(u8, field_type, "LENGTH"))
    {
        _ = std.fmt.parseUnsigned(i64, value, 10) catch {
            try report.addError("Invalid integer for tag {d} ({s}): {s}", .{ tag, name, value });
            return;
        };
        return;
    }

    if (std.mem.eql(u8, field_type, "FLOAT") or
        std.mem.eql(u8, field_type, "PRICE") or
        std.mem.eql(u8, field_type, "QTY") or
        std.mem.eql(u8, field_type, "AMT") or
        std.mem.eql(u8, field_type, "PERCENTAGE"))
    {
        _ = std.fmt.parseFloat(f64, value) catch {
            try report.addError("Invalid decimal for tag {d} ({s}): {s}", .{ tag, name, value });
            return;
        };
        return;
    }

    if (std.mem.eql(u8, field_type, "BOOLEAN")) {
        if (!std.mem.eql(u8, value, "Y") and !std.mem.eql(u8, value, "N")) {
            try report.addError("Invalid BOOLEAN for tag {d} ({s}): {s}", .{ tag, name, value });
        }
        return;
    }

    if (std.mem.eql(u8, field_type, "CHAR")) {
        if (std.unicode.utf8CountCodepoints(value) catch 0 != 1) {
            try report.addError("Invalid CHAR for tag {d} ({s}): {s}", .{ tag, name, value });
        }
        return;
    }

    if (std.mem.eql(u8, field_type, "UTCDATEONLY") or std.mem.eql(u8, field_type, "LOCALMKTDATE")) {
        if (!isEightDigits(value)) {
            try report.addError("Invalid date for tag {d} ({s}): {s}", .{ tag, name, value });
        }
        return;
    }

    if (std.mem.eql(u8, field_type, "UTCTIMEONLY")) {
        if (!looksLikeTime(value)) {
            try report.addError("Invalid time for tag {d} ({s}): {s}", .{ tag, name, value });
        }
        return;
    }

    if (std.mem.eql(u8, field_type, "UTCTIMESTAMP")) {
        if (!looksLikeTimestamp(value)) {
            try report.addError("Invalid timestamp for tag {d} ({s}): {s}", .{ tag, name, value });
        }
    }
}

fn isEightDigits(value: []const u8) bool {
    if (value.len != 8) return false;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

fn looksLikeTime(value: []const u8) bool {
    return value.len >= 8 and value[2] == ':' and value[5] == ':';
}

fn looksLikeTimestamp(value: []const u8) bool {
    return value.len >= 17 and value[8] == '-' and value[11] == ':' and value[14] == ':';
}

test "flags missing msg type" {
    const allocator = std.testing.allocator;
    const xml =
        "<fix type='FIX' major='4' minor='4' servicepack='0'>" ++
        "<header><field name='BeginString' required='Y'/></header>" ++
        "<messages><message name='Heartbeat' msgtype='0' msgcat='admin'><field name='MsgType' required='Y'/></message></messages>" ++
        "<components/>" ++
        "<fields><field number='8' name='BeginString' type='STRING'/><field number='35' name='MsgType' type='STRING'><value enum='0' description='HEARTBEAT'/></field></fields>" ++
        "</fix>";

    var registry = dictionary.Registry.init(allocator);
    defer registry.deinit();
    const loaded = try allocator.create(struct {
        arena: std.heap.ArenaAllocator,
        dict: dictionary.Dictionary,
    });
    defer allocator.destroy(loaded);
    loaded.* = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .dict = undefined,
    };
    defer loaded.arena.deinit();
    loaded.dict = try @import("dictionary.zig").parseDictionary(loaded.arena.allocator(), xml, .{ .file = "inline.xml" });

    const message = "8=FIX.4.4\x019=5\x0110=161\x01";
    const fields = try fix_message.parseFields(allocator, message);
    defer allocator.free(fields);

    const lookup = dictionary.Lookup{ .primary_key = "FIX44", .primary = &loaded.dict };
    var report = try validateMessage(allocator, message, fields, lookup);
    defer report.deinit();

    try std.testing.expect(!report.isClean());
}
