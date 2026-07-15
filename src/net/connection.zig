//! The client↔server boundary. This is the single seam multiplayer will slot
//! into: today it's two in-process queues (single-player, client and server in
//! one process); later it becomes a network socket with the *same* interface, so
//! nothing on either side has to change.
//!
//! The rule the whole architecture leans on: **the client only ever sends
//! actions and reads events through here — it never touches the world directly.**
//! If that holds, we're structurally multiplayer-ready before any networking
//! exists.

const std = @import("std");
const protocol = @import("protocol.zig");
const Action = protocol.Action;
const Event = protocol.Event;

pub const Connection = struct {
    allocator: std.mem.Allocator,
    /// client → server
    actions: std.ArrayList(Action),
    /// server → client
    events: std.ArrayList(Event),

    pub fn init(allocator: std.mem.Allocator) Connection {
        return .{
            .allocator = allocator,
            .actions = std.ArrayList(Action).empty,
            .events = std.ArrayList(Event).empty,
        };
    }

    pub fn deinit(self: *Connection) void {
        self.actions.deinit(self.allocator);
        self.events.deinit(self.allocator);
    }

    // --- client side ---

    /// Queue an action for the server. Dropped on OOM (a lost input, not a crash).
    pub fn sendAction(self: *Connection, action: Action) void {
        self.actions.append(self.allocator, action) catch {};
    }

    /// The events the server has produced since the last `clearEvents`.
    pub fn eventsSlice(self: *const Connection) []const Event {
        return self.events.items;
    }

    pub fn clearEvents(self: *Connection) void {
        self.events.clearRetainingCapacity();
    }

    // --- server side ---

    /// The actions queued by the client since the last `clearActions`.
    pub fn actionsSlice(self: *const Connection) []const Action {
        return self.actions.items;
    }

    pub fn clearActions(self: *Connection) void {
        self.actions.clearRetainingCapacity();
    }

    /// Emit an authoritative event for the client. Dropped on OOM.
    pub fn emitEvent(self: *Connection, event: Event) void {
        self.events.append(self.allocator, event) catch {};
    }
};
