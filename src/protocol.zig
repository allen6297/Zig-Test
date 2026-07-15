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

/// Client → server. A request; the server validates and decides to apply it.
pub const Action = union(enum) {
    set_block: BlockChange,
};

/// Server → client. An authoritative fact the client applies to its view.
pub const Event = union(enum) {
    block_changed: BlockChange,
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

/// Decode a client→server action packet, or null if malformed.
pub fn decodeAction(bytes: []const u8) ?Action {
    if (bytes.len < block_msg_len or bytes[0] != tag_set_block) return null;
    return .{ .set_block = readBlockChange(bytes) };
}

/// Encode an event into `buf` (must be ≥ block_msg_len); returns the used slice.
pub fn encodeEvent(e: Event, buf: []u8) []u8 {
    return switch (e) {
        .block_changed => |b| writeBlockChange(buf, tag_block_changed, b),
    };
}

/// What a server→client packet can be: an event, or the join-time world snapshot
/// (the `snapshot` slice borrows the packet's bytes — copy if you keep it).
pub const ServerMessage = union(enum) {
    block_changed: BlockChange,
    snapshot: []const u8,
};

pub fn decodeServerMessage(bytes: []const u8) ?ServerMessage {
    if (bytes.len < 1) return null;
    return switch (bytes[0]) {
        tag_block_changed => if (bytes.len >= block_msg_len)
            .{ .block_changed = readBlockChange(bytes) }
        else
            null,
        tag_snapshot => .{ .snapshot = bytes[1..] },
        else => null,
    };
}

test "action/event round-trip through the wire encoding" {
    const testing = std.testing;
    var buf: [block_msg_len]u8 = undefined;

    const a = Action{ .set_block = .{ .x = -1234, .y = 42, .z = 999999, .block = .stone } };
    const a2 = decodeAction(encodeAction(a, &buf)).?;
    try testing.expectEqual(a.set_block, a2.set_block);

    const e = Event{ .block_changed = .{ .x = 7, .y = -8, .z = 0, .block = .air } };
    const msg = decodeServerMessage(encodeEvent(e, &buf)).?;
    try testing.expectEqual(e.block_changed, msg.block_changed);
}

test "snapshot message carries its payload" {
    const testing = std.testing;
    var buf: [5]u8 = .{ tag_snapshot, 0xAA, 0xBB, 0xCC, 0xDD };
    const msg = decodeServerMessage(&buf).?;
    try testing.expectEqualSlices(u8, &.{ 0xAA, 0xBB, 0xCC, 0xDD }, msg.snapshot);
}
