const build_options = @import("build_options");
const builtins = @import("builtins.zig");
const dictionary = @import("dictionary.zig");
const fix_message = @import("fix_message.zig");
const obfuscate = @import("obfuscate.zig");
const summary = @import("summary.zig");
const validate = @import("validate.zig");
const std = @import("std");

const c = @cImport({
    @cInclude("time.h");
});

const OutputStyle = struct {
    show_numbers: bool = false,
    show_header: bool = false,
    show_grid: bool = false,
};

const OptionalArg = struct {
    specified: bool = false,
    value: ?[]const u8 = null,
};

const Options = struct {
    fix_key: []const u8,
    fix_from_user: bool,
    xml_paths: [][]const u8,
    message: OptionalArg,
    component: OptionalArg,
    tag: OptionalArg,
    column: bool,
    verbose: bool,
    include_header: bool,
    include_trailer: bool,
    info: bool,
    secret: bool,
    validate: bool,
    style: OutputStyle,
    summary: bool,
    follow: bool,
    paging: ?[]const u8,
    pager: ?[]const u8,
    nowrap: bool,
    colour: ?[]const u8,
    delimiter: []const u8,
    files: [][]const u8,
};

pub fn run() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    var options_arena = std.heap.ArenaAllocator.init(allocator);
    defer options_arena.deinit();

    var stdout_file = std.fs.File.stdout();
    var stderr_file = std.fs.File.stderr();
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(&stdout_buffer);
    var stderr_writer = stderr_file.writer(&stderr_buffer);
    defer stdout_writer.interface.flush() catch {};
    defer stderr_writer.interface.flush() catch {};

    if (hasArg(args[1..], "--help") or hasArg(args[1..], "-h")) {
        try printHelp(&stdout_writer.interface);
        return;
    }
    if (hasArg(args[1..], "--version")) {
        try printVersion(&stdout_writer.interface);
        return;
    }

    const options = try parseOptions(options_arena.allocator(), args[1..]);
    if (options.follow) {
        return error.FollowModeNotImplemented;
    }

    var registry = dictionary.Registry.init(allocator);
    defer registry.deinit();
    for (options.xml_paths) |path| {
        try registry.registerXmlFile(path);
    }
    if (!registry.hasKey(options.fix_key)) {
        return error.UnknownDictionary;
    }

    const out = &stdout_writer.interface;
    const err = &stderr_writer.interface;

    if (try runQueryHandlers(allocator, out, err, &registry, options)) {
        return;
    }

    var obfuscator = obfuscate.Obfuscator.init(allocator, options.secret);
    defer obfuscator.deinit();

    var tracker = if (options.summary) summary.SummaryTracker.init(allocator, options.delimiter) else null;
    defer if (tracker) |*active| active.deinit();

    var session_arena = std.heap.ArenaAllocator.init(allocator);
    defer session_arena.deinit();
    var session_defaults = std.StringHashMap([]const u8).init(allocator);
    defer session_defaults.deinit();

    if (options.files.len == 0) {
        const stdin = std.fs.File.stdin();
        const bytes = try stdin.readToEndAlloc(allocator, 64 * 1024 * 1024);
        defer allocator.free(bytes);
        try processContent(
            allocator,
            out,
            err,
            &registry,
            options,
            null,
            null,
            bytes,
            if (tracker) |*active| active else null,
            &obfuscator,
            &session_defaults,
            session_arena.allocator(),
        );
    } else {
        for (options.files) |path| {
            obfuscator.reset();
            const file = try std.fs.cwd().openFile(path, .{});
            defer file.close();
            const stat = try file.stat();
            const bytes = try file.readToEndAlloc(allocator, 64 * 1024 * 1024);
            defer allocator.free(bytes);
            try processContent(
                allocator,
                out,
                err,
                &registry,
                options,
                path,
                stat.mtime,
                bytes,
                if (tracker) |*active| active else null,
                &obfuscator,
                &session_defaults,
                session_arena.allocator(),
            );
        }
    }

    if (tracker) |*active| {
        try active.render(out);
    }
}

fn parseOptions(allocator: std.mem.Allocator, args: []const []const u8) !Options {
    var xml_paths: std.ArrayList([]const u8) = .empty;
    var files: std.ArrayList([]const u8) = .empty;

    var fix_key: []const u8 = "FIX44";
    var fix_from_user = false;
    var message = OptionalArg{};
    var component = OptionalArg{};
    var tag = OptionalArg{};
    var column = false;
    var verbose = false;
    var include_header = false;
    var include_trailer = false;
    var info = false;
    var secret = false;
    var validation = false;
    var style = OutputStyle{};
    var summary_enabled = false;
    var follow = false;
    var paging: ?[]const u8 = null;
    var pager: ?[]const u8 = null;
    var nowrap = false;
    var colour: ?[]const u8 = null;
    var delimiter: []const u8 = "SOH";

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--column")) {
            column = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--header")) {
            include_header = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--trailer")) {
            include_trailer = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--info")) {
            info = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--secret")) {
            secret = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--validate")) {
            validation = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--summary")) {
            summary_enabled = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--nowrap")) {
            nowrap = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--number") or std.mem.eql(u8, arg, "-n")) {
            style.show_numbers = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--plain") or std.mem.eql(u8, arg, "-p")) {
            style = .{};
            continue;
        }
        if (std.mem.eql(u8, arg, "--follow") or std.mem.eql(u8, arg, "-f")) {
            follow = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--fix=")) {
            fix_key = try dictionary.normalizeFixKey(allocator, arg["--fix=".len..]);
            fix_from_user = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--fix")) {
            index += 1;
            if (index >= args.len) return error.MissingOptionValue;
            fix_key = try dictionary.normalizeFixKey(allocator, args[index]);
            fix_from_user = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--xml=")) {
            try xml_paths.append(allocator, try allocator.dupe(u8, arg["--xml=".len..]));
            continue;
        }
        if (std.mem.eql(u8, arg, "--xml")) {
            index += 1;
            if (index >= args.len) return error.MissingOptionValue;
            try xml_paths.append(allocator, try allocator.dupe(u8, args[index]));
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--style=")) {
            style = try parseStyle(arg["--style=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--style")) {
            index += 1;
            if (index >= args.len) return error.MissingOptionValue;
            style = try parseStyle(args[index]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--delimiter=")) {
            delimiter = try parseDelimiter(allocator, arg["--delimiter=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--delimiter")) {
            index += 1;
            if (index >= args.len) return error.MissingOptionValue;
            delimiter = try parseDelimiter(allocator, args[index]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--paging=")) {
            paging = try allocator.dupe(u8, arg["--paging=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--paging")) {
            index += 1;
            if (index >= args.len) return error.MissingOptionValue;
            paging = try allocator.dupe(u8, args[index]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--pager=")) {
            pager = try allocator.dupe(u8, arg["--pager=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--pager")) {
            index += 1;
            if (index >= args.len) return error.MissingOptionValue;
            pager = try allocator.dupe(u8, args[index]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--colour=") or std.mem.startsWith(u8, arg, "--color=")) {
            const value = if (std.mem.startsWith(u8, arg, "--colour=")) arg["--colour=".len..] else arg["--color=".len..];
            colour = try allocator.dupe(u8, value);
            continue;
        }
        if (std.mem.eql(u8, arg, "--colour") or std.mem.eql(u8, arg, "--color")) {
            colour = "yes";
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--message")) {
            message = try parseOptionalArg(allocator, args, &index, "--message", arg);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--component")) {
            component = try parseOptionalArg(allocator, args, &index, "--component", arg);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--tag")) {
            tag = try parseOptionalArg(allocator, args, &index, "--tag", arg);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownOption;
        }
        try files.append(allocator, try allocator.dupe(u8, arg));
    }

    return .{
        .fix_key = fix_key,
        .fix_from_user = fix_from_user,
        .xml_paths = try xml_paths.toOwnedSlice(allocator),
        .message = message,
        .component = component,
        .tag = tag,
        .column = column,
        .verbose = verbose,
        .include_header = include_header,
        .include_trailer = include_trailer,
        .info = info,
        .secret = secret,
        .validate = validation,
        .style = style,
        .summary = summary_enabled,
        .follow = follow,
        .paging = paging,
        .pager = pager,
        .nowrap = nowrap,
        .colour = colour,
        .delimiter = delimiter,
        .files = try files.toOwnedSlice(allocator),
    };
}

fn parseOptionalArg(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    index: *usize,
    long_name: []const u8,
    current: []const u8,
) !OptionalArg {
    if (std.mem.eql(u8, current, long_name)) {
        if (index.* + 1 < args.len and !std.mem.startsWith(u8, args[index.* + 1], "-")) {
            index.* += 1;
            return .{
                .specified = true,
                .value = try allocator.dupe(u8, args[index.*]),
            };
        }
        return .{ .specified = true, .value = null };
    }
    const prefix = try std.fmt.allocPrint(allocator, "{s}=", .{long_name});
    defer allocator.free(prefix);
    if (std.mem.startsWith(u8, current, prefix)) {
        return .{
            .specified = true,
            .value = try allocator.dupe(u8, current[prefix.len..]),
        };
    }
    return error.InvalidOptionalArgument;
}

fn parseStyle(raw: []const u8) !OutputStyle {
    var style = OutputStyle{};
    var iter = std.mem.splitScalar(u8, raw, ',');
    while (iter.next()) |part| {
        const value = std.mem.trim(u8, part, " \t\r\n");
        if (std.mem.eql(u8, value, "plain")) {
            style = .{};
        } else if (std.mem.eql(u8, value, "numbers")) {
            style.show_numbers = true;
        } else if (std.mem.eql(u8, value, "header")) {
            style.show_header = true;
        } else if (std.mem.eql(u8, value, "grid")) {
            style.show_grid = true;
        } else if (std.mem.eql(u8, value, "full")) {
            style = .{ .show_numbers = true, .show_header = true, .show_grid = true };
        } else {
            return error.InvalidStyle;
        }
    }
    return style;
}

fn parseDelimiter(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (std.ascii.eqlIgnoreCase(raw, "SOH") or std.mem.eql(u8, raw, "\\x01") or std.ascii.eqlIgnoreCase(raw, "0x01")) {
        return "SOH";
    }
    if (raw.len == 0) return error.InvalidDelimiter;
    return try allocator.dupe(u8, raw);
}

fn runQueryHandlers(
    allocator: std.mem.Allocator,
    writer: anytype,
    err_writer: anytype,
    registry: *dictionary.Registry,
    options: Options,
) !bool {
    _ = err_writer;
    if (options.info) {
        try renderInfo(writer, registry, options.fix_key);
        return true;
    }

    const base_lookup = dictionary.Lookup{
        .primary_key = options.fix_key,
        .primary = try registry.requireDictionary(options.fix_key),
    };

    if (options.message.specified) {
        try renderMessageQuery(allocator, writer, base_lookup, options);
        return true;
    }
    if (options.component.specified) {
        try renderComponentQuery(writer, base_lookup, options);
        return true;
    }
    if (options.tag.specified) {
        try renderTagQuery(writer, base_lookup, options);
        return true;
    }
    return false;
}

fn renderInfo(writer: anytype, registry: *dictionary.Registry, selected_key: []const u8) !void {
    try writer.writeAll("Available FIX Dictionaries\n");
    try writer.writeAll("==========================\n");
    for (builtins.builtin_dictionaries) |entry| {
        if (entry.alias_of) |alias| {
            try writer.print("  {s} (built-in alias of {s})\n", .{ entry.key, alias });
        } else {
            try writer.print("  {s}\n", .{entry.key});
        }
    }

    try writer.writeAll("\nLoaded dictionaries\n");
    try writer.writeAll("===================\n");
    for (builtins.builtin_dictionaries) |entry| {
        const dict = try registry.requireDictionary(entry.key);
        const marker = if (std.mem.eql(u8, entry.key, selected_key)) "*" else " ";
        if (entry.alias_of) |alias| {
            try writer.print("{s} {s}  fields={d} components={d} messages={d}  source=built-in alias of {s}\n", .{
                marker,
                entry.key,
                dict.fields.len,
                dict.components.len,
                dict.messages.len,
                alias,
            });
        } else {
            try writer.print("{s} {s}  fields={d} components={d} messages={d}  source={s}\n", .{
                marker,
                dict.key,
                dict.fields.len,
                dict.components.len,
                dict.messages.len,
                sourceLabel(dict.source),
            });
        }
    }
}

fn renderMessageQuery(allocator: std.mem.Allocator, writer: anytype, lookup: dictionary.Lookup, options: Options) !void {
    if (options.message.value == null) {
        var items: std.ArrayList([]const u8) = .empty;
        defer items.deinit(allocator);
        for (lookup.primary.messages) |message| {
            try items.append(allocator, message.name);
        }
        try renderList(writer, items.items, options.column);
        return;
    }

    const message = lookup.messageByNameOrType(options.message.value.?) orelse {
        try writer.print("Message not found: {s}\n", .{options.message.value.?});
        return;
    };

    try writer.print("Message: {s} ({s})\n", .{ message.name, message.msg_type });
    if (options.include_header) {
        try writer.writeAll("Header\n");
        try renderEntries(writer, lookup, lookup.primary.header.entries, 2, options.verbose);
    }
    try renderEntries(writer, lookup, message.entries, 2, options.verbose);
    if (options.include_trailer) {
        try writer.writeAll("Trailer\n");
        try renderEntries(writer, lookup, lookup.primary.trailer.entries, 2, options.verbose);
    }
}

fn renderComponentQuery(writer: anytype, lookup: dictionary.Lookup, options: Options) !void {
    if (options.component.value == null) {
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(std.heap.page_allocator);
        try names.append(std.heap.page_allocator, "Header");
        try names.append(std.heap.page_allocator, "Trailer");
        for (lookup.primary.components) |component| {
            try names.append(std.heap.page_allocator, component.name);
        }
        try renderList(writer, names.items, options.column);
        return;
    }

    const component_name = options.component.value.?;
    const component = if (std.mem.eql(u8, component_name, "Header"))
        &lookup.primary.header
    else if (std.mem.eql(u8, component_name, "Trailer"))
        &lookup.primary.trailer
    else
        lookup.componentByName(component_name) orelse {
            try writer.print("Component not found: {s}\n", .{component_name});
            return;
        };

    try writer.print("Component: {s}\n", .{component.name});
    try renderEntries(writer, lookup, component.entries, 2, options.verbose);
}

fn renderTagQuery(writer: anytype, lookup: dictionary.Lookup, options: Options) !void {
    if (options.tag.value == null) {
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(std.heap.page_allocator);
        for (lookup.primary.fields) |field| {
            try names.append(std.heap.page_allocator, field.name);
        }
        try renderList(writer, names.items, options.column);
        return;
    }

    const tag_number = std.fmt.parseUnsigned(u32, options.tag.value.?, 10) catch {
        return error.InvalidTag;
    };
    const field = lookup.fieldByTag(tag_number) orelse {
        try writer.print("Tag not found: {d}\n", .{tag_number});
        return;
    };
    try writer.print("Tag: {d} ({s})\n", .{ field.number, field.name });
    try writer.print("Type: {s}\n", .{field.field_type});
    if (field.values.len != 0) {
        try writer.writeAll("Values:\n");
        for (field.values) |value| {
            try writer.print("  {s} = {s}\n", .{ value.enumeration, value.description });
        }
    }
}

fn processContent(
    allocator: std.mem.Allocator,
    writer: anytype,
    err_writer: anytype,
    registry: *dictionary.Registry,
    options: Options,
    source_path: ?[]const u8,
    mtime_ns: ?i128,
    bytes: []const u8,
    tracker: ?*summary.SummaryTracker,
    obfuscator: *obfuscate.Obfuscator,
    session_defaults: *std.StringHashMap([]const u8),
    session_allocator: std.mem.Allocator,
) !void {
    _ = err_writer;
    if (source_path) |path| {
        try printFileBanner(allocator, writer, path, mtime_ns);
    }

    var line_number: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        line_number += 1;
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (line.len == 0) {
            continue;
        }

        const messages = try fix_message.extractMessages(allocator, line);
        defer allocator.free(messages);
        if (messages.len == 0) {
            continue;
        }

        for (messages) |message| {
            var msg_arena = std.heap.ArenaAllocator.init(allocator);
            defer msg_arena.deinit();
            const temp = msg_arena.allocator();
            const fields = try fix_message.parseFields(temp, message);
            const lookup = try lookupForMessage(temp, registry, options, fields, session_defaults);

            if (tracker) |active_tracker| {
                try active_tracker.record(lookup, message, fields);
            } else {
                if (options.validate) {
                    var validation_report = try validate.validateMessage(allocator, message, fields, lookup);
                    defer validation_report.deinit();
                    if (validation_report.isClean()) {
                        try recordSessionDefault(session_allocator, session_defaults, fields);
                        continue;
                    }
                    try renderDecodedMessage(
                        temp,
                        writer,
                        lookup,
                        message,
                        fields,
                        line_number,
                        options,
                        obfuscator,
                        validation_report.errors.items,
                    );
                } else {
                    try renderDecodedMessage(
                        temp,
                        writer,
                        lookup,
                        message,
                        fields,
                        line_number,
                        options,
                        obfuscator,
                        &.{},
                    );
                }
            }

            try recordSessionDefault(session_allocator, session_defaults, fields);
        }
    }
}

fn renderDecodedMessage(
    allocator: std.mem.Allocator,
    writer: anytype,
    lookup: dictionary.Lookup,
    message: []const u8,
    fields: []const fix_message.FieldValue,
    line_number: usize,
    options: Options,
    obfuscator: *obfuscate.Obfuscator,
    errors: []const []const u8,
) !void {
    if (options.style.show_grid) {
        try writer.writeAll("----------------------------------------------\n");
    }
    if (options.style.show_numbers) {
        const rendered = try fix_message.renderWithDelimiter(allocator, message, options.delimiter);
        try writer.print("{d: >6} | {s}\n", .{ line_number, rendered });
    }
    const msg_type = fix_message.findTagValue(fields, 35) orelse "?";
    const msg_name = if (lookup.messageByType(msg_type)) |message_def| message_def.name else "Unknown";
    try writer.print("Message Type: {s} ({s})\n", .{ msg_name, msg_type });
    for (fields) |field| {
        const field_name = lookup.fieldName(field.tag) orelse "UnknownTag";
        const display_value = try obfuscator.displayValue(lookup, field.tag, field.value);
        if (lookup.enumDescription(field.tag, field.value)) |enum_name| {
            try writer.print("  {d: >4} {s}: {s} ({s})\n", .{ field.tag, field_name, display_value, enum_name });
        } else {
            try writer.print("  {d: >4} {s}: {s}\n", .{ field.tag, field_name, display_value });
        }
    }
    if (errors.len != 0) {
        try writer.writeAll("Errors:\n");
        for (errors) |err| {
            try writer.print("  - {s}\n", .{err});
        }
    }
    try writer.writeByte('\n');
}

fn lookupForMessage(
    allocator: std.mem.Allocator,
    registry: *dictionary.Registry,
    options: Options,
    fields: []const fix_message.FieldValue,
    session_defaults: *std.StringHashMap([]const u8),
) !dictionary.Lookup {
    const begin_string = fix_message.findTagValue(fields, 8);
    var selected_key = options.fix_key;
    if (!options.fix_from_user) {
        if (begin_string) |value| {
            if (dictionary.keyFromBeginString(value)) |detected| {
                selected_key = detected;
            }
        }
    }

    if (begin_string != null and std.mem.eql(u8, begin_string.?, "FIXT.1.1")) {
        const session_dict = try registry.requireDictionary("FIXT11");
        var app_key: ?[]const u8 = null;
        if (fix_message.findTagValue(fields, 1128)) |appl_ver_id| {
            app_key = dictionary.applVerIdToKey(appl_ver_id);
        }
        if (app_key == null) {
            const session_key = try makeSessionKey(allocator, fields);
            app_key = session_defaults.get(session_key);
        }
        if (app_key == null and options.fix_from_user and !std.mem.eql(u8, options.fix_key, "FIXT11")) {
            app_key = options.fix_key;
        }
        if (app_key) |resolved| {
            return .{
                .primary_key = resolved,
                .primary = try registry.requireDictionary(resolved),
                .fallback_key = "FIXT11",
                .fallback = session_dict,
            };
        }
        return .{
            .primary_key = "FIXT11",
            .primary = session_dict,
        };
    }

    return .{
        .primary_key = selected_key,
        .primary = try registry.requireDictionary(selected_key),
    };
}

fn recordSessionDefault(
    allocator: std.mem.Allocator,
    session_defaults: *std.StringHashMap([]const u8),
    fields: []const fix_message.FieldValue,
) !void {
    const begin_string = fix_message.findTagValue(fields, 8) orelse return;
    if (!std.mem.eql(u8, begin_string, "FIXT.1.1")) {
        return;
    }
    const appl_ver_id = fix_message.findTagValue(fields, 1137) orelse return;
    const resolved = dictionary.applVerIdToKey(appl_ver_id) orelse return;
    const session_key = try makeSessionKey(allocator, fields);
    const stored_key = try allocator.dupe(u8, session_key);
    try session_defaults.put(stored_key, resolved);
}

fn makeSessionKey(allocator: std.mem.Allocator, fields: []const fix_message.FieldValue) ![]const u8 {
    const sender = fix_message.findTagValue(fields, 49) orelse "?";
    const target = fix_message.findTagValue(fields, 56) orelse "?";
    const sender_sub = fix_message.findTagValue(fields, 50) orelse "";
    const target_sub = fix_message.findTagValue(fields, 57) orelse "";
    return try std.fmt.allocPrint(allocator, "{s}|{s}|{s}|{s}", .{ sender, target, sender_sub, target_sub });
}

fn renderEntries(
    writer: anytype,
    lookup: dictionary.Lookup,
    entries: []const dictionary.ContainerEntry,
    indent: usize,
    verbose: bool,
) !void {
    for (entries) |entry| {
        try writeSpaces(writer, indent);
        switch (entry) {
            .field => |field| {
                const tag = lookup.primary.tagForFieldName(field.name) orelse if (lookup.fallback) |fallback| fallback.tagForFieldName(field.name) else null;
                if (tag) |resolved| {
                    try writer.print("{d} {s}", .{ resolved, field.name });
                } else {
                    try writer.print("{s}", .{field.name});
                }
                if (field.required) {
                    try writer.writeAll(" [required]");
                }
                try writer.writeByte('\n');
                if (verbose) {
                    const field_def = lookup.fieldByTag(tag orelse 0) orelse continue;
                    for (field_def.values) |value| {
                        try writeSpaces(writer, indent + 2);
                        try writer.print("{s} = {s}\n", .{ value.enumeration, value.description });
                    }
                }
            },
            .component => |component| {
                try writer.print("{s}", .{component.name});
                if (component.required) {
                    try writer.writeAll(" [required]");
                }
                try writer.writeByte('\n');
                if (verbose) {
                    if (lookup.componentByName(component.name)) |component_def| {
                        try renderEntries(writer, lookup, component_def.entries, indent + 2, verbose);
                    }
                }
            },
            .group => |group| {
                try writer.print("{s}", .{group.name});
                if (group.required) {
                    try writer.writeAll(" [required]");
                }
                try writer.writeByte('\n');
                try renderEntries(writer, lookup, group.entries, indent + 2, verbose);
            },
        }
    }
}

fn renderList(writer: anytype, items: []const []const u8, columns_enabled: bool) !void {
    if (!columns_enabled) {
        for (items) |item| {
            try writer.print("{s}\n", .{item});
        }
        return;
    }

    var max_len: usize = 0;
    for (items) |item| {
        max_len = @max(max_len, item.len);
    }
    const width = max_len + 2;
    const columns = @max(@as(usize, 1), 80 / @max(width, @as(usize, 1)));

    var index: usize = 0;
    while (index < items.len) : (index += columns) {
        var column: usize = 0;
        while (column < columns and index + column < items.len) : (column += 1) {
            const item = items[index + column];
            try writer.print("{s}", .{item});
            if (column + 1 < columns and index + column + 1 < items.len and item.len < width) {
                try writeSpaces(writer, width - item.len);
            }
        }
        try writer.writeByte('\n');
    }
}

fn printFileBanner(allocator: std.mem.Allocator, writer: anytype, path: []const u8, mtime_ns: ?i128) !void {
    const filename = std.fs.path.basename(path);
    const timestamp = try formatTimestamp(allocator, mtime_ns);
    defer allocator.free(timestamp);
    try writer.writeAll("----------------------------------------------\n");
    try writer.print("Filename: {s}\n", .{filename});
    try writer.print("Last Modified: {s}\n", .{timestamp});
    try writer.writeAll("----------------------------------------------\n\n");
}

fn formatTimestamp(allocator: std.mem.Allocator, mtime_ns: ?i128) ![]const u8 {
    if (mtime_ns == null) {
        return try allocator.dupe(u8, "unknown");
    }
    const total_ms: i64 = @intCast(@divFloor(mtime_ns.?, std.time.ns_per_ms));
    var seconds: c.time_t = @intCast(@divFloor(total_ms, 1000));
    const millis: u16 = @intCast(@mod(total_ms, 1000));
    var tm_value: c.struct_tm = undefined;
    _ = c.gmtime_r(&seconds, &tm_value);
    var buffer: [64]u8 = undefined;
    const count = c.strftime(&buffer, buffer.len, "%d/%m/%y %H:%M:%S", &tm_value);
    return try std.fmt.allocPrint(allocator, "{s}.{d:0>3}Z", .{ buffer[0..count], millis });
}

fn printHelp(writer: anytype) !void {
    try writer.writeAll(
        \\Usage: fixdecoder [OPTIONS] [FILE...]
        \\
        \\Options:
        \\  --fix <VER>           FIX dictionary to use (default: 44)
        \\  --xml <FILE>          Load a custom FIX XML dictionary
        \\  --message[=NAME]      List messages or show a specific message
        \\  --component[=NAME]    List components or show a specific component
        \\  --tag[=TAG]           List tags or show a specific tag
        \\  --info                Show available dictionaries
        \\  --validate            Validate decoded FIX messages
        \\  --summary             Summarise order state instead of full decode
        \\  --secret              Obfuscate sensitive FIX values
        \\  --style <STYLE>       plain,numbers,header,grid,full
        \\  --plain               Disable number/header/grid decorations
        \\  --number              Show input line numbers
        \\  --delimiter <CHAR>    Display delimiter for rendered raw FIX
        \\  --version             Print version information
        \\  --help                Print this help
        \\
    );
}

fn writeSpaces(writer: anytype, count: usize) !void {
    var remaining = count;
    const chunk = "                                ";
    while (remaining > 0) {
        const to_write = @min(remaining, chunk.len);
        try writer.writeAll(chunk[0..to_write]);
        remaining -= to_write;
    }
}

fn printVersion(writer: anytype) !void {
    try writer.print(
        "fixdecoder {s} (branch:{s}, commit:{s}) [zig:{d}.{d}.{d}]\n",
        .{
            build_options.app_version,
            build_options.git_branch,
            build_options.git_commit,
            @import("builtin").zig_version.major,
            @import("builtin").zig_version.minor,
            @import("builtin").zig_version.patch,
        },
    );
}

fn sourceLabel(source: dictionary.Source) []const u8 {
    return switch (source) {
        .builtin => |label| label,
        .file => |path| path,
    };
}

fn hasArg(args: []const []const u8, value: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, value)) {
            return true;
        }
    }
    return false;
}

test "parses style strings" {
    const style = try parseStyle("header,grid");
    try std.testing.expect(style.show_header);
    try std.testing.expect(style.show_grid);
    try std.testing.expect(!style.show_numbers);
}
