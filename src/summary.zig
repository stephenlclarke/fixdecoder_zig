const dictionary = @import("dictionary.zig");
const fix_message = @import("fix_message.zig");
const std = @import("std");

pub const SummaryTracker = struct {
    arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    records: std.StringHashMap(*OrderRecord),
    ordered_keys: std.ArrayList([]const u8),
    unknown_counter: usize,
    delimiter: []const u8,

    pub fn init(allocator: std.mem.Allocator, delimiter: []const u8) SummaryTracker {
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .allocator = allocator,
            .records = std.StringHashMap(*OrderRecord).init(allocator),
            .ordered_keys = .empty,
            .unknown_counter = 0,
            .delimiter = delimiter,
        };
    }

    pub fn deinit(self: *SummaryTracker) void {
        self.records.deinit();
        self.ordered_keys.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn record(self: *SummaryTracker, lookup: dictionary.Lookup, message: []const u8, fields: []const fix_message.FieldValue) !void {
        const key = try self.resolveKey(fields);
        var existing_record = self.records.get(key);
        if (existing_record == null) {
            const arena_allocator = self.arena.allocator();
            const new_record = try arena_allocator.create(OrderRecord);
            new_record.* = .{
                .key = try arena_allocator.dupe(u8, key),
                .order_id = null,
                .cl_ord_id = null,
                .orig_cl_ord_id = null,
                .symbol = null,
                .side = null,
                .order_qty = null,
                .cum_qty = null,
                .leaves_qty = null,
                .avg_px = null,
                .status = null,
                .raw_messages = .empty,
            };
            try self.records.put(new_record.key, new_record);
            try self.ordered_keys.append(self.allocator, new_record.key);
            existing_record = new_record;
        }
        const rec = existing_record.?;
        const arena_allocator = self.arena.allocator();
        rec.order_id = try dupMaybe(arena_allocator, fix_message.findTagValue(fields, 37));
        rec.cl_ord_id = try dupMaybe(arena_allocator, fix_message.findTagValue(fields, 11));
        rec.orig_cl_ord_id = try dupMaybe(arena_allocator, fix_message.findTagValue(fields, 41));
        rec.symbol = try dupMaybe(arena_allocator, fix_message.findTagValue(fields, 55));
        rec.side = try dupMaybe(arena_allocator, displayEnumOrValue(lookup, 54, fix_message.findTagValue(fields, 54)));
        rec.order_qty = try dupMaybe(arena_allocator, fix_message.findTagValue(fields, 38));
        rec.cum_qty = try dupMaybe(arena_allocator, fix_message.findTagValue(fields, 14));
        rec.leaves_qty = try dupMaybe(arena_allocator, fix_message.findTagValue(fields, 151));
        rec.avg_px = try dupMaybe(arena_allocator, fix_message.findTagValue(fields, 6));
        rec.status = try dupMaybe(arena_allocator, displayEnumOrValue(lookup, 39, fix_message.findTagValue(fields, 39)));
        const rendered = try fix_message.renderWithDelimiter(arena_allocator, message, self.delimiter);
        try rec.raw_messages.append(arena_allocator, rendered);
    }

    pub fn render(self: *SummaryTracker, writer: anytype) !void {
        try writer.writeAll("Order Summary\n");
        try writer.writeAll("=============\n\n");
        for (self.ordered_keys.items) |key| {
            const order_record = self.records.get(key).?;
            try writer.print("Order: {s}\n", .{order_record.key});
            if (order_record.order_id) |value| try writer.print("  OrderID: {s}\n", .{value});
            if (order_record.cl_ord_id) |value| try writer.print("  ClOrdID: {s}\n", .{value});
            if (order_record.orig_cl_ord_id) |value| try writer.print("  OrigClOrdID: {s}\n", .{value});
            if (order_record.symbol) |value| try writer.print("  Symbol: {s}\n", .{value});
            if (order_record.side) |value| try writer.print("  Side: {s}\n", .{value});
            if (order_record.order_qty) |value| try writer.print("  OrderQty: {s}\n", .{value});
            if (order_record.cum_qty) |value| try writer.print("  CumQty: {s}\n", .{value});
            if (order_record.leaves_qty) |value| try writer.print("  LeavesQty: {s}\n", .{value});
            if (order_record.avg_px) |value| try writer.print("  AvgPx: {s}\n", .{value});
            if (order_record.status) |value| try writer.print("  Status: {s}\n", .{value});
            if (order_record.raw_messages.items.len != 0) {
                try writer.writeAll("  Raw FIX messages:\n");
                for (order_record.raw_messages.items) |message| {
                    try writer.print("    {s}\n", .{message});
                }
            }
            try writer.writeByte('\n');
        }
    }

    fn resolveKey(self: *SummaryTracker, fields: []const fix_message.FieldValue) ![]const u8 {
        if (fix_message.findTagValue(fields, 37)) |value| return value;
        if (fix_message.findTagValue(fields, 11)) |value| return value;
        if (fix_message.findTagValue(fields, 41)) |value| return value;
        self.unknown_counter += 1;
        return try std.fmt.allocPrint(self.arena.allocator(), "UNKNOWN-{d}", .{self.unknown_counter});
    }
};

const OrderRecord = struct {
    key: []const u8,
    order_id: ?[]const u8,
    cl_ord_id: ?[]const u8,
    orig_cl_ord_id: ?[]const u8,
    symbol: ?[]const u8,
    side: ?[]const u8,
    order_qty: ?[]const u8,
    cum_qty: ?[]const u8,
    leaves_qty: ?[]const u8,
    avg_px: ?[]const u8,
    status: ?[]const u8,
    raw_messages: std.ArrayList([]const u8),
};

fn dupMaybe(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    if (value) |text| {
        return try allocator.dupe(u8, text);
    }
    return null;
}

fn displayEnumOrValue(lookup: dictionary.Lookup, tag: u32, value: ?[]const u8) ?[]const u8 {
    if (value) |raw| {
        return lookup.enumDescription(tag, raw) orelse raw;
    }
    return null;
}
