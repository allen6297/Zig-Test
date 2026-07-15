//! The client↔server wire protocol: the messages that cross the `Connection`,
//! plus their byte encoding for the networked transport. Deliberately
//! transport-agnostic — plain data whether it travels through an in-process queue
//! (single-player) or an ENet socket (multiplayer).
//!
//! **Actions** flow client→server (requests to change the world). **Events** flow
//! server→client (authoritative notifications). The client never mutates the
//! world itself; it asks, and reacts to what the server confirms.

const std = @import("std");
const BlockId = @import("block.zig").BlockId;

/// A block set at a world coordinate. Used as both a client request (Action) and
/// the server's confirmation (Event) — the payload is identical.
pub const BlockChange = struct {
    x: i32,
    y: i32,
    z: i32,
    block: BlockId,
};

/// A player/entity's replicated state: feet position + facing yaw.
pub const PlayerState = struct {
    x: f32,
    y: f32,
    z: f32,
    yaw: f32,
};

/// A remote entity: a server-assigned id + its state.
pub const Entity = struct {
    id: u32,
    state: PlayerState,
};

/// Client → server. A request; the server validates and decides to apply it.
pub const Action = union(enum) {
    set_block: BlockChange,
};

/// Server → client. An authoritative fact the client applies to its view.
pub const Event = union(enum) {
    block_changed: BlockChange,
};

/// Anything a client can send: a world-mutation action, or its own position
/// report (relayed to other clients, not a world mutation).
pub const ClientMessage = union(enum) {
    set_block: BlockChange,
    player_state: PlayerState,
};

// --- wire encoding ---
//
// One byte tag then a fixed little-endian payload. Tags are unique across both
// directions so a decoder never has to know which way a packet is going. The
// world snapshot (join sync) is variable-length and framed by the net layer with
// `tag_snapshot`.

pub const tag_set_block: u8 = 1; // client → server: an Action.set_block
pub const tag_block_changed: u8 = 2; // server → client: an Event.block_changed
pub const tag_snapshot: u8 = 3; // server → client: World.serialize() bytes follow
pub const tag_player_state: u8 = 4; // client → server: this client's position report
pub const tag_assign_id: u8 = 5; // server → client: "your entity id is N"
pub const tag_entity_moved: u8 = 6; // server → client: an entity's new state (create-or-update)
pub const tag_entity_despawn: u8 = 7; // server → client: an entity left

/// Bytes a player_state message occupies: tag + 4×f32.
pub const player_state_len = 1 + 16;
/// Bytes an entity_moved message occupies: tag + u32 id + 4×f32.
pub const entity_moved_len = 1 + 4 + 16;
/// Bytes an id-only message (assign_id / entity_despawn): tag + u32.
pub const id_msg_len = 1 + 4;

fn writeF32(buf: []u8, off: usize, v: f32) void {
    std.mem.writeInt(u32, buf[off..][0..4], @bitCast(v), .little);
}
fn readF32(bytes: []const u8, off: usize) f32 {
    return @bitCast(std.mem.readInt(u32, bytes[off..][0..4], .little));
}
fn writePlayerState(buf: []u8, off: usize, s: PlayerState) void {
    writeF32(buf, off, s.x);
    writeF32(buf, off + 4, s.y);
    writeF32(buf, off + 8, s.z);
    writeF32(buf, off + 12, s.yaw);
}
fn readPlayerState(bytes: []const u8, off: usize) PlayerState {
    return .{ .x = readF32(bytes, off), .y = readF32(bytes, off + 4), .z = readF32(bytes, off + 8), .yaw = readF32(bytes, off + 12) };
}

/// Bytes a tagged BlockChange message occupies: tag + i32 x,y,z + u16 block.
pub const block_msg_len = 1 + 4 + 4 + 4 + 2;

fn writeBlockChange(buf: []u8, tag: u8, b: BlockChange) []u8 {
    buf[0] = tag;
    std.mem.writeInt(i32, buf[1..][0..4], b.x, .little);
    std.mem.writeInt(i32, buf[5..][0..4], b.y, .little);
    std.mem.writeInt(i32, buf[9..][0..4], b.z, .little);
    std.mem.writeInt(u16, buf[13..][0..2], @intFromEnum(b.block), .little);
    return buf[0..block_msg_len];
}

fn readBlockChange(bytes: []const u8) BlockChange {
    return .{
        .x = std.mem.readInt(i32, bytes[1..][0..4], .little),
        .y = std.mem.readInt(i32, bytes[5..][0..4], .little),
        .z = std.mem.readInt(i32, bytes[9..][0..4], .little),
        .block = @enumFromInt(std.mem.readInt(u16, bytes[13..][0..2], .little)),
    };
}

/// Encode an action into `buf` (must be ≥ block_msg_len); returns the used slice.
pub fn encodeAction(a: Action, buf: []u8) []u8 {
    return switch (a) {
        .set_block => |b| writeBlockChange(buf, tag_set_block, b),
    };
}

/// Encode this client's position report into `buf` (≥ player_state_len).
pub fn encodePlayerState(s: PlayerState, buf: []u8) []u8 {
    buf[0] = tag_player_state;
    writePlayerState(buf, 1, s);
    return buf[0..player_state_len];
}

/// Decode any client→server packet (an action or a position report).
pub fn decodeClientMessage(bytes: []const u8) ?ClientMessage {
    if (bytes.len < 1) return null;
    return switch (bytes[0]) {
        tag_set_block => if (bytes.len >= block_msg_len) .{ .set_block = readBlockChange(bytes) } else null,
        tag_player_state => if (bytes.len >= player_state_len) .{ .player_state = readPlayerState(bytes, 1) } else null,
        else => null,
    };
}

/// Encode an event into `buf` (must be ≥ block_msg_len); returns the used slice.
pub fn encodeEvent(e: Event, buf: []u8) []u8 {
    return switch (e) {
        .block_changed => |b| writeBlockChange(buf, tag_block_changed, b),
    };
}

/// Encode an id-only server message (assign_id or entity_despawn) into `buf`.
pub fn encodeIdMessage(tag: u8, id: u32, buf: []u8) []u8 {
    buf[0] = tag;
    std.mem.writeInt(u32, buf[1..][0..4], id, .little);
    return buf[0..id_msg_len];
}

/// Encode an entity_moved message (id + state) into `buf` (≥ entity_moved_len).
pub fn encodeEntityMoved(e: Entity, buf: []u8) []u8 {
    buf[0] = tag_entity_moved;
    std.mem.writeInt(u32, buf[1..][0..4], e.id, .little);
    writePlayerState(buf, 5, e.state);
    return buf[0..entity_moved_len];
}

/// What a server→client packet can be. The `snapshot` slice borrows the packet's
/// bytes — copy if you keep it.
pub const ServerMessage = union(enum) {
    block_changed: BlockChange,
    snapshot: []const u8,
    assign_id: u32,
    entity_moved: Entity,
    entity_despawn: u32,
};

pub fn decodeServerMessage(bytes: []const u8) ?ServerMessage {
    if (bytes.len < 1) return null;
    return switch (bytes[0]) {
        tag_block_changed => if (bytes.len >= block_msg_len) .{ .block_changed = readBlockChange(bytes) } else null,
        tag_snapshot => .{ .snapshot = bytes[1..] },
        tag_assign_id => if (bytes.len >= id_msg_len) .{ .assign_id = std.mem.readInt(u32, bytes[1..][0..4], .little) } else null,
        tag_entity_moved => if (bytes.len >= entity_moved_len)
            .{ .entity_moved = .{ .id = std.mem.readInt(u32, bytes[1..][0..4], .little), .state = readPlayerState(bytes, 5) } }
        else
            null,
        tag_entity_despawn => if (bytes.len >= id_msg_len) .{ .entity_despawn = std.mem.readInt(u32, bytes[1..][0..4], .little) } else null,
        else => null,
    };
}

test "action/event round-trip through the wire encoding" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;

    const a = Action{ .set_block = .{ .x = -1234, .y = 42, .z = 999999, .block = .stone } };
    const cm = decodeClientMessage(encodeAction(a, &buf)).?;
    try testing.expectEqual(a.set_block, cm.set_block);

    const e = Event{ .block_changed = .{ .x = 7, .y = -8, .z = 0, .block = .air } };
    const msg = decodeServerMessage(encodeEvent(e, &buf)).?;
    try testing.expectEqual(e.block_changed, msg.block_changed);
}

test "entity messages round-trip through the wire encoding" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;

    const ps = PlayerState{ .x = 1.5, .y = -2.25, .z = 100.0, .yaw = 3.14 };
    const cm = decodeClientMessage(encodePlayerState(ps, &buf)).?;
    try testing.expectEqual(ps, cm.player_state);

    const moved = decodeServerMessage(encodeEntityMoved(.{ .id = 77, .state = ps }, &buf)).?;
    try testing.expectEqual(@as(u32, 77), moved.entity_moved.id);
    try testing.expectEqual(ps, moved.entity_moved.state);

    const assign = decodeServerMessage(encodeIdMessage(tag_assign_id, 5, &buf)).?;
    try testing.expectEqual(@as(u32, 5), assign.assign_id);

    const despawn = decodeServerMessage(encodeIdMessage(tag_entity_despawn, 9, &buf)).?;
    try testing.expectEqual(@as(u32, 9), despawn.entity_despawn);
}

test "snapshot message carries its payload" {
    const testing = std.testing;
    var buf: [5]u8 = .{ tag_snapshot, 0xAA, 0xBB, 0xCC, 0xDD };
    const msg = decodeServerMessage(&buf).?;
    try testing.expectEqualSlices(u8, &.{ 0xAA, 0xBB, 0xCC, 0xDD }, msg.snapshot);
}
