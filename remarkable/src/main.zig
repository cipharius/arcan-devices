const std = @import("std");
const c = @cImport({
    @cInclude("arcan_shmif.h");
});
const Atomic = std.atomic.Atomic;

const EventType = enum(u16) { syn, key, rel, abs, msc, sw, led, snd, rep, ff, pwr, ff_status };

const EvdevEvent = extern struct {
    time: std.os.linux.timeval,
    event_type: EventType,
    code: u16,
    value: i32,
};

const samples_len = 10;
const Samples = struct{
    time: [samples_len]std.os.linux.timeval = [1]std.os.linux.timeval{
        .{ .tv_sec = 0, .tv_usec = 0 },
    } ** samples_len,
    value: [samples_len]i32 = [1]i32{0} ** samples_len,
    index: Atomic(u8) = Atomic(u8).init(0),

    fn record(samples: *Samples, time: std.os.linux.timeval, value: i32) void {
        const i = samples.index.load(.Monotonic);
        samples.time[i] = time;
        samples.value[i] = value;
        samples.index.store((i + 1) % samples_len, .Release);
    }

    fn sample(samples: *const Samples, t: std.os.linux.timeval) i32 {
        const i = samples.index.load(.Acquire);
        const value_i1 = samples.value[(i + samples_len - 1) % samples_len];
        const value_i2 = samples.value[(i + samples_len - 2) % samples_len];
        const time_i1 = samples.time[(i + samples_len - 1) % samples_len];
        const time_i2 = samples.time[(i + samples_len - 2) % samples_len];

        const dv: f64 = @floatFromInt(value_i1 -| value_i2);
        const dt =
            @as(f64, @floatFromInt(time_i1.tv_sec -| time_i2.tv_sec)) +
            @as(f64, @floatFromInt(time_i1.tv_usec -| time_i2.tv_usec)) / std.time.us_per_s;

        if (dt == 0) return 0;

        const dv_dt = dv / dt;

        const dt_now =
            @as(f64, @floatFromInt(t.tv_sec -| time_i1.tv_sec)) +
            @as(f64, @floatFromInt(t.tv_usec -| time_i1.tv_usec)) / std.time.us_per_s;

        const result = @round(@as(f64, @floatFromInt(value_i1)) + dt_now * dv_dt);
        return std.math.lossyCast(i32, result);
    }
};

const StylusState = struct{
    x: Samples = .{},
    y: Samples = .{},
    distance: Samples = .{},
    pressure: Samples = .{},
    tilt_x: Samples = .{},
    tilt_y: Samples = .{},
    tip_in_range: Atomic(bool) = Atomic(bool).init(false),
    eraser_in_range: Atomic(bool) = Atomic(bool).init(false),
    is_pressed: Atomic(bool) = Atomic(bool).init(false),
    dirty: Atomic(bool) = Atomic(bool).init(false),
};
var stylus_state: StylusState = .{};

var finalise_threads = Atomic(bool).init(false);

fn handleSigInt(_: c_int) callconv(.C) void {
    finalise_threads.store(true, .Release);
}

pub fn main() !void {
    try std.os.sigaction(std.os.SIG.INT, &.{
        .handler = .{ .handler = handleSigInt },
        .mask = std.os.empty_sigset,
        .flags = 0,
    }, null);

    var cont = c.arcan_shmif_open(c.SEGID_SENSOR, c.SHMIF_ACQUIRE_FATALFAIL, null);
    std.debug.print("SHMIF connected", .{});

    std.debug.print("Spawning IO thread", .{});
    var stylus_io_thread = try std.Thread.spawn(.{}, stylusIOThread, .{});
    defer stylus_io_thread.join();

    var last_enqueue = try std.time.Instant.now();
    while (!finalise_threads.load(.Acquire)) {
        const now_ts = try std.time.Instant.now();
        const time_passed = now_ts.since(last_enqueue);

        // Sleeping sucks on this weak ARM processor, average idle CPU usage is 50%
        // Should be able to use event based resumes, for now the battery will suffer
        if (time_passed < 20 * std.time.ns_per_ms) {
            std.time.sleep(20 * std.time.ns_per_ms - time_passed);
            continue;
        }

        if (!stylus_state.dirty.load(.Acquire)) continue;
        stylus_state.dirty.store(false, .Monotonic);

        defer last_enqueue = std.time.Instant.now() catch unreachable;

        var ts_ns: std.os.timespec = undefined;
        try std.os.clock_gettime(std.os.CLOCK.REALTIME, &ts_ns);
        const ts = std.os.linux.timeval{
            .tv_sec = ts_ns.tv_sec,
            .tv_usec = @divTrunc(ts_ns.tv_nsec, std.time.ns_per_us),
        };

        const x_sample = stylus_state.x.sample(ts);
        const y_sample = stylus_state.y.sample(ts);
        const pressure_sample = stylus_state.pressure.sample(ts);
        const tilt_x_sample = stylus_state.tilt_x.sample(ts);
        const tilt_y_sample = stylus_state.tilt_y.sample(ts);
        // unused: const distance_sample = stylus_state.distance.sample(ts);

        const tip_in_range = stylus_state.tip_in_range.load(.Acquire);
        const eraser_in_range = stylus_state.eraser_in_range.load(.Acquire);
        const is_pressed = stylus_state.is_pressed.load(.Acquire);

        var label_buf = [1]u8{0} ** 16;
        std.mem.copyForwards(u8, &label_buf, "rM2 Wacom");
        const res = c.arcan_shmif_enqueue(&cont, &c.arcan_event{
            .unnamed_0 = .{
                .unnamed_0 = .{
                    .category = c.EVENT_IO,
                    .unnamed_0 = .{
                        .io = .{
                            .unnamed_0 = .{
                                .unnamed_0 = .{ .devid = 1, .subid = 0 },
                            },
                            .label = label_buf,
                            .flags = 0,
                            .dst = 0,
                            .pts = 0,
                            .devkind = c.EVENT_IDEVKIND_TOUCHDISP,
                            .kind = c.EVENT_IO_TOUCH,
                            .datatype = c.EVENT_IDATATYPE_TOUCH,
                            .input = c.arcan_ioevent_data{
                                .touch = .{
                                    .active = @intFromBool(is_pressed),
                                    .x = @truncate(x_sample),
                                    .y = @truncate(y_sample),
                                    .pressure = @floatFromInt(pressure_sample),
                                    .size = @as(f32, if (tip_in_range) 1 else if (eraser_in_range) 2 else 0),
                                    .tilt_x = std.math.lossyCast(u16, tilt_x_sample),
                                    .tilt_y = std.math.lossyCast(u16, tilt_y_sample),
                                    .tool = 1,
                                },
                            },
                        },
                    },
                },
            },
        });

        if (res < 0) {
            @panic("Failed to enqueue event");
        }
    }
}

fn stylusIOThread() void {
    var ev_file = std.fs.openFileAbsolute("/dev/input/event1", .{}) catch @panic("No /dev/input/event1");
    defer ev_file.close();

    var got_syn = true;
    var bytes = [1]u8{0} ** @sizeOf(EvdevEvent);
    while (!finalise_threads.load(.Acquire)) {
        if (got_syn) {
            // Polling for graceful shutdown window
            // Again, event based resumes would be better
            var pollfd = [1]std.os.linux.pollfd{ .{
                .fd = ev_file.handle,
                .events = std.os.linux.POLL.IN,
                .revents = 0,
            } };
            const poll_res = std.os.poll(&pollfd, 500) catch unreachable;
            if (poll_res == 0) continue;
        }
        got_syn = false;

        const read_bytes = ev_file.read(&bytes) catch unreachable;
        if (read_bytes != @sizeOf(EvdevEvent)) unreachable;

        const event: EvdevEvent = @bitCast(bytes);

        switch (event.event_type) {
            .key => {
                if (event.code == 320) {
                    stylus_state.tip_in_range.store(event.value > 0, .Release);
                } else if (event.code == 321) {
                    stylus_state.eraser_in_range.store(event.value > 0, .Release);
                } else if (event.code == 330) {
                    stylus_state.is_pressed.store(event.value > 0, .Release);
                }
            },
            .abs => {
                if (event.code == 0) {
                    stylus_state.x.record(event.time, event.value);
                } else if (event.code == 1) {
                    stylus_state.y.record(event.time, event.value);
                } else if (event.code == 24) {
                    stylus_state.pressure.record(event.time, event.value);
                } else if (event.code == 25) {
                    stylus_state.distance.record(event.time, event.value);
                } else if (event.code == 26) {
                    stylus_state.tilt_x.record(event.time, event.value);
                } else if (event.code == 27) {
                    stylus_state.tilt_y.record(event.time, event.value);
                }
            },
            .syn => {
                stylus_state.dirty.store(true, .Release);
                got_syn = true;
            },
            else => {},
        }
    }
}
