//! The client↔server wire protocol: the messages that cross the `Connection`.
//! Deliberately transport-agnostic — these are plain data, whether they travel
//! through an in-process queue (single-player) or a socket (multiplayer later).
//!
//! **Actions** flow client→server (requests to change the world). **Events** flow
//! server→client (authoritative notifications of what changed). The client never
//! mutates the world itself; it asks, and reacts to what the server confirms.

const BlockId = @import("block.zig").BlockId;

/// A block set at a world coordinate. Used both as a client request (Action) and
/// the server's confirmation (Event) — the payload is the same.
pub const BlockChange = struct {
    x: i32,
    y: i32,
    z: i32,
    block: BlockId,
};

/// Client → server. A request; the server validates and decides whether to apply
/// it. (Reach/permission checks live server-side, added later.)
pub const Action = union(enum) {
    set_block: BlockChange,
    // Later: move_intent, use_item, interact, ...
};

/// Server → client. An authoritative fact the client applies to its view.
pub const Event = union(enum) {
    block_changed: BlockChange,
    // Later: entity_spawn, entity_moved, chunk_data, ...
};
