const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const proc = std.process;

const Dir = fs.Dir;
const File = fs.File;
const Allocator = std.mem.Allocator;

const clap = @import("clap");
const knfo = @import("knfo");

const cwd = fs.cwd();
const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();

fn flip(n: usize) f64 {
    return @as(f64, 1.0) / @as(f64, @floatFromInt(n));
}

fn stringDistance(allocator: Allocator, strA: []const u8, strB: []const u8) Allocator.Error!f64 {

    // To minimize memory usage always make the second argument the smallest
    var sA = strA;
    var sB = strB;
    if (sB.len > sA.len) {
        sA = strB;
        sB = strA;
    }

    const H = sA.len + 1;
    const W = sB.len + 1;

    var oldrow = try allocator.alloc(f64, W);
    var newrow = try allocator.alloc(f64, W);
    defer {
        allocator.free(oldrow);
        allocator.free(newrow);
    }

    oldrow[0] = 0.0;

    var j: usize = 1;
    while (j < W) : (j += 1) {
        oldrow[j] = flip(j) + oldrow[j - 1];
    }

    var i: usize = 1;
    while (i < H) : (i += 1) {
        newrow[0] = flip(i) + oldrow[0];

        j = 1;
        while (j < W) : (j += 1) {
            newrow[j] = if (sA[i - 1] == sB[j - 1])
                oldrow[j - 1]
            else
                @min(
                    flip(i) + oldrow[j],
                    flip(j) + newrow[j - 1],
                );
        }

        const temp = oldrow;
        oldrow = newrow;
        newrow = temp;
    }

    return oldrow[oldrow.len - 1];
}

test "stringDistance" {
    const tst = std.testing;

    const test_samples = .{
        .{ "Zig", "is", "awesome" },
        .{ "red", "blue", "green" },
        .{ "father", "son", "holy spirit" },
        .{ "bulbasaur", "charmander", "squirtle" },
        .{ "six", "Seven", "8" },
        .{ "hlaalu", "redoran", "telvanni" },
    };

    const dist = stringDistance;
    const lloc = tst.allocator;

    // Test wether stringDistance is a metric
    inline for (test_samples) |sample| {
        inline for (sample) |sv| {
            // dist(str, str) = 0
            try tst.expect(try dist(lloc, sv, sv) == 0.0);
            // dist(str, str[0+1..str.len]) = 1
            try tst.expect(try dist(lloc, sv, sv[0 + 1 .. sv.len]) == 1.0);
            // dist(str, str[0..str.len-1]) = 1/(str.len)
            try tst.expect(try dist(lloc, sv, sv[0 .. sv.len - 1]) == flip(sv.len));
        }

        // Distance is symmetric
        try tst.expect(try dist(lloc, sample[0], sample[1]) == try dist(lloc, sample[1], sample[0]));
        try tst.expect(try dist(lloc, sample[1], sample[2]) == try dist(lloc, sample[2], sample[1]));
        try tst.expect(try dist(lloc, sample[2], sample[0]) == try dist(lloc, sample[0], sample[2]));

        // Triangular inequality
        try tst.expect(try dist(lloc, sample[0], sample[1]) +
            try dist(lloc, sample[1], sample[2]) >=
            try dist(lloc, sample[0], sample[2]));
        try tst.expect(try dist(lloc, sample[0], sample[2]) +
            try dist(lloc, sample[2], sample[1]) >=
            try dist(lloc, sample[0], sample[1]));
        try tst.expect(try dist(lloc, sample[1], sample[0]) +
            try dist(lloc, sample[0], sample[2]) >=
            try dist(lloc, sample[1], sample[2]));
    }
}

fn canonicalPath(allocator: Allocator, path: []const u8) []const u8 {
    return cwd.realpathAlloc(allocator, path) catch |err| {
        stderr.print("Error resolving the path \"{s}\": {s}\n", .{ path, @errorName(err) }) catch {};
        proc.exit(100);
    };
}

fn oom() noreturn {
    _ = stderr.write("Out of memory.") catch {};
    proc.exit(255);
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
        \\-c,  --compare     <PATTERN>  Print distance between arguments to stdout. 
        \\-C,  --calculations           Output fuzzy string distance calculations.
        \\<PATTERN>                     Change dir to fuzzy matched table entry.
    ;

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

    if (res.args.compare) |leaf| {
        if (res.positionals.len == 0) {
            stderr.print("Must provide a second pattern as an arugment.\n", .{}) catch {};
            return 2;
        }
        const pattern = res.positionals[0];

        const dist = stringDistance(allocator, leaf, pattern) catch oom();
        stdout.print("{d}\n", .{dist}) catch {};
        return 0;
    }

    const jumptable: File = open_jumptable: {
        const creat = File.CreateFlags{ .read = true, .truncate = false };

        if (res.args.jumptable) |path| {
            const file = cwd.createFile(path, creat) catch |err| {
                stderr.print("Can't access jumptable file \"{s}\" for creation. {s}\n", .{ path, @errorName(err) }) catch {};
                return 101;
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
        return 50;
    };
    defer jumptable.close();

    const data = jumptable.readToEndAlloc(allocator, 1 << 20) catch |err| {
        stderr.print("Error reading jumptable file: {s}.\n", .{@errorName(err)}) catch {};
        return 102;
    };
    defer allocator.free(data);

    if (res.args.add) |path| {
        const canonical_path = canonicalPath(allocator, path);
        defer allocator.free(canonical_path);

        jumptable.writer().print("{s}\n", .{canonical_path}) catch |err| {
            stderr.print("Can't write the new path to jumptable. {s}\n", .{@errorName(err)}) catch {};
            return 103;
        };

        return 0;
    }

    if (res.args.del) |path| {
        // TODO: This can be done in less writes, by preserving a initial section
        // of the file that has not changed

        const canonical_path = canonicalPath(allocator, path);
        defer allocator.free(canonical_path);

        jumptable.seekBy(-@as(i64, @intCast(data.len))) catch |err| {
            stderr.print("Can't seek the jumptable. {s}\n", .{@errorName(err)}) catch {};
            return 104;
        };

        jumptable.setEndPos(0) catch |err| {
            stderr.print("Can't truncate the jumptable. {s}\n", .{@errorName(err)}) catch {};
            return 105;
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
                    stderr.print("Failed to write to jumptable. {s}\n", .{@errorName(err)}) catch {};
                    return 106;
                };
            }
        }

        return 0;
    }

    const pattern = if (res.positionals.len > 0) res.positionals[0] else {
        stderr.print("Must provide a pattern to jump into.\n", .{}) catch {};
        return 2;
    };

    const path = fuzzy_match: {
        var iter = mem.splitSequence(u8, data, "\n");

        var min_line: []const u8 = &.{};
        var min_dist: f64 = 99999999999.0;

        if (res.args.calculations != 0)
            stdout.print("pattern: \"{s}\"\n", .{pattern}) catch {};

        while (iter.next()) |line| {
            if (line.len == 0) continue;

            if (!fs.path.isAbsolute(line)) {
                stderr.print("jumptable: not an absolute path: \"{s}\"\n", .{line}) catch {};
                continue;
            }

            const leaf = fs.path.basename(line);
            const dist: f64 = stringDistance(allocator, leaf, pattern) catch oom();

            if (res.args.calculations != 0)
                stdout.print("leaf: \"{s}\" distance: {d}\n", .{ leaf, dist }) catch {};

            if (dist == 0 and res.args.calculations == 0) break :fuzzy_match line;

            if (dist < min_dist) {
                min_line = line;
                min_dist = dist;
            }
        }

        if (res.args.calculations != 0) {
            stdout.print("match: \"{s}\"\n", .{min_line}) catch {};
            return 0;
        }

        break :fuzzy_match min_line;
    };

    if (path.len == 0) {
        stderr.print("No match has been found. Your jumptable is empty.\n" ++
            "Add an entry to the table with 'jmp -a <PATH>'\n", .{}) catch {};
        return 4;
    }

    proc.changeCurDir(path) catch |err| {
        stderr.print("Can't change diretory to \"{s}\". {s}\n", .{ path, @errorName(err) }) catch {};
        return 108;
    };

    var env = proc.getEnvMap(allocator) catch oom();
    defer env.deinit();

    const shell = env.get("SHELL") orelse {
        stderr.print("The SHELL environment variable is not set.", .{}) catch {};
        return 51;
    };

    const jump_depth: u8 = if (env.get("JUMP_DEPTH")) |depth|
        std.fmt.parseInt(u8, depth, 10) catch 0
    else
        0;

    const value = std.fmt.allocPrint(allocator, "{d}", .{jump_depth +% 1}) catch oom();
    defer allocator.free(value);

    env.put("JUMP_DEPTH", value) catch oom();

    const err = proc.execve(allocator, &.{shell}, &env);
    stderr.print("Can't execute \"{s}\". {s}\n", .{ shell, @errorName(err) }) catch {};

    return 109;
}
