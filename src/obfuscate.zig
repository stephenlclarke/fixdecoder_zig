const dictionary = @import("dictionary.zig");
const std = @import("std");

pub const Obfuscator = struct {
    arena: std.heap.ArenaAllocator,
    enabled: bool,
    aliases: std.StringHashMap([]const u8),
    counters: std.AutoHashMap(u32, u32),

    pub fn init(allocator: std.mem.Allocator, enabled: bool) Obfuscator {
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .enabled = enabled,
            .aliases = std.StringHashMap([]const u8).init(allocator),
            .counters = std.AutoHashMap(u32, u32).init(allocator),
        };
    }

    pub fn deinit(self: *Obfuscator) void {
        self.aliases.deinit();
        self.counters.deinit();
        self.arena.deinit();
    }

    pub fn reset(self: *Obfuscator) void {
        self.aliases.clearRetainingCapacity();
        self.counters.clearRetainingCapacity();
        self.arena.deinit();
        self.arena = std.heap.ArenaAllocator.init(self.aliases.allocator);
    }

    pub fn displayValue(self: *Obfuscator, lookup: dictionary.Lookup, tag: u32, value: []const u8) ![]const u8 {
        if (!self.enabled or !lookup.isSensitiveTag(tag)) {
            return value;
        }
        const alias_key = try std.fmt.allocPrint(self.arena.allocator(), "{d}\x1f{s}", .{ tag, value });
        if (self.aliases.get(alias_key)) |existing| {
            return existing;
        }

        const field_name = lookup.fieldName(tag) orelse "Tag";
        const current = self.counters.get(tag) orelse 0;
        try self.counters.put(tag, current + 1);
        const alias = try std.fmt.allocPrint(self.arena.allocator(), "{s}{d:0>4}", .{ field_name, current + 1 });
        try self.aliases.put(alias_key, alias);
        return alias;
    }
};
