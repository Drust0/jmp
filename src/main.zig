// TODO: proper error messages

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

fn canonicalPath(allocator: Allocator, path: []const u8) []const u8 {
    return cwd.realpathAlloc(allocator, path) catch |err| {
        stderr.print(
            "Error resolving the path \"{s}\": ({s}) {s}\n",
            .{ path, @errorName(err), switch (err) {
                error.AccessDenied => "Cant reach path because we have no permissions.",
                error.NameTooLong => "Path contains a component whose name is too long.",
                error.NotSupported => "Realpath is not supported on this system.",
                error.OutOfMemory => oom(),
                error.Unexpected => wtf(),
                else => "",
            } },
        ) catch {};
        std.process.exit(253);
    };
}

fn oom() noreturn {
    _ = stderr.write("Out of memory.") catch {};
    std.process.exit(254);
}

fn wtf() noreturn {
    _ = stderr.write("Unexpected error has occurred... spooky") catch {};
    std.process.exit(255);
}

fn flip(n: usize) f64 {
    return @as(f64, 1.0) / @as(f64, @floatFromInt(n));
}

// TODO: This can be done in O(n) space
fn stringDistance(allocator: Allocator, strA: []const u8, strB: []const u8) Allocator.Error!f64 {
    const H = strA.len + 1;
    const W = strB.len + 1;

    const matrix = try allocator.alloc(f64, W * H);
    defer allocator.free(matrix);

    // matrix[i * W + j] == stringDistance(strA[0..i], strB[0..j])

    matrix[0] = 0.0;

    var j: usize = 1;
    while (j < W) : (j += 1) {
        matrix[0 * W + j] = flip(j) + matrix[0 * W + (j - 1)];
    }

    var i: usize = 1;
    while (i < H) : (i += 1) {
        matrix[i * W + 0] = flip(i) + matrix[(i - 1) * W + 0];

        j = 1;
        while (j < W) : (j += 1) {
            matrix[i * W + j] = if (strA[i - 1] == strB[j - 1])
                matrix[(i - 1) * W + (j - 1)]
            else
                @min(
                    flip(i) + matrix[(i - 1) * W + j],
                    flip(j) + matrix[i * W + (j - 1)],
                );
        }
    }

    return matrix[matrix.len - 1];
}

pub fn main() u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const options =
        \\-h,  --help                   Display this help and exit.
        \\-t,  --jumptable   <PATH>     Override default jumptable.
        \\-T,  --locate-table           Print jumptable path to stdout and exit.
        \\-a,  --add         <PATH>     Add target directory to jumptable.
        \\-d,  --del         <PATH>     Delete target directory from jumptable.
        \\-v,  --verbose                Output fuzzy string distance calculations.
        \\-c,  --calculate   <PATTERN>  Print distance between arguments to stdout. 
        \\<PATTERN>                     Change dir to fuzzy matched table entry.
    ;

    const shell = getenv("SHELL") orelse {
        stderr.print("The SHELL environment variable is not set.", .{}) catch {};
        return 4;
    };

    const jump_depth: u8 = if (getenv("JUMP_DEPTH")) |depth| (std.fmt.parseInt(u8, depth, 10) catch 0) else 0;

    const params = comptime clap.parseParamsComptime(options);
    const parsers = comptime .{
        .PATH = clap.parsers.string,
        .PATTERN = clap.parsers.string,
    };

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        diag.report(stderr, err) catch {};
        stderr.print("Use '-h' or '--help' to see usage.\n", .{}) catch {};
        return 1;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        stdout.print("Usage: jmp [OPTION] [PATTERN]\n{s}\n", .{options}) catch {};
        return 0;
    }

    const jumptable: File = open_jumptable: {
        const creat = File.CreateFlags{ .read = true, .truncate = false };

        if (res.args.jumptable) |path| {
            const file = cwd.createFile(path, creat) catch |err| {
                stderr.print(
                    "Can't access jumptable file \"{s}\" for creation: ({s}) {s}\n",
                    .{ path, @errorName(err), switch (err) {
                        error.Unexpected => wtf(),
                        else => "",
                    } },
                ) catch {};
                return 60;
            };

            if (res.args.@"locate-table" != 0) {
                file.close();
                const canonical_path = canonicalPath(allocator, path);
                defer allocator.free(canonical_path);
                stdout.print("{s}\n", .{canonical_path}) catch {};
                return 0;
            }

            break :open_jumptable file;
        }

        const knfo_predefined = .{
            .{ .data, "jumptable" },
            .{ .local_configuration, "jumptable" },
            .{ .roaming_configuration, "jumptable" },
            .{ .home, ".jumptable" },
        };

        var folders = std.ArrayList(Dir).init(allocator);
        var leaves = std.ArrayList([]const u8).init(allocator);
        var dirpath = std.ArrayList([]const u8).init(allocator);

        defer {
            for (folders.items) |*folder| folder.close();
            for (dirpath.items) |dpath| allocator.free(dpath);
            folders.deinit();
            leaves.deinit();
            dirpath.deinit();
        }

        inline for (knfo_predefined) |entry| {
            const dir: ?Dir = knfo.open(allocator, entry[0], .{}) catch null;
            if (dir) |actual_dir| {
                const pathname = knfo.getPath(allocator, entry[0]) catch |err| switch (err) {
                    error.OutOfMemory => oom(),
                    error.ParseError => unreachable,
                } orelse unreachable;

                folders.append(actual_dir) catch oom();
                leaves.append(entry[1]) catch oom();
                dirpath.append(pathname) catch oom();
            }
        }

        var file: ?File = null;
        var filepath: ?[]const u8 = null;
        defer if (filepath) |af| allocator.free(af);

        // Try to find the file to open
        for (folders.items, leaves.items, dirpath.items) |*folder, leaf, dpath| {
            if (file != null) break;
            file = folder.openFile(leaf, .{ .mode = .read_write }) catch null;
            if (file != null) filepath = fs.path.join(allocator, &.{ dpath, leaf }) catch oom();
        }

        // If we didn't find a file, loop again and try to create it
        for (folders.items, leaves.items, dirpath.items) |*folder, leaf, dpath| {
            if (file != null) break;
            file = folder.createFile(leaf, creat) catch null;
            if (file != null) filepath = fs.path.join(allocator, &.{ dpath, leaf }) catch oom();
        }

        if (file) |*actual_file| {
            if (res.args.@"locate-table" != 0) {
                actual_file.close();
                const canonical_path = canonicalPath(allocator, filepath.?);
                defer allocator.free(canonical_path);
                stdout.print("{s}\n", .{canonical_path}) catch {};
                return 0;
            }

            break :open_jumptable actual_file.*;
        }

        stderr.print("No predefined location for jumptable is avaiable on the system.\n" ++
            "Use '-t' or '--jumptable' to provide one.\n", .{}) catch {};
        return 120;
    };
    defer jumptable.close();

    const data = jumptable.readToEndAlloc(allocator, 1 << 20) catch |err| {
        stderr.print("Error reading jumptable file: {s}.\n", .{@errorName(err)}) catch {};
        return 10;
    };
    defer allocator.free(data);

    if (res.args.add) |path| {
        const canonical_path = canonicalPath(allocator, path);
        defer allocator.free(canonical_path);

        jumptable.writer().print("{s}\n", .{canonical_path}) catch |err| {
            stderr.print("Can't write the new path to jumptable: {s}\n", .{switch (err) {
                else => @errorName(err),
                error.Unexpected => wtf(),
            }}) catch {};
            return 13;
        };

        return 0;
    }

    if (res.args.del) |path| {
        const canonical_path = canonicalPath(allocator, path);
        defer allocator.free(canonical_path);

        jumptable.seekBy(-@as(i64, @intCast(data.len))) catch |err| {
            stderr.print("Can't seek the jumptable: {s}\n", .{switch (err) {
                else => @errorName(err),
                error.Unexpected => wtf(),
            }}) catch {};
        };

        jumptable.setEndPos(0) catch |err| {
            stderr.print("Can't truncate the jumptable: {s}\n", .{switch (err) {
                else => @errorName(err),
                error.Unexpected => wtf(),
            }}) catch {};
        };

        var iter = mem.splitSequence(u8, data, "\n");
        while (iter.next()) |line| {
            if (line.len == 0) continue;

            if (!fs.path.isAbsolute(line)) {
                stderr.print("jumptable: not an absolute path: {s}\n", .{line}) catch {};
                continue;
            }

            if (!std.mem.eql(u8, canonical_path, line)) {
                jumptable.writer().print("{s}\n", .{line}) catch |err| {
                    stderr.print("Failed to write to jumptable: {s}\n", .{switch (err) {
                        else => @errorName(err),
                        error.Unexpected => wtf(),
                    }}) catch {};
                    return 14;
                };
            }
        }

        return 0;
    }

    if (res.positionals.len == 0) {
        stderr.print("Must provide a pattern to jump into.\n", .{}) catch {};
        return 2;
    }

    const pattern = res.positionals[0];

    if (res.args.calculate) |leaf| {
        const dist = stringDistance(allocator, leaf, pattern) catch oom();
        stdout.print("{d}\n", .{dist}) catch {};
        return 0;
    }

    const path = fuzzy_match: {
        var iter = mem.splitSequence(u8, data, "\n");

        var min_line: []const u8 = &.{};
        var min_dist: f64 = 99999999999.0;

        if (res.args.verbose != 0)
            stdout.print("pattern: \"{s}\"\n", .{pattern}) catch {};

        while (iter.next()) |line| {
            if (line.len == 0) continue;

            if (!fs.path.isAbsolute(line)) {
                stderr.print("jumptable: not an absolute path: \"{s}\"\n", .{line}) catch {};
                continue;
            }

            const leaf = fs.path.basename(line);
            const dist: f64 = stringDistance(allocator, leaf, pattern) catch oom();

            if (res.args.verbose != 0)
                stdout.print("leaf: \"{s}\" distance: \"{d}\"\n", .{ leaf, dist }) catch {};

            if (dist == 0 and res.args.verbose == 0) break :fuzzy_match line;

            if (dist < min_dist) {
                min_line = line;
                min_dist = dist;
            }
        }

        break :fuzzy_match min_line;
    };

    if (path.len == 0) {
        stderr.print("No match has been found. Your jumptable is empty.\n" ++
            "Add an entry to the table with 'jmp -a <PATH>'\n", .{}) catch {};
        return 7;
    }

    std.process.changeCurDir(path) catch |err| {
        stderr.print("Can't change diretory to \"{s}\": {s}\n", .{ path, switch (err) {
            error.AccessDenied => "No permission to access this directory.",
            error.FileSystem => "Filesystem error.",
            error.SymLinkLoop => "Symlink loop detected.",
            error.NameTooLong => "Directory name is way too long.",
            error.FileNotFound => "No such file or directory.",
            error.SystemResources => "Not enough resources on system.",
            error.NotDir => "File is not a directory.",
            error.BadPathName => "Invalid path name.",
            error.InvalidUtf8 => "Pathname is not a valid utf-8 string.",
            error.Unexpected => wtf(),
        } }) catch {};
        return 23;
    };

    var new_environ = std.process.getEnvMap(allocator) catch oom();
    defer new_environ.deinit();
    const value = std.fmt.allocPrint(allocator, "{d}", .{jump_depth + 1}) catch oom();
    defer allocator.free(value);
    new_environ.put("JUMP_DEPTH", value) catch oom();

    const err = std.process.execve(allocator, &.{shell}, &new_environ);
    stderr.print("Can't execute {s}: {s}\n", .{ shell, switch (err) {
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
        error.Unexpected => wtf(),
        error.OutOfMemory => oom(),
    } }) catch {};

    return 11;
}
