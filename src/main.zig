const std = @import("std");
const mem = std.mem;
const fs = std.fs;

const Dir = fs.Dir;
const File = fs.File;
const Allocator = std.mem.Allocator;

const clap = @import("clap");
const knfo = @import("knfo");

const cwd = fs.cwd();
const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();

fn getenv(variable: []const u8) ?[]const u8 {
    for (std.os.environ) |entry| {
        var splitter = mem.splitSequence(u8, mem.span(entry), "=");
        if (splitter.next()) |key| {
            if (mem.eql(u8, key, variable)) return splitter.rest();
        }
    }
    return null;
}

pub fn main() anyerror!u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const lloc = arena.allocator();

    const options =
        \\-h,  --help               Display this help and exit.
        \\-t,  --jumptable   <str>  Override default jumptable.
        \\-T,  --dump-table         Print jumptable path to stdout and exit.
        \\-a,  --add         <str>  Add target directory to jumptable.
        \\-r,  --remove      <str>  Remove target directory from jumptable.
        \\<str>                     Change dir to fuzzy matched table entry.
    ;

    const shell = getenv("SHELL") orelse {
        stderr.print("The SHELL environment variable is not set.", .{}) catch {};
        return 4;
    };

    const params = comptime clap.parseParamsComptime(options);

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        diag.report(stderr, err) catch {};
        stderr.print("Use -h or --help to see usage.\n", .{}) catch {};
        return 1;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        stdout.print("jmp usage:\n{s}\n", .{options}) catch {};
        return 0;
    }

    const pwd = getenv("PWD") orelse cwd.realpathAlloc(lloc, ".") catch |err| {
        stderr.print(
            "Failed to obtain absolute path of current directory: {s}\n" ++
                "You can try to avoid this by defining PWD environment variable.\n",
            .{@errorName(err)},
        ) catch {};
        return 254;
    };

    const jumptable: File = open_jumptable: {
        if (res.args.jumptable) |override| {
            const absolute_table_path = if (fs.path.isAbsolute(override))
                override
            else
                fs.path.join(lloc, &.{ pwd, override }) catch {
                    stderr.print("Out of memory.\n", .{}) catch {};
                    return 176;
                };

            if (res.args.@"dump-table" != 0) {
                stdout.print("{s}\n", .{absolute_table_path}) catch {};
                return 0;
            }

            break :open_jumptable fs.createFileAbsolute(absolute_table_path, .{
                .read = true,
                .truncate = false,
            }) catch |err| {
                stderr.print(
                    "Can't access file \"{s}\": {s}\n",
                    .{ absolute_table_path, @errorName(err) },
                ) catch {};
                return 60;
            };
        }

        const locations_to_try = [_](struct {
            folder: knfo.KnownFolder,
            leaf: []const u8,
        }){
            .{ .folder = .local_configuration, .leaf = "jumpbuffer" },
            .{ .folder = .data, .leaf = "jumpbuffer" },
            .{ .folder = .home, .leaf = ".jumpbuffer" },
        };

        var absolute_paths: [locations_to_try.len]([]const u8) = undefined;

        for (locations_to_try, &absolute_paths) |entry, *path| {
            const dir = (knfo.getPath(lloc, entry.folder) catch |err| switch (err) {
                error.OutOfMemory => {
                    stderr.print("Out of memory.", .{}) catch {};
                    return 254;
                },
                error.ParseError => continue, // Error parsing environment variables
            }) orelse continue;
            const leaf = entry.leaf;

            const join_args = if (fs.path.isAbsolute(dir)) &.{ dir, leaf } else &.{ pwd, dir, leaf };
            path.* = fs.path.join(lloc, join_args) catch {
                stderr.print("Out of memory.\n", .{}) catch {};
                return 254;
            };
        }

        // Check if file exists and return it
        for (absolute_paths) |path| {
            const file = fs.openFileAbsolute(path, .{ .mode = .read_write }) catch |err| switch (err) {
                error.FileNotFound => continue, // Keep searching
                else => {
                    stderr.print("Can't access file \"{s}\": {s}\n", .{ path, @errorName(err) }) catch {};
                    return 60;
                },
            };

            if (res.args.@"dump-table" != 0) {
                stdout.print("{s}\n", .{path}) catch {};
                return 0;
            }

            break :open_jumptable file;
        }

        // Create file
        for (absolute_paths) |path| {
            const file = fs.createFileAbsolute(path, .{ .read = true, .truncate = false }) catch |err| switch (err) {
                else => {
                    stderr.print("Can't access file \"{s}\": {s}\n", .{ path, @errorName(err) }) catch {};
                    return 60;
                },
            };

            if (res.args.@"dump-table" != 0) {
                stdout.print("{s}\n", .{path}) catch {};
                return 0;
            }

            break :open_jumptable file;
        }

        stderr.print("No predefined location for jumpbuffer file." ++
            "Use the -t/--jumpbuffer option.", .{}) catch {};
        return 254;
    };
    defer jumptable.close();

    _ = arena.reset(.free_all);

    if (res.positionals.len == 0) {
        stderr.print("Must specify a path to jump into.\n", .{}) catch {};
        return 2;
    }

    const path = res.positionals[0];

    std.process.changeCurDir(path) catch |err| {
        stderr.print("Can't change diretory to {s}: {s}\n", .{ path, switch (err) {
            error.AccessDenied => "No permission to access this directory.",
            error.FileSystem => "Filesystem error.",
            error.SymLinkLoop => "Symlink loop detected.",
            error.NameTooLong => "Directory name is way too long.",
            error.FileNotFound => "No such file or directory.",
            error.SystemResources => "Not enough resources on system.",
            error.NotDir => "File is not a directory.",
            error.BadPathName => "Invalid path name.",
            error.InvalidUtf8 => "Pathname is not a valid utf-8 string.",
            error.Unexpected => "An unknown error code was returned. Spooky.",
        } }) catch {};
        return 3;
    };

    const err = std.process.execv(allocator, &.{shell});
    stderr.print("Can't execute {s}: {s}\n", .{ shell, switch (err) {
        error.OutOfMemory => "Out of memory.",
        error.SystemResources => "Not enough resources on system.",
        error.AccessDenied => "No permission to execute this.",
        error.InvalidExe => "Not a valid executable.",
        error.FileSystem => "Filesystem error.",
        error.IsDir => "This is a directory, not an executable.",
        error.FileNotFound => "No such file or directory.",
        error.NameTooLong => "Executable name is way too long.",
        error.NotDir => "Path to executable goes through a non-directory.",
        error.FileBusy => "File is busy.",
        error.ProcessFdQuotaExceeded => "Fd quota exceeded for process.",
        error.SystemFdQuotaExceeded => "Fd quota exceeded for system",
        error.Unexpected => "An unknown error code was returned. Spooky.",
    } }) catch {};

    return 255;
}
