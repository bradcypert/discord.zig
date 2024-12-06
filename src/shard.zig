const ws = @import("ws");
const builtin = @import("builtin");

const std = @import("std");
const net = std.net;
const crypto = std.crypto;
const tls = std.crypto.tls;
const json = std.json;
const mem = std.mem;
const http = std.http;

// todo use this to read compressed messages
const zlib = @import("zlib");
const zjson = @import("json");

const Self = @This();

const IdentifyProperties = @import("internal.zig").IdentifyProperties;
const GatewayInfo = @import("internal.zig").GatewayInfo;
const GatewayBotInfo = @import("internal.zig").GatewayBotInfo;
const GatewaySessionStartLimit = @import("internal.zig").GatewaySessionStartLimit;
const ShardDetails = @import("internal.zig").ShardDetails;

const Log = @import("internal.zig").Log;
const GatewayDispatchEvent = @import("internal.zig").GatewayDispatchEvent;
const Bucket = @import("internal.zig").Bucket;
const default_identify_properties = @import("internal.zig").default_identify_properties;

const Types = @import("./structures/types.zig");
const GatewayPayload = Types.GatewayPayload;
const Opcode = Types.GatewayOpcodes;
const Intents = Types.Intents;

const Snowflake = @import("./structures/snowflake.zig").Snowflake;
const FetchReq = @import("http.zig").FetchReq;
const MakeRequestError = @import("http.zig").MakeRequestError;
const Partial = Types.Partial;

pub const ShardSocketCloseCodes = enum(u16) {
    Shutdown = 3000,
    ZombiedConnection = 3010,
};

const Heart = struct {
    /// interval to send heartbeats, further multiply it with the jitter
    heartbeatInterval: u64,
    /// useful for calculating ping and resuming
    lastBeat: i64,
};

const RatelimitOptions = struct {
    max_requests_per_ratelimit_tick: ?usize = 120,
    ratelimit_reset_interval: u64 = 60000,
};

pub const ShardOptions = struct {
    info: GatewayBotInfo,
    ratelimit_options: RatelimitOptions = .{},
};

id: usize,

client: ws.Client,
details: ShardDetails,

//heart: Heart =
allocator: mem.Allocator,
resume_gateway_url: ?[]const u8 = null,
bucket: Bucket,
options: ShardOptions,

session_id: ?[]const u8,
sequence: std.atomic.Value(isize) = .init(0),
heart: Heart = .{ .heartbeatInterval = 45000, .lastBeat = 0 },

///
handler: GatewayDispatchEvent(*Self),
packets: std.ArrayList(u8),
inflator: zlib.Decompressor,

///useful for closing the conn
ws_mutex: std.Thread.Mutex = .{},
rw_mutex: std.Thread.RwLock = .{},
log: Log = .no,

pub const JsonResolutionError = std.fmt.ParseIntError || std.fmt.ParseFloatError || json.ParseFromValueError || json.ParseError(json.Scanner);

pub fn resumable(self: *Self) bool {
    return self.resume_gateway_url != null and
        self.session_id != null and
        self.sequence.load(.monotonic) > 0;
}

pub fn resume_(self: *Self) SendError!void {
    const data = .{ .op = @intFromEnum(Opcode.Resume), .d = .{
        .token = self.details.token,
        .session_id = self.session_id,
        .seq = self.sequence.load(.monotonic),
    } };

    try self.send(false, data);
}

inline fn gatewayUrl(self: ?*Self) []const u8 {
    return if (self) |s| (s.resume_gateway_url orelse s.options.info.url)["wss://".len..] else "gateway.discord.gg";
}

/// identifies in order to connect to Discord and get the online status, this shall be done on hello perhaps
pub fn identify(self: *Self, properties: ?IdentifyProperties) SendError!void {
    if (self.details.intents.toRaw() != 0) {
        const data = .{
            .op = @intFromEnum(Opcode.Identify),
            .d = .{
                .intents = self.details.intents.toRaw(),
                .properties = properties orelse default_identify_properties,
                .token = self.details.token,
            },
        };
        try self.send(false, data);
    } else {
        const data = .{
            .op = @intFromEnum(Opcode.Identify),
            .d = .{
                .capabilities = 30717,
                .properties = properties orelse default_identify_properties,
                .token = self.details.token,
            },
        };
        try self.send(false, data);
    }
}

pub fn init(allocator: mem.Allocator, shard_id: usize, settings: struct {
    token: []const u8,
    intents: Intents,
    options: ShardOptions,
    run: GatewayDispatchEvent(*Self),
    log: Log,
}) zlib.Error!Self {
    return Self{
        .options = ShardOptions{
            .info = GatewayBotInfo{
                .url = settings.options.info.url,
                .shards = settings.options.info.shards,
                .session_start_limit = settings.options.info.session_start_limit,
            },
            .ratelimit_options = settings.options.ratelimit_options,
        },
        .id = shard_id,
        .allocator = allocator,
        .details = ShardDetails{
            .token = settings.token,
            .intents = settings.intents,
        },
        .client = undefined,
        // maybe there is a better way to do this
        .session_id = undefined,
        .handler = settings.run,
        .log = settings.log,
        .packets = std.ArrayList(u8).init(allocator),
        .inflator = try zlib.Decompressor.init(allocator, .{ .header = .zlib_or_gzip }),
        .bucket = Bucket.init(
            allocator,
            Self.calculateSafeRequests(settings.options.ratelimit_options),
            settings.options.ratelimit_options.ratelimit_reset_interval,
            Self.calculateSafeRequests(settings.options.ratelimit_options),
        ),
    };
}

inline fn calculateSafeRequests(options: RatelimitOptions) usize {
    const safe_requests =
        @as(f64, @floatFromInt(options.max_requests_per_ratelimit_tick orelse 120)) -
        @ceil(@as(f64, @floatFromInt(options.ratelimit_reset_interval)) / 30000.0) * 2;

    if (safe_requests < 0) {
        return 0;
    }

    return @intFromFloat(safe_requests);
}

inline fn _connect_ws(allocator: mem.Allocator, url: []const u8) !ws.Client {
    var conn = try ws.Client.init(allocator, .{
        .tls = true, // important: zig.http doesn't support this, type shit
        .port = 443,
        .host = url,
    });

    // maybe change this to a buffer
    var buf: [0x100]u8 = undefined;
    const host = try std.fmt.bufPrint(&buf, "host: {s}", .{url});

    conn.handshake("/?v=10&encoding=json&compress=zlib-stream", .{
        .timeout_ms = 1000,
        .headers = host,
    }) catch unreachable;

    return conn;
}

pub fn deinit(self: *Self) void {
    self.client.deinit();
}

const ReadMessageError = mem.Allocator.Error || zlib.Error || json.ParseError(json.Scanner) || json.ParseFromValueError;

/// listens for messages
fn readMessage(self: *Self, _: anytype) !void {
    try self.client.readTimeout(0);

    while (try self.client.read()) |msg| { // check your intents, dumbass
        defer self.client.done(msg);

        try self.packets.appendSlice(msg.data);

        // end of zlib
        if (!std.mem.endsWith(u8, msg.data, &[4]u8{ 0x00, 0x00, 0xFF, 0xFF }))
            continue;

        const buf = try self.packets.toOwnedSlice();
        const decompressed = try self.inflator.decompressAllAlloc(buf);
        defer self.allocator.free(decompressed);

        const raw = try json.parseFromSlice(struct {
            op: isize,
            d: json.Value,
            s: ?i64,
            t: ?[]const u8,
        }, self.allocator, decompressed, .{});
        defer raw.deinit();

        const payload = raw.value;

        switch (@as(Opcode, @enumFromInt(payload.op))) {
            Opcode.Dispatch => {
                // maybe use threads and call it instead from there
                if (payload.t) |name| {
                    self.sequence.store(payload.s orelse 0, .monotonic);
                    try self.handleEvent(name, decompressed);
                }
            },
            Opcode.Hello => {
                const HelloPayload = struct { heartbeat_interval: u64, _trace: [][]const u8 };
                const parsed = try json.parseFromValue(HelloPayload, self.allocator, payload.d, .{});
                defer parsed.deinit();

                const helloPayload = parsed.value;

                // PARSE NEW URL IN READY

                self.heart = Heart{
                    .heartbeatInterval = helloPayload.heartbeat_interval,
                    .lastBeat = 0,
                };

                if (self.resumable()) {
                    try self.resume_();
                    return;
                }

                try self.identify(self.details.properties);

                var prng = std.Random.DefaultPrng.init(0);
                const jitter = std.Random.float(prng.random(), f64);
                self.heart.lastBeat = std.time.milliTimestamp();
                const heartbeat_writer = try std.Thread.spawn(.{}, Self.heartbeat, .{ self, jitter });
                heartbeat_writer.detach();
            },
            Opcode.HeartbeatACK => {
                // perhaps this needs a mutex?
                self.rw_mutex.lock();
                defer self.rw_mutex.unlock();
                self.heart.lastBeat = std.time.milliTimestamp();
            },
            Opcode.Heartbeat => {
                self.ws_mutex.lock();
                defer self.ws_mutex.unlock();
                try self.send(false, .{ .op = @intFromEnum(Opcode.Heartbeat), .d = self.sequence.load(.monotonic) });
            },
            Opcode.Reconnect => {
                try self.reconnect();
            },
            Opcode.Resume => {
                const WithSequence = struct {
                    token: []const u8,
                    session_id: []const u8,
                    seq: ?isize,
                };
                const parsed = try json.parseFromValue(WithSequence, self.allocator, payload.d, .{});
                defer parsed.deinit();

                const resume_payload = parsed.value;

                self.sequence.store(resume_payload.seq orelse 0, .monotonic);
                self.session_id = resume_payload.session_id;
            },
            Opcode.InvalidSession => {},
            else => {},
        }
    }
}

pub const SendHeartbeatError = CloseError || SendError;

pub fn heartbeat(self: *Self, initial_jitter: f64) SendHeartbeatError!void {
    var jitter = initial_jitter;

    while (true) {
        // basecase
        if (jitter == 1.0) {
            std.Thread.sleep(std.time.ns_per_ms * self.heart.heartbeatInterval);
        } else {
            const timeout = @as(f64, @floatFromInt(self.heart.heartbeatInterval)) * jitter;
            std.Thread.sleep(std.time.ns_per_ms * @as(u64, @intFromFloat(timeout)));
        }

        self.rw_mutex.lock();
        const last = self.heart.lastBeat;
        self.rw_mutex.unlock();

        const seq = self.sequence.load(.monotonic);
        self.ws_mutex.lock();
        try self.send(false, .{ .op = @intFromEnum(Opcode.Heartbeat), .d = seq });
        self.ws_mutex.unlock();

        if ((std.time.milliTimestamp() - last) > (5000 * self.heart.heartbeatInterval)) {
            try self.close(ShardSocketCloseCodes.ZombiedConnection, "Zombied connection");
            @panic("zombied conn\n");
        }

        jitter = 1.0;
    }
}

pub const ReconnectError = ConnectError || CloseError;

pub fn reconnect(self: *Self) ReconnectError!void {
    try self.disconnect();
    try self.connect();
}

pub const ConnectError =
    net.TcpConnectToAddressError || crypto.tls.Client.InitError(net.Stream) ||
    net.Stream.ReadError || net.IPParseError ||
    crypto.Certificate.Bundle.RescanError || net.TcpConnectToHostError ||
    std.fmt.BufPrintError || mem.Allocator.Error;

pub fn connect(self: *Self) ConnectError!void {
    //std.time.sleep(std.time.ms_per_s * 5);
    self.client = try Self._connect_ws(self.allocator, self.gatewayUrl());
    //const event_listener = try std.Thread.spawn(.{}, Self.readMessage, .{ &self, null });
    //event_listener.join();

    self.readMessage(null) catch unreachable;
}

pub fn disconnect(self: *Self) CloseError!void {
    try self.close(ShardSocketCloseCodes.Shutdown, "Shard down request");
}

pub const CloseError = mem.Allocator.Error || error{ReasonTooLong};

pub fn close(self: *Self, code: ShardSocketCloseCodes, reason: []const u8) CloseError!void {
    // Implement reconnection logic here
    try self.client.close(.{
        .code = @intFromEnum(code), //u16
        .reason = reason, //[]const u8
    });
}

pub const SendError = net.Stream.WriteError || std.ArrayList(u8).Writer.Error;

pub fn send(self: *Self, _: bool, data: anytype) SendError!void {
    var buf: [1000]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var string = std.ArrayList(u8).init(fba.allocator());
    try std.json.stringify(data, .{}, string.writer());

    try self.client.write(try string.toOwnedSlice());
}

pub fn handleEvent(self: *Self, name: []const u8, payload: []const u8) !void {
    // std.debug.print("event: {s}\n", .{name});

    if (mem.eql(u8, name, "READY")) {
        const ready = try zjson.parse(GatewayPayload(Types.Ready), self.allocator, payload);

        if (self.handler.ready) |event| try event(self, ready.value.d.?);
    }

    if (mem.eql(u8, name, "APPLICATION_COMMAND_PERMISSIONS_UPDATE")) {
        const acp = try zjson.parse(GatewayPayload(Types.ApplicationCommandPermissions), self.allocator, payload);

        if (self.handler.application_command_permissions_update) |event| try event(self, acp.value.d.?);
    }

    if (mem.eql(u8, name, "CHANNEL_CREATE")) {
        const chan = try zjson.parse(GatewayPayload(Types.Channel), self.allocator, payload);

        if (self.handler.channel_create) |event| try event(self, chan.value.d.?);
    }

    if (mem.eql(u8, name, "CHANNEL_UPDATE")) {
        const chan = try zjson.parse(GatewayPayload(Types.Channel), self.allocator, payload);

        if (self.handler.channel_update) |event| try event(self, chan.value.d.?);
    }

    if (mem.eql(u8, name, "CHANNEL_DELETE")) {
        const chan = try zjson.parse(GatewayPayload(Types.Channel), self.allocator, payload);

        if (self.handler.channel_delete) |event| try event(self, chan.value.d.?);
    }

    if (mem.eql(u8, name, "CHANNEL_PINS_UPDATE")) {
        const chan_pins_update = try zjson.parse(GatewayPayload(Types.ChannelPinsUpdate), self.allocator, payload);

        if (self.handler.channel_pins_update) |event| try event(self, chan_pins_update.value.d.?);
    }

    if (mem.eql(u8, name, "ENTITLEMENT_CREATE")) {
        const entitlement = try zjson.parse(GatewayPayload(Types.Entitlement), self.allocator, payload);

        if (self.handler.entitlement_create) |event| try event(self, entitlement.value.d.?);
    }

    if (mem.eql(u8, name, "ENTITLEMENT_UPDATE")) {
        const entitlement = try zjson.parse(GatewayPayload(Types.Entitlement), self.allocator, payload);

        if (self.handler.entitlement_update) |event| try event(self, entitlement.value.d.?);
    }

    if (mem.eql(u8, name, "ENTITLEMENT_DELETE")) {
        const entitlement = try zjson.parse(GatewayPayload(Types.Entitlement), self.allocator, payload);

        if (self.handler.entitlement_delete) |event| try event(self, entitlement.value.d.?);
    }

    if (mem.eql(u8, name, "INTEGRATION_CREATE")) {
        const guild_id = try zjson.parse(GatewayPayload(Types.IntegrationCreateUpdate), self.allocator, payload);

        if (self.handler.integration_create) |event| try event(self, guild_id.value.d.?);
    }

    if (mem.eql(u8, name, "INTEGRATION_UPDATE")) {
        const guild_id = try zjson.parse(GatewayPayload(Types.IntegrationCreateUpdate), self.allocator, payload);

        if (self.handler.integration_update) |event| try event(self, guild_id.value.d.?);
    }

    if (mem.eql(u8, name, "INTEGRATION_DELETE")) {
        const data = try zjson.parse(GatewayPayload(Types.IntegrationDelete), self.allocator, payload);

        if (self.handler.integration_delete) |event| try event(self, data.value.d.?);
    }

    if (mem.eql(u8, name, "INTERACTION_CREATE")) {
        const interaction = try zjson.parse(GatewayPayload(Types.MessageInteraction), self.allocator, payload);

        if (self.handler.interaction_create) |event| try event(self, interaction.value.d.?);
    }

    if (mem.eql(u8, name, "INVITE_CREATE")) {
        const data = try zjson.parse(GatewayPayload(Types.InviteCreate), self.allocator, payload);

        if (self.handler.invite_create) |event| try event(self, data.value.d.?);
    }

    if (mem.eql(u8, name, "INVITE_DELETE")) {
        const data = try zjson.parse(GatewayPayload(Types.InviteDelete), self.allocator, payload);

        if (self.handler.invite_delete) |event| try event(self, data.value.d.?);
    }

    if (mem.eql(u8, name, "MESSAGE_CREATE")) {
        const message = try zjson.parse(GatewayPayload(Types.Message), self.allocator, payload);

        if (self.handler.message_create) |event| try event(self, message.value.d.?);
    }

    if (mem.eql(u8, name, "MESSAGE_DELETE")) {
        const data = try zjson.parse(GatewayPayload(Types.MessageDelete), self.allocator, payload);

        if (self.handler.message_delete) |event| try event(self, data.value.d.?);
    }

    if (mem.eql(u8, name, "MESSAGE_UPDATE")) {
        const message = try zjson.parse(GatewayPayload(Types.Message), self.allocator, payload);

        if (self.handler.message_update) |event| try event(self, message.value.d.?);
    }

    if (mem.eql(u8, name, "MESSAGE_DELETE_BULK")) {
        const data = try zjson.parse(GatewayPayload(Types.MessageDeleteBulk), self.allocator, payload);

        if (self.handler.message_delete_bulk) |event| try event(self, data.value.d.?);
    }

    if (mem.eql(u8, name, "MESSAGE_REACTION_ADD")) {
        const reaction = try zjson.parse(GatewayPayload(Types.MessageReactionAdd), self.allocator, payload);

        if (self.handler.message_reaction_add) |event| try event(self, reaction.value.d.?);
    }

    if (mem.eql(u8, name, "MESSAGE_REACTION_REMOVE")) {
        const reaction = try zjson.parse(GatewayPayload(Types.MessageReactionRemove), self.allocator, payload);

        if (self.handler.message_reaction_remove) |event| try event(self, reaction.value.d.?);
    }

    if (mem.eql(u8, name, "MESSAGE_REACTION_REMOVE_ALL")) {
        const data = try zjson.parse(GatewayPayload(Types.MessageReactionRemoveAll), self.allocator, payload);

        if (self.handler.message_reaction_remove_all) |event| try event(self, data.value.d.?);
    }

    if (mem.eql(u8, name, "MESSAGE_REACTION_REMOVE_EMOJI")) {
        const emoji = try zjson.parse(GatewayPayload(Types.MessageReactionRemoveEmoji), self.allocator, payload);

        if (self.handler.message_reaction_remove_emoji) |event| try event(self, emoji.value.d.?);
    }

    if (mem.eql(u8, name, "GUILD_CREATE")) {
        const isAvailable =
            try zjson.parse(GatewayPayload(struct { unavailable: ?bool }), self.allocator, payload);

        if (isAvailable.value.d.?.unavailable == true) {
            const guild = try zjson.parse(GatewayPayload(Types.Guild), self.allocator, payload);

            if (self.handler.guild_create) |event| try event(self, guild.value.d.?);
            return;
        }

        const guild = try zjson.parse(GatewayPayload(Types.UnavailableGuild), self.allocator, payload);

        if (self.handler.guild_create_unavailable) |event| try event(self, guild.value.d.?);
    }

    if (mem.eql(u8, name, "GUILD_UPDATE")) {
        const guild = try zjson.parse(GatewayPayload(Types.Guild), self.allocator, payload);

        if (self.handler.guild_update) |event| try event(self, guild.value.d.?);
    }

    if (mem.eql(u8, name, "GUILD_DELETE")) {
        const guild = try zjson.parse(GatewayPayload(Types.UnavailableGuild), self.allocator, payload);

        if (self.handler.guild_delete) |event| try event(self, guild.value.d.?);
    }

    if (mem.eql(u8, name, "GUILD_SCHEDULED_EVENT_CREATE")) {
        const s_event = try zjson.parse(GatewayPayload(Types.ScheduledEvent), self.allocator, payload);

        if (self.handler.guild_scheduled_event_create) |event| try event(self, s_event.value.d.?);
    }

    if (mem.eql(u8, name, "GUILD_SCHEDULED_EVENT_UPDATE")) {
        const s_event = try zjson.parse(GatewayPayload(Types.ScheduledEvent), self.allocator, payload);

        if (self.handler.guild_scheduled_event_update) |event| try event(self, s_event.value.d.?);
    }

    if (mem.eql(u8, name, "GUILD_SCHEDULED_EVENT_DELETE")) {
        const s_event = try zjson.parse(GatewayPayload(Types.ScheduledEvent), self.allocator, payload);

        if (self.handler.guild_scheduled_event_delete) |event| try event(self, s_event.value.d.?);
    }

    if (mem.eql(u8, name, "GUILD_SCHEDULED_EVENT_USER_ADD")) {
        const data = try zjson.parse(GatewayPayload(Types.ScheduledEventUserAdd), self.allocator, payload);

        if (self.handler.guild_scheduled_event_user_add) |event| try event(self, data.value.d.?);
    }

    if (mem.eql(u8, name, "GUILD_SCHEDULED_EVENT_USER_REMOVE")) {
        const data = try zjson.parse(GatewayPayload(Types.ScheduledEventUserRemove), self.allocator, payload);

        if (self.handler.guild_scheduled_event_user_remove) |event| try event(self, data.value.d.?);
    }

    if (mem.eql(u8, name, "GUILD_MEMBER_ADD")) {
        const guild_id = try zjson.parse(GatewayPayload(Types.GuildMemberAdd), self.allocator, payload);

        if (self.handler.guild_member_add) |event| try event(self, guild_id.value.d.?);
    }

    if (mem.eql(u8, name, "GUILD_MEMBER_UPDATE")) {
        const fields = try zjson.parse(GatewayPayload(Types.GuildMemberUpdate), self.allocator, payload);

        if (self.handler.guild_member_update) |event| try event(self, fields.value.d.?);
    }

    if (mem.eql(u8, name, "GUILD_MEMBER_REMOVE")) {
        const user = try zjson.parse(GatewayPayload(Types.GuildMemberRemove), self.allocator, payload);

        if (self.handler.guild_member_remove) |event| try event(self, user.value.d.?);
    }

    if (mem.eql(u8, name, "GUILD_MEMBERS_CHUNK")) {
        const data = try zjson.parse(GatewayPayload(Types.GuildMembersChunk), self.allocator, payload);

        if (self.handler.guild_members_chunk) |event| try event(self, data.value.d.?);
    }

    if (mem.eql(u8, name, "GUILD_ROLE_CREATE")) {
        const role = try zjson.parse(GatewayPayload(Types.GuildRoleCreate), self.allocator, payload);

        if (self.handler.guild_role_create) |event| try event(self, role.value.d.?);
    }

    if (mem.eql(u8, name, "GUILD_ROLE_UPDATE")) {
        const role = try zjson.parse(GatewayPayload(Types.GuildRoleUpdate), self.allocator, payload);

        if (self.handler.guild_role_update) |event| try event(self, role.value.d.?);
    }

    if (mem.eql(u8, name, "GUILD_ROLE_DELETE")) {
        const role_id = try zjson.parse(GatewayPayload(Types.GuildRoleDelete), self.allocator, payload);

        if (self.handler.guild_role_delete) |event| try event(self, role_id.value.d.?);
    }

    if (mem.eql(u8, name, "GUILD_DELETE")) {
        const guild = try zjson.parse(GatewayPayload(Types.UnavailableGuild), self.allocator, payload);

        if (self.handler.guild_delete) |event| try event(self, guild.value.d.?);
    }

    if (mem.eql(u8, name, "GUILD_BAN_ADD")) {
        const gba = try zjson.parse(GatewayPayload(Types.GuildBanAddRemove), self.allocator, payload);

        if (self.handler.guild_ban_add) |event| try event(self, gba.value.d.?);
    }

    if (mem.eql(u8, name, "GUILD_BAN_REMOVE")) {
        const gbr = try zjson.parse(GatewayPayload(Types.GuildBanAddRemove), self.allocator, payload);

        if (self.handler.guild_ban_remove) |event| try event(self, gbr.value.d.?);
    }

    if (mem.eql(u8, name, "GUILD_EMOJIS_UPDATE")) {
        const emojis = try zjson.parse(GatewayPayload(Types.GuildEmojisUpdate), self.allocator, payload);

        if (self.handler.guild_emojis_update) |event| try event(self, emojis.value.d.?);
    }

    if (mem.eql(u8, name, "GUILD_STICKERS_UPDATE")) {
        const stickers = try zjson.parse(GatewayPayload(Types.GuildStickersUpdate), self.allocator, payload);

        if (self.handler.guild_stickers_update) |event| try event(self, stickers.value.d.?);
    }

    if (mem.eql(u8, name, "GUILD_INTEGRATIONS_UPDATE")) {
        const guild_id = try zjson.parse(GatewayPayload(Types.GuildIntegrationsUpdate), self.allocator, payload);

        if (self.handler.guild_integrations_update) |event| try event(self, guild_id.value.d.?);
    }

    if (mem.eql(u8, name, "THREAD_CREATE")) {
        const thread = try zjson.parse(GatewayPayload(Types.Channel), self.allocator, payload);

        if (self.handler.thread_create) |event| try event(self, thread.value.d.?);
    }
    if (mem.eql(u8, name, "THREAD_UPDATE")) {
        const thread = try zjson.parse(GatewayPayload(Types.Channel), self.allocator, payload);

        if (self.handler.thread_update) |event| try event(self, thread.value.d.?);
    }
    if (mem.eql(u8, name, "THREAD_DELETE")) {
        const thread_data = try zjson.parse(GatewayPayload(Types.Partial(Types.Channel)), self.allocator, payload);

        if (self.handler.thread_delete) |event| try event(self, thread_data.value.d.?);
    }
    if (mem.eql(u8, name, "THREAD_LIST_SYNC")) {
        const data = try zjson.parse(GatewayPayload(Types.ThreadListSync), self.allocator, payload);

        if (self.handler.thread_list_sync) |event| try event(self, data.value.d.?);
    }

    if (mem.eql(u8, name, "THREAD_MEMBER_UPDATE")) {
        const guild_id = try zjson.parse(GatewayPayload(Types.ThreadMemberUpdate), self.allocator, payload);

        if (self.handler.thread_member_update) |event| try event(self, guild_id.value.d.?);
    }

    if (mem.eql(u8, name, "THREAD_MEMBERS_UPDATE")) {
        const data = try zjson.parse(GatewayPayload(Types.ThreadMembersUpdate), self.allocator, payload);

        if (self.handler.thread_members_update) |event| try event(self, data.value.d.?);
    }

    if (mem.eql(u8, name, "TYPING_START")) {
        const data = try zjson.parse(GatewayPayload(Types.TypingStart), self.allocator, payload);

        if (self.handler.typing_start) |event| try event(self, data.value.d.?);
    }

    if (mem.eql(u8, name, "USER_UPDATE")) {
        const user = try zjson.parse(GatewayPayload(Types.User), self.allocator, payload);

        if (self.handler.user_update) |event| try event(self, user.value.d.?);
    }

    if (mem.eql(u8, name, "PRESENCE_UPDATE")) {
        const pu = try zjson.parse(GatewayPayload(Types.PresenceUpdate), self.allocator, payload);

        if (self.handler.presence_update) |event| try event(self, pu.value.d.?);
    }

    if (mem.eql(u8, name, "MESSSAGE_POLL_VOTE_ADD")) {
        const data = try zjson.parse(GatewayPayload(Types.PollVoteAdd), self.allocator, payload);

        if (self.handler.message_poll_vote_add) |event| try event(self, data.value.d.?);
    }

    if (mem.eql(u8, name, "MESSSAGE_POLL_VOTE_REMOVE")) {
        const data = try zjson.parse(GatewayPayload(Types.PollVoteRemove), self.allocator, payload);

        if (self.handler.message_poll_vote_remove) |event| try event(self, data.value.d.?);
    }

    if (mem.eql(u8, name, "WEBHOOKS_UPDATE")) {
        const fields = try zjson.parse(GatewayPayload(Types.WebhookUpdate), self.allocator, payload);

        if (self.handler.webhooks_update) |event| try event(self, fields.value.d.?);
    }

    if (mem.eql(u8, name, "STAGE_INSTANCE_CREATE")) {
        const stage = try zjson.parse(GatewayPayload(Types.StageInstance), self.allocator, payload);

        if (self.handler.stage_instance_create) |event| try event(self, stage.value.d.?);
    }

    if (mem.eql(u8, name, "STAGE_INSTANCE_UPDATE")) {
        const stage = try zjson.parse(GatewayPayload(Types.StageInstance), self.allocator, payload);

        if (self.handler.stage_instance_update) |event| try event(self, stage.value.d.?);
    }

    if (mem.eql(u8, name, "STAGE_INSTANCE_DELETE")) {
        const stage = try zjson.parse(GatewayPayload(Types.StageInstance), self.allocator, payload);

        if (self.handler.stage_instance_delete) |event| try event(self, stage.value.d.?);
    }

    if (mem.eql(u8, name, "AUTO_MODERATION_RULE_CREATE")) {
        const rule = try zjson.parse(GatewayPayload(Types.AutoModerationRule), self.allocator, payload);

        if (self.handler.auto_moderation_rule_create) |event| try event(self, rule.value.d.?);
    }

    if (mem.eql(u8, name, "AUTO_MODERATION_RULE_UPDATE")) {
        const rule = try zjson.parse(GatewayPayload(Types.AutoModerationRule), self.allocator, payload);

        if (self.handler.auto_moderation_rule_update) |event| try event(self, rule.value.d.?);
    }

    if (mem.eql(u8, name, "AUTO_MODERATION_RULE_DELETE")) {
        const rule = try zjson.parse(GatewayPayload(Types.AutoModerationRule), self.allocator, payload);

        if (self.handler.auto_moderation_rule_delete) |event| try event(self, rule.value.d.?);
    }

    if (mem.eql(u8, name, "AUTO_MODERATION_ACTION_EXECUTION")) {
        const ax = try zjson.parse(GatewayPayload(Types.AutoModerationActionExecution), self.allocator, payload);

        if (self.handler.auto_moderation_action_execution) |event| try event(self, ax.value.d.?);
    }

    if (self.handler.any) |anyEvent|
        try anyEvent(self, payload);
}

pub const RequestFailedError = zjson.ParserError || MakeRequestError || error{FailedRequest};

// start http methods

/// Method to send a message
pub fn sendMessage(self: *Self, channel_id: Snowflake, create_message: Partial(Types.CreateMessage)) RequestFailedError!zjson.Owned(Types.Message) {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/channels/{d}/messages", .{channel_id.into()});

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    const res = try req.post(Types.Message, path, create_message);
    return res;
}

/// Method to delete a message
pub fn deleteMessage(self: *Self, channel_id: Snowflake, message_id: Snowflake) RequestFailedError!void {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/channels/{d}/messages/{d}", .{ channel_id.into(), message_id.into() });

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    try req.delete(path);
}

/// Method to edit a message
pub fn editMessage(self: *Self, channel_id: Snowflake, message_id: Snowflake, edit_message: Partial(Types.CreateMessage)) RequestFailedError!zjson.Owned(Types.Message) {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/channels/{d}/messages/{d}", .{ channel_id.into(), message_id.into() });

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    const res = try req.patch(Types.Message, path, edit_message);
    return res;
}

/// Method to get a message
pub fn fetchMessage(self: *Self, channel_id: Snowflake, message_id: Snowflake) RequestFailedError!zjson.Owned(Types.Message) {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/channels/{d}/messages/{d}", .{ channel_id.into(), message_id.into() });

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    const res = try req.get(Types.Message, path);
    return res;
}

// Methods for channel-related actions

/// Method to fetch a channel
pub fn fetchChannel(self: *Self, channel_id: Snowflake) RequestFailedError!zjson.Owned(Types.Channel) {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/channels/{d}", .{channel_id.into()});

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    const res = try req.get(Types.Channel, path);
    return res;
}

/// Method to delete a channel
pub fn deleteChannel(self: *Self, channel_id: Snowflake) RequestFailedError!void {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/channels/{d}", .{channel_id.into()});

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    try req.delete(path);
}

/// Method to edit a channel
pub fn editChannel(self: *Self, channel_id: Snowflake, edit_channel: Types.ModifyChannel) RequestFailedError!zjson.Owned(Types.Channel) {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/channels/{d}", .{channel_id.into()});

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    const res = try req.patch(Types.Channel, path, edit_channel);
    return res;
}

/// Method to create a channel
pub fn createChannel(self: *Self, guild_id: Snowflake, create_channel: Types.CreateGuildChannel) RequestFailedError!zjson.Owned(Types.Channel) {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}/channels", .{guild_id.into()});

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    const res = try req.post(Types.Channel, path, create_channel);
    return res;
}

// Methods for guild-related actions

/// Method to fetch a guild
/// Returns the guild object for the given id.
/// If `with_counts` is set to true, this endpoint will also return `approximate_member_count` and `approximate_presence_count` for the guild.
pub fn fetchGuild(self: *Self, guild_id: Snowflake) RequestFailedError!zjson.Owned(Types.Guild) {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}", .{guild_id.into()});

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    const res = try req.get(Types.Guild, path);
    return res;
}

/// Method to fetch a guild preview
/// Returns the guild preview object for the given id. If the user is not in the guild, then the guild must be discoverable.
pub fn fetchGuildPreview(self: *Self, guild_id: Snowflake) RequestFailedError!zjson.Owned(Types.GuildPreview) {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}/preview", .{guild_id.into()});

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    const res = try req.get(Types.GuildPreview, path);
    return res;
}

/// Method to fetch a guild's channels
/// Returns a list of guild channel objects. Does not include threads.
/// TODO: implement query string parameters
pub fn fetchGuildChannels(self: *Self, guild_id: Snowflake) RequestFailedError!zjson.Owned([]Types.Channel) {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}/channels", .{guild_id.into()});

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    const res = try req.get([]Types.Channel, path);
    return res;
}

/// Method to create a guild channel
/// Create a new channel object for the guild.
/// Requires the `MANAGE_CHANNELS` permission.
/// If setting permission overwrites, only permissions your bot has in the guild can be allowed/denied.
/// Setting `MANAGE_ROLES` permission in channels is only possible for guild administrators.
/// Returns the new channel object on success. Fires a Channel Create Gateway event.
pub fn createGuildChannel(self: *Self, guild_id: Snowflake, create_guild_channel: Types.CreateGuildChannel) RequestFailedError!zjson.Owned(Types.Channel) {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}/channels", .{guild_id.into()});

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    const res = try req.post(Types.Channel, path, create_guild_channel);
    return res;
}

/// Method to edit a guild channel's positions
/// Create a new channel object for the guild.
/// Requires the `MANAGE_CHANNELS` permission.
/// If setting permission overwrites, only permissions your bot has in the guild can be allowed/denied.
/// Setting `MANAGE_ROLES` permission in channels is only possible for guild administrators.
/// Returns the new channel object on success. Fires a Channel Create Gateway event.
pub fn editGuildChannelPositions(self: *Self, guild_id: Snowflake, edit_guild_channel: Types.ModifyGuildChannelPositions) RequestFailedError!void {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}/channels", .{guild_id.into()});

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    try req.patch2(void, path, edit_guild_channel);
}

/// Method to get a guild's active threads
/// Returns all active threads in the guild, including public and private threads.
/// Threads are ordered by their `id`, in descending order.
/// TODO: implement query string parameters
pub fn fetchGuildActiveThreads(self: *Self, guild_id: Snowflake) RequestFailedError!zjson.Owned(Types.Channel) {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}/threads/active", .{guild_id.into()});

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    const res = try req.get([]Types.Channel, path);
    return res;
}

/// Method to get a member
/// Returns a guild member object for the specified user.
pub fn fetchMember(self: *Self, guild_id: Snowflake, user_id: Snowflake) RequestFailedError!zjson.Owned(Types.Member) {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}/members/{d}", .{ guild_id.into(), user_id.into() });

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    const res = try req.get(Types.Member, path);
    return res;
}

/// Method to get the members of a guild
/// Returns a list of guild member objects that are members of the guild.
/// TODO: implement query string parameters
pub fn fetchMembers(self: *Self, guild_id: Snowflake) RequestFailedError!zjson.Owned([]Types.Member) {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}/members", .{guild_id.into()});

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    const res = try req.get([]Types.Member, path);
    return res;
}

/// Method to find members
/// Returns a list of guild member objects whose username or nickname starts with a provided string.
pub fn searchMembers(self: *Self, guild_id: Snowflake, query: struct {
    query: []const u8,
    limit: usize,
}) RequestFailedError!zjson.Owned([]Types.Member) {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}/members/search?query={s}&limit={d}", .{
        guild_id.into(),
        query.query,
        query.limit,
    });

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    const res = try req.get([]Types.Member, path);
    return res;
}

/// Adds a user to the guild, provided you have a valid oauth2 access token for the user with the guilds.join scope.
/// Returns a 201 Created with the guild member as the body, or 204 No Content if the user is already a member of the guild.
/// Fires a Guild Member Add Gateway event.
///
/// For guilds with Membership Screening enabled, this endpoint will default to adding new members as pending in the guild member object.
/// Members that are pending will have to complete membership screening before they become full members that can talk.
pub fn addMember(self: *Self, guild_id: Snowflake, user_id: Snowflake, credentials: Types.AddGuildMember) RequestFailedError!?zjson.Owned(Types.Member) {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}/members/{d}", .{ guild_id.into(), user_id.into() });

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    const res = try req.put2(Types.Member, path, credentials);
    return res;
}

/// Method to edit a member's attributes
/// Modify attributes of a guild member.
/// Returns a 200 OK with the guild member as the body.
/// Fires a Guild Member Update Gateway event. If the channel_id is set to null,
/// this will force the target user to be disconnected from voice.
pub fn editMember(self: *Self, guild_id: Snowflake, user_id: Snowflake, attributes: Types.ModifyGuildMember) RequestFailedError!?zjson.Owned(Types.Member) {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}/members/{d}", .{ guild_id.into(), user_id.into() });

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    const res = try req.patch(Types.Member, path, attributes);
    return res;
}

/// Method to edit a ones's attributes
pub fn editCurrentMember(self: *Self, guild_id: Snowflake, attributes: Types.ModifyGuildMember) RequestFailedError!?zjson.Owned(Types.Member) {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}/members/@me", .{guild_id.into()});

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    const res = try req.patch(Types.Member, path, attributes);
    return res;
}

/// change's someones's nickname
pub fn changeNickname(self: *Self, guild_id: Snowflake, user_id: Snowflake, attributes: Types.ModifyGuildMember) RequestFailedError!void {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}/members/{d}", .{ guild_id.into(), user_id.into() });

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    const res = try req.patch(Types.Member, path, attributes);
    defer res.deinit();
}

/// change's someones's nickname
pub fn changeMyNickname(self: *Self, guild_id: Snowflake, attributes: Types.ModifyGuildMember) RequestFailedError!void {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}/members/@me", .{guild_id.into()});

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    const res = try req.patch(Types.Member, path, attributes);
    defer res.deinit();
}

/// Adds a role to a guild member. Requires the `MANAGE_ROLES` permission.
/// Returns a 204 empty response on success.
/// Fires a Guild Member Update Gateway event.
pub fn addRole(
    self: *Self,
    guild_id: Snowflake,
    user_id: Snowflake,
    role_id: Snowflake,
) RequestFailedError!void {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}/members/{d}/roles/{d}", .{
        guild_id.into(),
        user_id.into(),
        role_id.into(),
    });

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    try req.put3(path);
}

/// Removes a role from a guild member.
/// Requires the `MANAGE_ROLES` permission.
/// Returns a 204 empty response on success.
/// Fires a Guild Member Update Gateway event.
pub fn removeRole(
    self: *Self,
    guild_id: Snowflake,
    user_id: Snowflake,
    role_id: Snowflake,
) RequestFailedError!void {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}/members/{d}/roles/{d}", .{
        guild_id.into(),
        user_id.into(),
        role_id.into(),
    });

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    try req.delete(path);
}

/// Remove a member from a guild.
/// Requires `KICK_MEMBERS` permission.
/// Returns a 204 empty response on success.
/// Fires a Guild Member Remove Gateway event.
pub fn kickMember(
    self: *Self,
    guild_id: Snowflake,
    user_id: Snowflake,
) RequestFailedError!void {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}/members/{d}", .{ guild_id.into(), user_id.into() });

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    try req.delete(path);
}

/// Returns a list of ban objects for the users banned from this guild.
/// Requires the `BAN_MEMBERS` permission.
/// TODO: add query params
pub fn fetchBans(
    self: *Self,
    guild_id: Snowflake,
) RequestFailedError!zjson.Owned([]Types.Ban) {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}/bans", .{guild_id.into()});

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    const res = try req.get([]Types.Ban, path);
    return res;
}

/// Returns a ban object for the given user or a 404 not found if the ban cannot be found.
/// Requires the `BAN_MEMBERS` permission.
pub fn fetchBan(self: *Self, guild_id: Snowflake, user_id: Snowflake) RequestFailedError!zjson.Owned(Types.Ban) {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}/bans/{d}", .{ guild_id.into(), user_id.into() });

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    const res = try req.get(Types.Ban, path);
    return res;
}

/// Create a guild ban, and optionally delete previous messages sent by the banned user.
/// Requires the `BAN_MEMBERS` permission.
/// Returns a 204 empty response on success.
/// Fires a Guild Ban Add Gateway event.
pub fn ban(self: *Self, guild_id: Snowflake, user_id: Snowflake) RequestFailedError!void {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}/bans/{d}", .{ guild_id.into(), user_id.into() });

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    try req.put3(path);
}

/// Remove the ban for a user. Requires the `BAN_MEMBERS` permissions.
/// Returns a 204 empty response on success.
/// Fires a Guild Ban Remove Gateway event.
pub fn unban(self: *Self, guild_id: Snowflake, user_id: Snowflake) RequestFailedError!void {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}/bans/{d}", .{ guild_id.into(), user_id.into() });

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    try req.delete(path);
}

/// Ban up to 200 users from a guild, and optionally delete previous messages sent by the banned users.
/// Requires both the `BAN_MEMBERS` and `MANAGE_GUILD` permissions.
/// Returns a 200 response on success, including the fields banned_users with the IDs of the banned users
/// and failed_users with IDs that could not be banned or were already banned.
pub fn bulkBan(self: *Self, guild_id: Snowflake, bulk_ban: Types.CreateGuildBan) RequestFailedError!zjson.Owned(Types.BulkBan) {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}/bulk-ban", .{guild_id.into()});

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    const res = try req.post(Types.BulkBan, path, bulk_ban);
    return res;
}

/// Method to delete a guild
/// Delete a guild permanently. User must be owner.
/// Returns 204 No Content on success.
/// Fires a Guild Delete Gateway event.
pub fn deleteGuild(self: *Self, guild_id: Snowflake) RequestFailedError!void {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}", .{guild_id.into()});

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    try req.delete(path);
}

/// Method to edit a guild
/// Modify a guild's settings. Requires the `MANAGE_GUILD` permission.
/// Returns the updated guild object on success.
/// Fires a Guild Update Gateway event.
pub fn editGuild(self: *Self, guild_id: Snowflake, edit_guild: Types.ModifyGuild) RequestFailedError!zjson.Owned(Types.Guild) {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}", .{guild_id.into()});

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    const res = try req.patch(Types.Guild, path, edit_guild);
    return res;
}

/// Method to create a guild
pub fn createGuild(self: *Self, create_guild: Partial(Types.CreateGuild)) RequestFailedError!zjson.Owned(Types.Guild) {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds", .{});

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    const res = try req.post(Types.Guild, path, create_guild);
    return res;
}

/// Create a new role for the guild.
/// Requires the `MANAGE_ROLES` permission.
/// Returns the new role object on success.
/// Fires a Guild Role Create Gateway event.
/// All JSON params are optional.
pub fn createRole(self: *Self, guild_id: Snowflake, create_role: Partial(Types.CreateGuildRole)) RequestFailedError!zjson.Owned(Types.Role) {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}/roles", .{guild_id.into()});

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    const res = try req.post(Types.Role, path, create_role);
    return res;
}

/// Modify the positions of a set of role objects for the guild.
/// Requires the `MANAGE_ROLES` permission.
/// Returns a list of all of the guild's role objects on success.
/// Fires multiple Guild Role Update Gateway events.
pub fn editRole(self: *Self, guild_id: Snowflake, role_id: Snowflake, edit_role: Partial(Types.ModifyGuildRole)) RequestFailedError!zjson.Owned(Types.Role) {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}/roles/{d}", .{ guild_id.into(), role_id.into() });

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    const res = try req.patch(Types.Role, path, edit_role);
    return res;
}

/// Modify a guild's MFA level.
/// Requires guild ownership.
/// Returns the updated level on success.
/// Fires a Guild Update Gateway event.
pub fn modifyMFALevel(self: *Self, guild_id: Snowflake) RequestFailedError!void {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}/mfa", .{guild_id.into()});

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    try req.delete(Types.Role, path);
}

/// Delete a guild role.
/// Requires the `MANAGE_ROLES` permission.
/// Returns a 204 empty response on success.
/// Fires a Guild Role Delete Gateway event.
pub fn deleteRole(self: *Self, guild_id: Snowflake, role_id: Snowflake) RequestFailedError!void {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}/roles/{d}", .{ guild_id.into(), role_id.into() });

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    try req.delete(Types.Role, path);
}

/// Returns an object with one pruned key indicating the number of members that would be removed in a prune operation.
/// Requires the `MANAGE_GUILD` and `KICK_MEMBERS` permissions.
/// By default, prune will not remove users with roles.
/// You can optionally include specific roles in your prune by providing the include_roles parameter.
/// Any inactive user that has a subset of the provided role(s) will be counted in the prune and users with additional roles will not.
/// TODO: implement query
pub fn fetchPruneCount(self: *Self, guild_id: Snowflake, _: Types.GetGuildPruneCountQuery) RequestFailedError!zjson.Owned(struct { pruned: isize }) {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}/prune", .{guild_id.into()});

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    const pruned = try req.get(struct { pruned: isize }, path);
    return pruned;
}

/// Begin a prune operation.
/// Requires the `MANAGE_GUILD` and `KICK_MEMBERS` permissions.
/// Returns an object with one `pruned` key indicating the number of members that were removed in the prune operation.
/// For large guilds it's recommended to set the `compute_prune_count` option to false, forcing `pruned` to `null`.
/// Fires multiple Guild Member Remove Gateway events.
///
/// By default, prune will not remove users with roles.
/// You can optionally include specific roles in your prune by providing the `include_roles` parameter.
/// Any inactive user that has a subset of the provided role(s) will be included in the prune and users with additional roles will not.
pub fn beginGuildPrune(self: *Self, guild_id: Snowflake, params: Types.BeginGuildPrune) RequestFailedError!zjson.Owned(struct { pruned: isize }) {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}/prune", .{guild_id.into()});

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    const pruned = try req.post(struct { pruned: isize }, path, params);
    return pruned;
}

/// Returns a list of voice region objects for the guild.
/// Unlike the similar /voice route, this returns VIP servers when the guild is VIP-enabled.
pub fn fetchVoiceRegion(self: *Self, guild_id: Snowflake) RequestFailedError!zjson.Owned([]Types.VoiceRegion) {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}/regions", .{guild_id.into()});

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    const regions = try req.get([]Types.VoiceRegion, path);
    return regions;
}

/// Returns a list of invite objects (with invite metadata) for the guild.
/// Requires the `MANAGE_GUILD` permission.
pub fn fetchInvites(self: *Self, guild_id: Snowflake) RequestFailedError!zjson.Owned([]Types.Invite) {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}/invites", .{guild_id.into()});

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    const invites = try req.get([]Types.Invite, path);
    return invites;
}

/// Returns a list of integration objects for the guild.
/// Requires the `MANAGE_GUILD` permission.
pub fn fetchIntegrations(self: *Self, guild_id: Snowflake) RequestFailedError!zjson.Owned([]Types.Integration) {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}/integrations", .{guild_id.into()});

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    const integrations = try req.get([]Types.integrations, path);
    return integrations;
}

/// Returns a list of integration objects for the guild.
/// Requires the `MANAGE_GUILD` permission.
pub fn deleteIntegration(
    self: *Self,
    guild_id: Snowflake,
    integration_id: Snowflake,
) RequestFailedError!void {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}/integrations/{d}", .{
        guild_id.into(),
        integration_id.into(),
    });

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    try req.delete(path);
}

/// Returns a guild widget settings object.
/// Requires the `MANAGE_GUILD` permission.
pub fn fetchWidgetSettings(self: *Self, guild_id: Snowflake) RequestFailedError!zjson.Owned(Types.GuildWidgetSettings) {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}/widget", .{guild_id.into()});

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    const widget = try req.get(Types.GuildWidgetSettings, path);
    return widget;
}

/// Modify a guild widget settings object for the guild.
/// All attributes may be passed in with JSON and modified.
/// Requires the `MANAGE_GUILD` permission.
/// Returns the updated guild widget settings object.
/// Fires a Guild Update Gateway event.
pub fn editWidget(self: *Self, guild_id: Snowflake, attributes: Partial(Types.GuildWidget)) RequestFailedError!zjson.Owned(Types.GuildWidget) {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}/widget", .{guild_id.into()});

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    const widget = try req.patch(Types.GuildWidget, path, attributes);
    return widget;
}

/// Returns the widget for the guild.
/// Fires an Invite Create Gateway event when an invite channel is defined and a new Invite is generated.
pub fn fetchWidget(self: *Self, guild_id: Snowflake) RequestFailedError!zjson.Owned(Types.GuildWidget) {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}/widget.json", .{guild_id.into()});

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    const widget = try req.get(Types.GuildWidget, path);
    return widget;
}

/// Returns a partial invite object for guilds with that feature enabled.
/// Requires the `MANAGE_GUILD` permission. code will be null if a vanity url for the guild is not set.
pub fn fetchVanityUrl(self: *Self, guild_id: Snowflake) RequestFailedError!zjson.Owned(Partial(Types.Invite)) {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}/vanity-url", .{guild_id.into()});

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    const invite = try req.get(Partial(Types.Invite), path);
    return invite;
}

/// Returns a PNG image widget for the guild.
/// Requires no permissions or authentication.
pub fn fetchWidgetImage(self: *Self, guild_id: Snowflake) RequestFailedError![]const u8 {
    _ = self;
    _ = guild_id;
    @panic("unimplemented");
}

/// Modify the guild's Welcome Screen.
/// Requires the `MANAGE_GUILD` permission.
/// Returns the updated Welcome Screen object. May fire a Guild Update Gateway event.
/// TODO: add query params
pub fn fetchWelcomeScreen(self: *Self, guild_id: Snowflake) RequestFailedError!zjson.Owned(Types.WelcomeScreen) {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}/welcome-screen", .{guild_id.into()});

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    const welcome_screen = try req.get(Types.WelcomeScreen, path);
    return welcome_screen;
}

/// Returns the Onboarding object for the guild.
pub fn fetchOnboarding(self: *Self, guild_id: Snowflake) RequestFailedError!zjson.Owned(Types.GuildOnboarding) {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}/onboarding", .{guild_id.into()});

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    const ob = try req.get(Types.GuildOnboarding, path);
    return ob;
}

/// Returns the Onboarding object for the guild.
pub fn editOnboarding(self: *Self, guild_id: Snowflake, onboarding: Types.GuildOnboardingPromptOption) RequestFailedError!zjson.Owned(Types.GuildOnboarding) {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/guilds/{d}/onboarding", .{guild_id.into()});

    var req = FetchReq.init(self.allocator, self.details.token);
    defer req.deinit();

    const ob = try req.put(Types.GuildOnboarding, path, onboarding);
    return ob;
}
