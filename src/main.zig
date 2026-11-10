const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const usage = "usage: lapentor360 <tour-url|slug> [out-dir]";
const api_url = "https://app.lapentor.com/v2/api/project-public/";
const faces = "rludfb";
const filter = "hstack=inputs=6,v360=input=c6x1:output=e:interp=lanczos";
const max_stitches = 2;
const max_title_len = 120;

const xmp_ns = "http://ns.adobe.com/xap/1.0/\x00";
const xmp_fmt =
    "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">" ++
    "<rdf:Description rdf:about=\"\" xmlns:GPano=\"http://ns.google.com/photos/1.0/panorama/\" " ++
    "GPano:ProjectionType=\"equirectangular\" GPano:UsePanoramaViewer=\"True\" " ++
    "GPano:FullPanoWidthPixels=\"{[width]d}\" GPano:FullPanoHeightPixels=\"{[height]d}\" " ++
    "GPano:CroppedAreaImageWidthPixels=\"{[width]d}\" GPano:CroppedAreaImageHeightPixels=\"{[height]d}\" " ++
    "GPano:CroppedAreaLeftPixels=\"0\" GPano:CroppedAreaTopPixels=\"0\"/></rdf:RDF></x:xmpmeta>";

const Tour = struct {
    scenes: []const Scene,
};

const Scene = struct {
    _id: []const u8,
    title: ?[]const u8 = null,
    xml: ?[]const u8 = null,
};

const Size = struct {
    width: u16,
    height: u16,
};

const Scraper = struct {
    gpa: Allocator,
    io: Io,
    client: *std.http.Client,
    out_dir: []const u8,
    scenes: []const Scene,
    number_width: usize,
    finished: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(usize) = .init(0),
    ffmpeg_missing: std.atomic.Value(bool) = .init(false),
    stitch_slots: Io.Semaphore = .{ .permits = max_stitches },
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    const slug = if (args.len == 2 or args.len == 3) slugOf(args[1]) else "";
    const out_dir = if (args.len == 3) args[2] else slug;
    if (slug.len == 0 or out_dir.len == 0) {
        std.debug.print(usage ++ "\n", .{});
        std.process.exit(2);
    }

    var client: std.http.Client = .{ .allocator = init.gpa, .io = io };
    defer client.deinit();

    const json = try get(&client, arena, try std.mem.concat(arena, u8, &.{ api_url, slug }));
    const tour = try std.json.parseFromSliceLeaky(Tour, arena, json, .{ .ignore_unknown_fields = true });
    if (tour.scenes.len == 0) std.process.fatal("{s}: tour has no scenes", .{slug});
    std.debug.print("{s}: {d} scenes -> {s}/\n", .{ slug, tour.scenes.len, out_dir });

    var scraper: Scraper = .{
        .gpa = init.gpa,
        .io = io,
        .client = &client,
        .out_dir = out_dir,
        .scenes = tour.scenes,
        .number_width = std.math.log10_int(tour.scenes.len) + 1,
    };
    var group: Io.Group = .init;
    for (0..tour.scenes.len) |index| group.async(io, scrapeTask, .{ &scraper, index });
    try group.await(io);

    const failed = scraper.failed.load(.monotonic);
    if (failed > 0) std.process.fatal("{d} of {d} scenes failed", .{ failed, tour.scenes.len });
}

fn slugOf(arg: []const u8) []const u8 {
    const marker = "/sphere/";
    const rest = if (std.mem.indexOf(u8, arg, marker)) |i| arg[i + marker.len ..] else arg;
    return rest[0 .. std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len];
}

fn scrapeTask(scraper: *Scraper, index: usize) Io.Cancelable!void {
    var arena: std.heap.ArenaAllocator = .init(scraper.gpa);
    defer arena.deinit();

    const total = scraper.scenes.len;
    const scene = scraper.scenes[index];
    const label = scene.title orelse scene._id;
    scrapeScene(scraper, arena.allocator(), index) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => {
            _ = scraper.failed.fetchAdd(1, .monotonic);
            std.debug.print("failed scene {d}/{d} {s}: {t}\n", .{ index + 1, total, label, err });
            return;
        },
    };
    const finished = scraper.finished.fetchAdd(1, .monotonic) + 1;
    std.debug.print("[{d}/{d}] {s}\n", .{ finished, total, label });
}

fn scrapeScene(scraper: *Scraper, arena: Allocator, index: usize) !void {
    const scene = scraper.scenes[index];
    const xml_url = scene.xml orelse return error.NoPanorama;
    const base_url = xml_url[0 .. (std.mem.lastIndexOfScalar(u8, xml_url, '/') orelse return error.BadXmlUrl) + 1];
    const name = try fileName(arena, index + 1, scraper.number_width, scene.title orelse scene._id);

    const xml = try get(scraper.client, arena, xml_url);
    const pattern = cubeUrl(xml) orelse return error.NoCubeInXml;

    var face_paths: [faces.len][]const u8 = undefined;
    for (faces, &face_paths) |face, *path| {
        const face_url = try std.mem.replaceOwned(u8, arena, pattern, "%s", &.{face});
        const url = if (std.mem.startsWith(u8, face_url, "http"))
            face_url
        else
            try std.mem.concat(arena, u8, &.{ base_url, face_url });
        path.* = try std.fmt.allocPrint(arena, "{s}/faces/{s}/{c}.jpg", .{ scraper.out_dir, name, face });
        try download(scraper, url, path.*);
    }

    try stitch(scraper, arena, &face_paths, try std.fmt.allocPrint(arena, "{s}/{s}.jpg", .{ scraper.out_dir, name }));
}

fn fileName(arena: Allocator, number: usize, width: usize, title: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, title, &std.ascii.whitespace);
    var len = @min(trimmed.len, max_title_len);
    while (len > 0 and len < trimmed.len and (trimmed[len] & 0xC0) == 0x80) len -= 1;

    const name = try std.fmt.allocPrint(arena, "{[number]d:0>[width]}-{[title]s}", .{
        .number = number,
        .width = width,
        .title = trimmed[0..len],
    });
    for (name) |*c| {
        if (c.* < 0x20 or std.mem.indexOfScalar(u8, " /\\:*?\"<>|", c.*) != null) c.* = '_';
    }
    return name;
}

fn cubeUrl(xml: []const u8) ?[]const u8 {
    const key = "url=\"";
    var rest = xml;
    while (std.mem.indexOf(u8, rest, "<cube ")) |start| {
        const end = std.mem.indexOfScalarPos(u8, rest, start, '>') orelse return null;
        const tag = rest[start..end];
        rest = rest[end..];
        if (std.mem.indexOf(u8, tag, "devices=") != null) continue;
        const key_at = std.mem.indexOf(u8, tag, key) orelse continue;
        const value = tag[key_at + key.len ..];
        return value[0 .. std.mem.indexOfScalar(u8, value, '"') orelse continue];
    }
    return null;
}

fn get(client: *std.http.Client, arena: Allocator, url: []const u8) ![]u8 {
    var body: Io.Writer.Allocating = .init(arena);
    const response = try client.fetch(.{ .location = .{ .url = url }, .response_writer = &body.writer });
    if (response.status != .ok) return httpError(url, response.status);
    return body.written();
}

fn httpError(url: []const u8, status: std.http.Status) error{HttpStatus} {
    std.debug.print("{s}: http {d}\n", .{ url, @backingInt(status) });
    return error.HttpStatus;
}

fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn download(scraper: *Scraper, url: []const u8, path: []const u8) !void {
    const io = scraper.io;
    if (exists(io, path)) return;

    var atomic = try Io.Dir.cwd().createFileAtomic(io, path, .{ .make_path = true });
    defer atomic.deinit(io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = atomic.file.writer(io, &buffer);

    const response = scraper.client.fetch(.{ .location = .{ .url = url }, .response_writer = &writer.interface }) catch |err| switch (err) {
        error.WriteFailed => return writer.err orelse error.WriteFailed,
        else => |e| return e,
    };
    if (response.status != .ok) return httpError(url, response.status);
    writer.interface.flush() catch return writer.err orelse error.WriteFailed;
    try atomic.file.sync(io);
    try atomic.link(io);
}

fn stitch(scraper: *Scraper, arena: Allocator, face_paths: []const []const u8, path: []const u8) !void {
    const io = scraper.io;
    if (exists(io, path) or scraper.ffmpeg_missing.load(.monotonic)) return;

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "ffmpeg", "-loglevel", "error" });
    for (face_paths) |face_path| try argv.appendSlice(arena, &.{ "-i", face_path });
    try argv.appendSlice(arena, &.{ "-filter_complex", filter, "-frames:v", "1", "-q:v", "2", "-f", "mjpeg", "-" });

    try scraper.stitch_slots.wait(io);
    defer scraper.stitch_slots.post(io);

    const result = std.process.run(arena, io, .{ .argv = argv.items }) catch |err| switch (err) {
        error.FileNotFound => {
            if (!scraper.ffmpeg_missing.swap(true, .monotonic)) {
                std.debug.print("ffmpeg not found, keeping cube faces only\n", .{});
            }
            return;
        },
        else => |e| return e,
    };
    if (!result.term.success()) {
        std.debug.print("ffmpeg failed for {s}: {s}\n", .{ path, result.stderr });
        return error.FfmpegFailed;
    }

    var atomic = try Io.Dir.cwd().createFileAtomic(io, path, .{ .make_path = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, try withPanoXmp(arena, result.stdout));
    try atomic.file.sync(io);
    try atomic.link(io);
}

fn withPanoXmp(arena: Allocator, jpeg: []const u8) ![]u8 {
    const size = jpegSize(jpeg) orelse return error.BadJpeg;

    var insert_at: usize = 2;
    if (jpeg[2] == 0xFF and jpeg[3] == 0xE0) insert_at += 2 + std.mem.readInt(u16, jpeg[4..6], .big);
    if (insert_at > jpeg.len) return error.BadJpeg;

    const xmp = try std.fmt.allocPrint(arena, xmp_fmt, size);
    var segment_len: [2]u8 = undefined;
    std.mem.writeInt(u16, &segment_len, @intCast(2 + xmp_ns.len + xmp.len), .big);
    return std.mem.concat(arena, u8, &.{ jpeg[0..insert_at], "\xFF\xE1", &segment_len, xmp_ns, xmp, jpeg[insert_at..] });
}

fn jpegSize(jpeg: []const u8) ?Size {
    if (!std.mem.startsWith(u8, jpeg, "\xFF\xD8")) return null;
    var i: usize = 2;
    while (i + 9 <= jpeg.len and jpeg[i] == 0xFF) {
        switch (jpeg[i + 1]) {
            0xC0...0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF => return .{
                .width = std.mem.readInt(u16, jpeg[i + 7 ..][0..2], .big),
                .height = std.mem.readInt(u16, jpeg[i + 5 ..][0..2], .big),
            },
            else => i += 2 + std.mem.readInt(u16, jpeg[i + 2 ..][0..2], .big),
        }
    }
    return null;
}

test slugOf {
    try std.testing.expectEqualStrings("spacer-2021", slugOf("https://app.lapentor.com/sphere/spacer-2021?scene=1"));
    try std.testing.expectEqualStrings("spacer-2021", slugOf("https://app.lapentor.com/sphere/spacer-2021/"));
    try std.testing.expectEqualStrings("spacer-2021", slugOf("spacer-2021"));
    try std.testing.expectEqualStrings("", slugOf("https://app.lapentor.com/sphere/"));
}

test fileName {
    const arena = std.testing.allocator;
    const name = try fileName(arena, 7, 3, "  SALA 3/A: \"x\"\n");
    defer arena.free(name);
    try std.testing.expectEqualStrings("007-SALA_3_A___x_", name);

    const run: [max_title_len - 1]u8 = @splat('a');
    const long = try fileName(arena, 1, 1, &run ++ "Ł");
    defer arena.free(long);
    try std.testing.expectEqualStrings("1-" ++ &run, long);

    const garbage: [max_title_len + 1]u8 = @splat(0x80);
    const empty = try fileName(arena, 1, 1, &garbage);
    defer arena.free(empty);
    try std.testing.expectEqualStrings("1-", empty);
}

test cubeUrl {
    const xml =
        \\<image><cube url="mobile/m_%s.jpg" devices="mobile" />
        \\<cube url="pc/pc_%s.jpg" /></image>
    ;
    try std.testing.expectEqualStrings("pc/pc_%s.jpg", cubeUrl(xml).?);
    try std.testing.expectEqual(null, cubeUrl("<krpano/>"));
}

test jpegSize {
    const jpeg = "\xFF\xD8\xFF\xE0\x00\x04\x00\x00\xFF\xC0\x00\x11\x08\x0D\x60\x1A\xC0\x03";
    try std.testing.expectEqual(Size{ .width = 6848, .height = 3424 }, jpegSize(jpeg).?);
    try std.testing.expectEqual(null, jpegSize("\xFF\xD8\xFF\xE0\xFF"));
}
