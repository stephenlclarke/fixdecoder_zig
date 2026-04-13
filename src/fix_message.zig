const std = @import("std");

pub const SOH: u8 = 0x01;

pub const FieldValue = struct {
    tag: u32,
    value: []const u8,
};

pub fn parseFields(allocator: std.mem.Allocator, message: []const u8) ![]FieldValue {
    var fields: std.ArrayList(FieldValue) = .empty;
    var iter = std.mem.splitScalar(u8, message, SOH);
    while (iter.next()) |fragment| {
        if (fragment.len == 0) {
            continue;
        }
        const eq_idx = std.mem.indexOfScalar(u8, fragment, '=') orelse continue;
        const tag_text = fragment[0..eq_idx];
        const value = fragment[eq_idx + 1 ..];
        const tag = std.fmt.parseUnsigned(u32, tag_text, 10) catch continue;
        try fields.append(allocator, .{ .tag = tag, .value = value });
    }
    return try fields.toOwnedSlice(allocator);
}

pub fn extractMessages(allocator: std.mem.Allocator, line: []const u8) ![][]const u8 {
    var messages: std.ArrayList([]const u8) = .empty;
    var start_at: usize = 0;
    while (true) {
        const start_rel = std.mem.indexOfPos(u8, line, start_at, "8=FIX") orelse break;
        const trailer_start = findChecksumTag(line, start_rel) orelse break;
        const message_end = trailer_start + 8;
        if (message_end > line.len) {
            break;
        }
        try messages.append(allocator, line[start_rel..message_end]);
        start_at = message_end;
    }
    return try messages.toOwnedSlice(allocator);
}

pub fn findTagValue(fields: []const FieldValue, tag: u32) ?[]const u8 {
    for (fields) |field| {
        if (field.tag == tag) {
            return field.value;
        }
    }
    return null;
}

pub fn computeChecksum(message: []const u8) ?u8 {
    const trailer_start = std.mem.indexOf(u8, message, "\x0110=") orelse return null;
    var sum: usize = 0;
    for (message[0 .. trailer_start + 1]) |byte| {
        sum += byte;
    }
    return @intCast(sum % 256);
}

pub fn checksumField(message: []const u8) ?[]const u8 {
    const trailer_start = std.mem.indexOf(u8, message, "\x0110=") orelse return null;
    const checksum_value_start = trailer_start + 4;
    if (checksum_value_start + 3 > message.len) {
        return null;
    }
    return message[checksum_value_start .. checksum_value_start + 3];
}

pub fn computeBodyLength(message: []const u8) ?usize {
    const body_tag_start = std.mem.indexOf(u8, message, "\x019=") orelse return null;
    const body_value_end_rel = std.mem.indexOfScalarPos(u8, message, body_tag_start + 3, SOH) orelse return null;
    const checksum_tag_start = std.mem.indexOf(u8, message, "\x0110=") orelse return null;
    if (checksum_tag_start <= body_value_end_rel) {
        return null;
    }
    return checksum_tag_start - (body_value_end_rel + 1);
}

pub fn bodyLengthField(message: []const u8) ?[]const u8 {
    const body_tag_start = std.mem.indexOf(u8, message, "\x019=") orelse return null;
    const body_value_start = body_tag_start + 3;
    const body_value_end = std.mem.indexOfScalarPos(u8, message, body_value_start, SOH) orelse return null;
    return message[body_value_start..body_value_end];
}

pub fn renderWithDelimiter(allocator: std.mem.Allocator, message: []const u8, delimiter: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (message) |byte| {
        if (byte == SOH) {
            try out.appendSlice(allocator, delimiter);
        } else {
            try out.append(allocator, byte);
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn findChecksumTag(line: []const u8, start: usize) ?usize {
    var pos = start;
    while (pos + 8 <= line.len) : (pos += 1) {
        if (line[pos] != SOH) {
            continue;
        }
        if (!std.mem.eql(u8, line[pos .. pos + 4], "\x0110=")) {
            continue;
        }
        if (pos + 8 > line.len) {
            return null;
        }
        if (!std.ascii.isDigit(line[pos + 4]) or !std.ascii.isDigit(line[pos + 5]) or !std.ascii.isDigit(line[pos + 6])) {
            continue;
        }
        if (line[pos + 7] != SOH) {
            continue;
        }
        return pos;
    }
    return null;
}

test "parses a basic FIX message" {
    const allocator = std.testing.allocator;
    const message = "8=FIX.4.4\x019=5\x0135=0\x0110=000\x01";
    const fields = try parseFields(allocator, message);
    defer allocator.free(fields);

    try std.testing.expectEqual(@as(usize, 4), fields.len);
    try std.testing.expectEqual(@as(u32, 35), fields[2].tag);
    try std.testing.expectEqualStrings("0", fields[2].value);
}

test "extracts embedded FIX messages from a log line" {
    const allocator = std.testing.allocator;
    const line = "before 8=FIX.4.4\x019=5\x0135=0\x0110=161\x01 after";
    const messages = try extractMessages(allocator, line);
    defer allocator.free(messages);

    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expect(std.mem.startsWith(u8, messages[0], "8=FIX.4.4"));
}
