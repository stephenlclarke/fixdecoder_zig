const builtins = @import("builtins.zig");
const std = @import("std");

pub const Source = union(enum) {
    builtin: []const u8,
    file: []const u8,
};

pub const ValueDef = struct {
    enumeration: []const u8,
    description: []const u8,
};

pub const FieldDef = struct {
    number: u32,
    name: []const u8,
    field_type: []const u8,
    values: []ValueDef,
};

pub const FieldRef = struct {
    name: []const u8,
    required: bool,
};

pub const ComponentRef = struct {
    name: []const u8,
    required: bool,
};

pub const GroupDef = struct {
    name: []const u8,
    required: bool,
    entries: []ContainerEntry,
};

pub const ContainerEntry = union(enum) {
    field: FieldRef,
    component: ComponentRef,
    group: GroupDef,
};

pub const MessageDef = struct {
    name: []const u8,
    msg_type: []const u8,
    msg_cat: []const u8,
    entries: []ContainerEntry,
};

pub const ComponentDef = struct {
    name: []const u8,
    entries: []ContainerEntry,
};

pub const Dictionary = struct {
    allocator: std.mem.Allocator,
    key: []const u8,
    source: Source,
    header: ComponentDef,
    trailer: ComponentDef,
    messages: []MessageDef,
    components: []ComponentDef,
    fields: []FieldDef,
    fields_by_tag: std.AutoHashMap(u32, usize),
    field_name_to_tag: std.StringHashMap(u32),
    message_name_to_index: std.StringHashMap(usize),
    msg_type_to_index: std.StringHashMap(usize),
    component_name_to_index: std.StringHashMap(usize),

    pub fn fieldByTag(self: *const Dictionary, tag: u32) ?*const FieldDef {
        const index = self.fields_by_tag.get(tag) orelse return null;
        return &self.fields[index];
    }

    pub fn fieldName(self: *const Dictionary, tag: u32) ?[]const u8 {
        const field = self.fieldByTag(tag) orelse return null;
        return field.name;
    }

    pub fn fieldType(self: *const Dictionary, tag: u32) ?[]const u8 {
        const field = self.fieldByTag(tag) orelse return null;
        return field.field_type;
    }

    pub fn enumDescription(self: *const Dictionary, tag: u32, value: []const u8) ?[]const u8 {
        const field = self.fieldByTag(tag) orelse return null;
        for (field.values) |entry| {
            if (std.mem.eql(u8, entry.enumeration, value)) {
                return entry.description;
            }
        }
        return null;
    }

    pub fn tagForFieldName(self: *const Dictionary, name: []const u8) ?u32 {
        return self.field_name_to_tag.get(name);
    }

    pub fn messageByName(self: *const Dictionary, name: []const u8) ?*const MessageDef {
        const index = self.message_name_to_index.get(name) orelse return null;
        return &self.messages[index];
    }

    pub fn messageByType(self: *const Dictionary, msg_type: []const u8) ?*const MessageDef {
        const index = self.msg_type_to_index.get(msg_type) orelse return null;
        return &self.messages[index];
    }

    pub fn messageByNameOrType(self: *const Dictionary, name_or_type: []const u8) ?*const MessageDef {
        return self.messageByName(name_or_type) orelse self.messageByType(name_or_type);
    }

    pub fn componentByName(self: *const Dictionary, name: []const u8) ?*const ComponentDef {
        const index = self.component_name_to_index.get(name) orelse return null;
        return &self.components[index];
    }
};

pub const Lookup = struct {
    primary_key: []const u8,
    primary: *const Dictionary,
    fallback_key: ?[]const u8 = null,
    fallback: ?*const Dictionary = null,

    pub fn fieldByTag(self: Lookup, tag: u32) ?*const FieldDef {
        return self.primary.fieldByTag(tag) orelse if (self.fallback) |fallback| fallback.fieldByTag(tag) else null;
    }

    pub fn fieldName(self: Lookup, tag: u32) ?[]const u8 {
        return self.primary.fieldName(tag) orelse if (self.fallback) |fallback| fallback.fieldName(tag) else null;
    }

    pub fn fieldType(self: Lookup, tag: u32) ?[]const u8 {
        return self.primary.fieldType(tag) orelse if (self.fallback) |fallback| fallback.fieldType(tag) else null;
    }

    pub fn enumDescription(self: Lookup, tag: u32, value: []const u8) ?[]const u8 {
        return self.primary.enumDescription(tag, value) orelse if (self.fallback) |fallback| fallback.enumDescription(tag, value) else null;
    }

    pub fn messageByType(self: Lookup, msg_type: []const u8) ?*const MessageDef {
        return self.primary.messageByType(msg_type) orelse if (self.fallback) |fallback| fallback.messageByType(msg_type) else null;
    }

    pub fn messageByNameOrType(self: Lookup, name_or_type: []const u8) ?*const MessageDef {
        return self.primary.messageByNameOrType(name_or_type) orelse if (self.fallback) |fallback| fallback.messageByNameOrType(name_or_type) else null;
    }

    pub fn componentByName(self: Lookup, name: []const u8) ?*const ComponentDef {
        return self.primary.componentByName(name) orelse if (self.fallback) |fallback| fallback.componentByName(name) else null;
    }

    pub fn isSensitiveTag(self: Lookup, tag: u32) bool {
        const name = self.fieldName(tag) orelse return false;
        return containsIgnoreCase(name, "CompID") or
            containsIgnoreCase(name, "SubID") or
            containsIgnoreCase(name, "LocationID") or
            containsIgnoreCase(name, "Username") or
            containsIgnoreCase(name, "Password") or
            containsIgnoreCase(name, "Account");
    }
};

pub const MessageMeta = struct {
    required_tags: []u32,
    ordered_tags: []u32,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    loaded: std.StringHashMap(*LoadedDictionary),
    custom: std.StringHashMap(*LoadedDictionary),
    loaded_items: std.ArrayList(*LoadedDictionary),

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .allocator = allocator,
            .loaded = std.StringHashMap(*LoadedDictionary).init(allocator),
            .custom = std.StringHashMap(*LoadedDictionary).init(allocator),
            .loaded_items = .empty,
        };
    }

    pub fn deinit(self: *Registry) void {
        for (self.loaded_items.items) |item| {
            item.arena.deinit();
            self.allocator.destroy(item);
        }
        self.loaded.deinit();
        self.custom.deinit();
        self.loaded_items.deinit(self.allocator);
    }

    pub fn registerXmlFile(self: *Registry, path: []const u8) !void {
        const bytes = try std.fs.cwd().readFileAlloc(self.allocator, path, 16 * 1024 * 1024);
        defer self.allocator.free(bytes);

        const loaded = try self.allocator.create(LoadedDictionary);
        loaded.* = .{
            .arena = std.heap.ArenaAllocator.init(self.allocator),
            .dict = undefined,
        };
        errdefer {
            loaded.arena.deinit();
            self.allocator.destroy(loaded);
        }
        const arena_allocator = loaded.arena.allocator();
        const path_copy = try arena_allocator.dupe(u8, path);
        const xml_copy = try arena_allocator.dupe(u8, bytes);
        loaded.dict = try parseDictionary(arena_allocator, xml_copy, .{ .file = path_copy });
        try self.custom.put(loaded.dict.key, loaded);
        try self.loaded_items.append(self.allocator, loaded);
    }

    pub fn getDictionary(self: *Registry, key: []const u8) !?*const Dictionary {
        const canonical = builtins.canonicalBuiltinKey(key);
        if (self.custom.get(canonical)) |loaded| {
            return &loaded.dict;
        }
        if (self.loaded.get(canonical)) |loaded| {
            return &loaded.dict;
        }
        const builtin = builtins.findBuiltin(canonical) orelse return null;
        const loaded = try self.allocator.create(LoadedDictionary);
        loaded.* = .{
            .arena = std.heap.ArenaAllocator.init(self.allocator),
            .dict = undefined,
        };
        errdefer {
            loaded.arena.deinit();
            self.allocator.destroy(loaded);
        }
        loaded.dict = try parseDictionary(loaded.arena.allocator(), builtin.xml, .{ .builtin = builtin.source });
        try self.loaded.put(canonical, loaded);
        try self.loaded_items.append(self.allocator, loaded);
        return &loaded.dict;
    }

    pub fn requireDictionary(self: *Registry, key: []const u8) !*const Dictionary {
        return (try self.getDictionary(key)) orelse error.UnknownDictionary;
    }

    pub fn hasKey(self: *Registry, key: []const u8) bool {
        const canonical = builtins.canonicalBuiltinKey(key);
        if (self.custom.contains(canonical)) {
            return true;
        }
        return builtins.findBuiltin(canonical) != null;
    }
};

const LoadedDictionary = struct {
    arena: std.heap.ArenaAllocator,
    dict: Dictionary,
};

pub fn normalizeFixKey(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var cleaned: std.ArrayList(u8) = .empty;
    defer cleaned.deinit(allocator);

    for (raw) |byte| {
        if (std.ascii.isWhitespace(byte) or byte == '.' or byte == '-' or byte == '_') {
            continue;
        }
        try cleaned.append(allocator, std.ascii.toUpper(byte));
    }

    if (cleaned.items.len == 0) {
        return error.InvalidFixVersion;
    }

    if (!std.mem.startsWith(u8, cleaned.items, "FIX")) {
        try cleaned.insertSlice(allocator, 0, "FIX");
    }

    return try allocator.dupe(u8, cleaned.items);
}

pub fn keyFromBeginString(begin_string: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, begin_string, "FIX.4.0")) return "FIX40";
    if (std.mem.eql(u8, begin_string, "FIX.4.1")) return "FIX41";
    if (std.mem.eql(u8, begin_string, "FIX.4.2")) return "FIX42";
    if (std.mem.eql(u8, begin_string, "FIX.4.3")) return "FIX43";
    if (std.mem.eql(u8, begin_string, "FIX.4.4")) return "FIX44";
    if (std.mem.eql(u8, begin_string, "FIX.5.0")) return "FIX50";
    if (std.mem.eql(u8, begin_string, "FIXT.1.1")) return "FIXT11";
    return null;
}

pub fn applVerIdToKey(value: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, value, "0")) return "FIX27";
    if (std.mem.eql(u8, value, "1")) return "FIX30";
    if (std.mem.eql(u8, value, "2")) return "FIX40";
    if (std.mem.eql(u8, value, "3")) return "FIX41";
    if (std.mem.eql(u8, value, "4")) return "FIX42";
    if (std.mem.eql(u8, value, "5")) return "FIX43";
    if (std.mem.eql(u8, value, "6")) return "FIX44";
    if (std.mem.eql(u8, value, "7")) return "FIX50";
    if (std.mem.eql(u8, value, "8")) return "FIX50SP1";
    if (std.mem.eql(u8, value, "9")) return "FIX50SP2";
    return null;
}

pub fn buildMessageMeta(allocator: std.mem.Allocator, lookup: Lookup, message: *const MessageDef) !MessageMeta {
    var required: std.ArrayList(u32) = .empty;
    var ordered: std.ArrayList(u32) = .empty;
    try appendEntriesMeta(allocator, lookup, lookup.primary.header.entries, &required, &ordered);
    try appendEntriesMeta(allocator, lookup, message.entries, &required, &ordered);
    try appendEntriesMeta(allocator, lookup, lookup.primary.trailer.entries, &required, &ordered);
    return .{
        .required_tags = try required.toOwnedSlice(allocator),
        .ordered_tags = try ordered.toOwnedSlice(allocator),
    };
}

fn appendEntriesMeta(
    allocator: std.mem.Allocator,
    lookup: Lookup,
    entries: []const ContainerEntry,
    required: *std.ArrayList(u32),
    ordered: *std.ArrayList(u32),
) !void {
    for (entries) |entry| {
        switch (entry) {
            .field => |field| {
                const tag = lookup.primary.tagForFieldName(field.name) orelse
                    if (lookup.fallback) |fallback| fallback.tagForFieldName(field.name) else null;
                if (tag) |resolved| {
                    try ordered.append(allocator, resolved);
                    if (field.required) {
                        try required.append(allocator, resolved);
                    }
                }
            },
            .component => |component| {
                const component_def = lookup.componentByName(component.name) orelse continue;
                try appendEntriesMeta(allocator, lookup, component_def.entries, required, ordered);
            },
            .group => |group| {
                const tag = lookup.primary.tagForFieldName(group.name) orelse
                    if (lookup.fallback) |fallback| fallback.tagForFieldName(group.name) else null;
                if (tag) |resolved| {
                    try ordered.append(allocator, resolved);
                    if (group.required) {
                        try required.append(allocator, resolved);
                    }
                }
            },
        }
    }
}

fn parseDictionary(allocator: std.mem.Allocator, xml: []const u8, source: Source) !Dictionary {
    var scanner = XmlScanner.init(xml);
    while (try scanner.next()) |token| {
        if (token.kind == .start and std.mem.eql(u8, token.name, "fix")) {
            return try parseFixRoot(allocator, &scanner, token, source);
        }
    }
    return error.InvalidXml;
}

fn parseFixRoot(
    allocator: std.mem.Allocator,
    scanner: *XmlScanner,
    token: XmlToken,
    source: Source,
) !Dictionary {
    var dictionary = Dictionary{
        .allocator = allocator,
        .key = try dictionaryKeyFromRoot(allocator, token.body),
        .source = source,
        .header = .{ .name = "Header", .entries = &.{} },
        .trailer = .{ .name = "Trailer", .entries = &.{} },
        .messages = &.{},
        .components = &.{},
        .fields = &.{},
        .fields_by_tag = std.AutoHashMap(u32, usize).init(allocator),
        .field_name_to_tag = std.StringHashMap(u32).init(allocator),
        .message_name_to_index = std.StringHashMap(usize).init(allocator),
        .msg_type_to_index = std.StringHashMap(usize).init(allocator),
        .component_name_to_index = std.StringHashMap(usize).init(allocator),
    };

    while (try scanner.next()) |next_token| {
        if (next_token.kind == .end and std.mem.eql(u8, next_token.name, "fix")) {
            break;
        }
        if (next_token.kind == .end) {
            continue;
        }

        if (std.mem.eql(u8, next_token.name, "header")) {
            dictionary.header = .{
                .name = "Header",
                .entries = if (next_token.kind == .empty) &.{} else try parseEntries(allocator, scanner, "header"),
            };
            continue;
        }
        if (std.mem.eql(u8, next_token.name, "trailer")) {
            dictionary.trailer = .{
                .name = "Trailer",
                .entries = if (next_token.kind == .empty) &.{} else try parseEntries(allocator, scanner, "trailer"),
            };
            continue;
        }
        if (std.mem.eql(u8, next_token.name, "messages")) {
            dictionary.messages = if (next_token.kind == .empty) &.{} else try parseMessages(allocator, scanner);
            continue;
        }
        if (std.mem.eql(u8, next_token.name, "components")) {
            dictionary.components = if (next_token.kind == .empty) &.{} else try parseComponents(allocator, scanner);
            continue;
        }
        if (std.mem.eql(u8, next_token.name, "fields")) {
            dictionary.fields = if (next_token.kind == .empty) &.{} else try parseFieldDefinitions(allocator, scanner);
            continue;
        }
        if (next_token.kind == .start) {
            try skipUntilEnd(scanner, next_token.name);
        }
    }

    try indexDictionary(&dictionary);
    return dictionary;
}

fn parseEntries(allocator: std.mem.Allocator, scanner: *XmlScanner, end_name: []const u8) ![]ContainerEntry {
    var entries: std.ArrayList(ContainerEntry) = .empty;
    while (try scanner.next()) |token| {
        if (token.kind == .end and std.mem.eql(u8, token.name, end_name)) {
            break;
        }
        if (token.kind == .end) {
            continue;
        }

        if (std.mem.eql(u8, token.name, "field")) {
            const field_name = attrValue(token.body, "name") orelse return error.InvalidXml;
            try entries.append(allocator, .{
                .field = .{
                    .name = field_name,
                    .required = attrRequired(token.body),
                },
            });
            if (token.kind == .start) {
                try skipUntilEnd(scanner, "field");
            }
            continue;
        }
        if (std.mem.eql(u8, token.name, "component")) {
            const component_name = attrValue(token.body, "name") orelse return error.InvalidXml;
            try entries.append(allocator, .{
                .component = .{
                    .name = component_name,
                    .required = attrRequired(token.body),
                },
            });
            if (token.kind == .start) {
                try skipUntilEnd(scanner, "component");
            }
            continue;
        }
        if (std.mem.eql(u8, token.name, "group")) {
            const group_name = attrValue(token.body, "name") orelse return error.InvalidXml;
            const group_entries: []ContainerEntry = if (token.kind == .empty) &.{} else try parseEntries(allocator, scanner, "group");
            try entries.append(allocator, .{
                .group = .{
                    .name = group_name,
                    .required = attrRequired(token.body),
                    .entries = group_entries,
                },
            });
            continue;
        }
        if (token.kind == .start) {
            try skipUntilEnd(scanner, token.name);
        }
    }
    return try entries.toOwnedSlice(allocator);
}

fn parseMessages(allocator: std.mem.Allocator, scanner: *XmlScanner) ![]MessageDef {
    var messages: std.ArrayList(MessageDef) = .empty;
    while (try scanner.next()) |token| {
        if (token.kind == .end and std.mem.eql(u8, token.name, "messages")) {
            break;
        }
        if (token.kind == .end) {
            continue;
        }
        if (!std.mem.eql(u8, token.name, "message")) {
            if (token.kind == .start) {
                try skipUntilEnd(scanner, token.name);
            }
            continue;
        }

        const name = attrValue(token.body, "name") orelse return error.InvalidXml;
        const msg_type = attrValue(token.body, "msgtype") orelse return error.InvalidXml;
        const msg_cat = attrValue(token.body, "msgcat") orelse "app";
        const entries: []ContainerEntry = if (token.kind == .empty) &.{} else try parseEntries(allocator, scanner, "message");
        try messages.append(allocator, .{
            .name = name,
            .msg_type = msg_type,
            .msg_cat = msg_cat,
            .entries = entries,
        });
    }
    return try messages.toOwnedSlice(allocator);
}

fn parseComponents(allocator: std.mem.Allocator, scanner: *XmlScanner) ![]ComponentDef {
    var components: std.ArrayList(ComponentDef) = .empty;
    while (try scanner.next()) |token| {
        if (token.kind == .end and std.mem.eql(u8, token.name, "components")) {
            break;
        }
        if (token.kind == .end) {
            continue;
        }
        if (!std.mem.eql(u8, token.name, "component")) {
            if (token.kind == .start) {
                try skipUntilEnd(scanner, token.name);
            }
            continue;
        }

        const name = attrValue(token.body, "name") orelse return error.InvalidXml;
        const entries: []ContainerEntry = if (token.kind == .empty) &.{} else try parseEntries(allocator, scanner, "component");
        try components.append(allocator, .{
            .name = name,
            .entries = entries,
        });
    }
    return try components.toOwnedSlice(allocator);
}

fn parseFieldDefinitions(allocator: std.mem.Allocator, scanner: *XmlScanner) ![]FieldDef {
    var fields: std.ArrayList(FieldDef) = .empty;
    while (try scanner.next()) |token| {
        if (token.kind == .end and std.mem.eql(u8, token.name, "fields")) {
            break;
        }
        if (token.kind == .end) {
            continue;
        }
        if (!std.mem.eql(u8, token.name, "field")) {
            if (token.kind == .start) {
                try skipUntilEnd(scanner, token.name);
            }
            continue;
        }

        const number_text = attrValue(token.body, "number") orelse return error.InvalidXml;
        const name = attrValue(token.body, "name") orelse return error.InvalidXml;
        const field_type = attrValue(token.body, "type") orelse "STRING";
        var values: std.ArrayList(ValueDef) = .empty;

        if (token.kind == .start) {
            while (try scanner.next()) |field_token| {
                if (field_token.kind == .end and std.mem.eql(u8, field_token.name, "field")) {
                    break;
                }
                if (field_token.kind == .end) {
                    continue;
                }
                if (std.mem.eql(u8, field_token.name, "value")) {
                    const enumeration = attrValue(field_token.body, "enum") orelse return error.InvalidXml;
                    const description = attrValue(field_token.body, "description") orelse "";
                    try values.append(allocator, .{
                        .enumeration = enumeration,
                        .description = description,
                    });
                    if (field_token.kind == .start) {
                        try skipUntilEnd(scanner, "value");
                    }
                    continue;
                }
                if (field_token.kind == .start) {
                    try skipUntilEnd(scanner, field_token.name);
                }
            }
        }

        try fields.append(allocator, .{
            .number = try std.fmt.parseUnsigned(u32, number_text, 10),
            .name = name,
            .field_type = field_type,
            .values = try values.toOwnedSlice(allocator),
        });
    }
    return try fields.toOwnedSlice(allocator);
}

fn indexDictionary(dictionary: *Dictionary) !void {
    for (dictionary.fields, 0..) |field, index| {
        try dictionary.fields_by_tag.put(field.number, index);
        try dictionary.field_name_to_tag.put(field.name, field.number);
    }
    for (dictionary.messages, 0..) |message, index| {
        try dictionary.message_name_to_index.put(message.name, index);
        try dictionary.msg_type_to_index.put(message.msg_type, index);
    }
    for (dictionary.components, 0..) |component, index| {
        try dictionary.component_name_to_index.put(component.name, index);
    }
}

fn dictionaryKeyFromRoot(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    const fix_type = attrValue(body, "type") orelse return error.InvalidXml;
    const major = attrValue(body, "major") orelse return error.InvalidXml;
    const minor = attrValue(body, "minor") orelse return error.InvalidXml;
    const service_pack = attrValue(body, "servicepack") orelse "0";

    if (std.mem.eql(u8, fix_type, "FIXT")) {
        return try allocator.dupe(u8, "FIXT11");
    }
    if (std.mem.eql(u8, major, "5") and std.mem.eql(u8, minor, "0")) {
        if (!std.mem.eql(u8, service_pack, "0")) {
            return try std.fmt.allocPrint(allocator, "FIX50SP{s}", .{service_pack});
        }
        return try allocator.dupe(u8, "FIX50");
    }
    return try std.fmt.allocPrint(allocator, "FIX{s}{s}", .{ major, minor });
}

fn skipUntilEnd(scanner: *XmlScanner, end_name: []const u8) !void {
    var depth: usize = 1;
    while (try scanner.next()) |token| {
        if (std.mem.eql(u8, token.name, end_name)) {
            switch (token.kind) {
                .start => depth += 1,
                .end => {
                    depth -= 1;
                    if (depth == 0) {
                        return;
                    }
                },
                .empty => {},
            }
        }
    }
}

fn attrRequired(body: []const u8) bool {
    const required = attrValue(body, "required") orelse return false;
    return std.ascii.eqlIgnoreCase(required, "Y");
}

fn attrValue(body: []const u8, key: []const u8) ?[]const u8 {
    var index: usize = 0;
    while (index < body.len and !isSpace(body[index])) : (index += 1) {}

    while (index < body.len) {
        while (index < body.len and isSpace(body[index])) : (index += 1) {}
        if (index >= body.len) {
            break;
        }
        const name_start = index;
        while (index < body.len and !isSpace(body[index]) and body[index] != '=') : (index += 1) {}
        const name_end = index;
        while (index < body.len and isSpace(body[index])) : (index += 1) {}
        if (index >= body.len or body[index] != '=') {
            break;
        }
        index += 1;
        while (index < body.len and isSpace(body[index])) : (index += 1) {}
        if (index >= body.len) {
            break;
        }
        const quote = body[index];
        if (quote != '"' and quote != '\'') {
            break;
        }
        index += 1;
        const value_start = index;
        while (index < body.len and body[index] != quote) : (index += 1) {}
        if (index >= body.len) {
            break;
        }
        const value = body[value_start..index];
        index += 1;
        if (std.mem.eql(u8, body[name_start..name_end], key)) {
            return value;
        }
    }
    return null;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) {
        return false;
    }
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[start .. start + needle.len], needle)) {
            return true;
        }
    }
    return false;
}

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\n' or byte == '\r' or byte == '\t';
}

const XmlScanner = struct {
    xml: []const u8,
    index: usize = 0,

    fn init(xml: []const u8) XmlScanner {
        return .{ .xml = xml };
    }

    fn next(self: *XmlScanner) !?XmlToken {
        while (self.index < self.xml.len) {
            const start = std.mem.indexOfScalarPos(u8, self.xml, self.index, '<') orelse return null;
            self.index = start + 1;
            if (self.index >= self.xml.len) {
                return null;
            }

            if (std.mem.startsWith(u8, self.xml[self.index - 1 ..], "<!--")) {
                const comment_end = std.mem.indexOfPos(u8, self.xml, self.index + 3, "-->") orelse return error.InvalidXml;
                self.index = comment_end + 3;
                continue;
            }

            const close = try self.findCloseAngle();
            var body = std.mem.trim(u8, self.xml[self.index..close], " \r\n\t");
            self.index = close + 1;
            if (body.len == 0) {
                continue;
            }
            if (body[0] == '?' or body[0] == '!') {
                continue;
            }

            var kind: XmlToken.Kind = .start;
            if (body[0] == '/') {
                kind = .end;
                body = std.mem.trim(u8, body[1..], " \r\n\t");
            } else if (body[body.len - 1] == '/') {
                kind = .empty;
                body = std.mem.trim(u8, body[0 .. body.len - 1], " \r\n\t");
            }

            const name_end = std.mem.indexOfAny(u8, body, " \r\n\t") orelse body.len;
            return XmlToken{
                .kind = kind,
                .name = body[0..name_end],
                .body = body,
            };
        }
        return null;
    }

    fn findCloseAngle(self: *XmlScanner) !usize {
        var idx = self.index;
        var quote: ?u8 = null;
        while (idx < self.xml.len) : (idx += 1) {
            const byte = self.xml[idx];
            if (quote) |quoted| {
                if (byte == quoted) {
                    quote = null;
                }
                continue;
            }
            if (byte == '"' or byte == '\'') {
                quote = byte;
                continue;
            }
            if (byte == '>') {
                return idx;
            }
        }
        return error.InvalidXml;
    }
};

const XmlToken = struct {
    const Kind = enum { start, end, empty };

    kind: Kind,
    name: []const u8,
    body: []const u8,
};

test "normalizes common FIX key spellings" {
    const allocator = std.testing.allocator;
    const key = try normalizeFixKey(allocator, "fix4.4");
    defer allocator.free(key);
    try std.testing.expectEqualStrings("FIX44", key);
}

test "parses a compact custom dictionary" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const xml =
        "<fix type='FIX' major='4' minor='4' servicepack='0'>\n" ++
        "  <header><field name='BeginString' required='Y'/></header>\n" ++
        "  <messages><message name='Heartbeat' msgtype='0' msgcat='admin'><field name='MsgType' required='Y'/></message></messages>\n" ++
        "  <components><component name='Header'><field name='MsgType' required='Y'/></component></components>\n" ++
        "  <fields>\n" ++
        "    <field number='8' name='BeginString' type='STRING'/>\n" ++
        "    <field number='35' name='MsgType' type='STRING'><value enum='0' description='HEARTBEAT'/></field>\n" ++
        "  </fields>\n" ++
        "</fix>";

    const loaded = try allocator.create(LoadedDictionary);
    defer allocator.destroy(loaded);
    loaded.* = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .dict = undefined,
    };
    defer loaded.arena.deinit();
    loaded.dict = try parseDictionary(loaded.arena.allocator(), xml, .{ .file = "test.xml" });

    try std.testing.expectEqualStrings("FIX44", loaded.dict.key);
    try std.testing.expectEqual(@as(usize, 2), loaded.dict.fields.len);
    try std.testing.expect(loaded.dict.messageByType("0") != null);
}
