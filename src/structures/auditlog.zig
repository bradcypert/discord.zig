const Webhook = @import("webhook.zig").Webhook;
const User = @import("user.zig").User;
const Channel = @import("channel.zig").Channel;
const ScheduledEvent = @import("scheduled_event.zig").ScheduledEvent;
const AutoModerationRule = @import("automod.zig").AutoModerationRule;
const Integration = @import("integration.zig").Integration;
const Snowflake = @import("snowflake.zig").Snowflake;
const AuditLogEvents = @import("shared.zig").AuditLogEvents;
const Partial = @import("partial.zig").Partial;
const ApplicationCommand = @import("command.zig").ApplicationCommand;

/// https://discord.com/developers/docs/resources/audit-log#audit-log-object
pub const AuditLog = struct {
    /// List of webhooks found in the audit log
    webhooks: []Webhook,
    /// List of users found in the audit log
    users: []User,
    /// List of audit log entries, sorted from most to least recent
    audit_log_entries: []AuditLogEntry,
    /// List of partial integration objects
    integrations: []Partial(Integration),
    ///
    /// List of threads found in the audit log.
    /// Threads referenced in `THREAD_CREATE` and `THREAD_UPDATE` events are included in the threads map since archived threads might not be kept in memory by clients.
    ///
    threads: []Channel,
    /// List of guild scheduled events found in the audit log
    guild_scheduled_events: []?ScheduledEvent,
    /// List of auto moderation rules referenced in the audit log
    auto_moderation_rules: []?AutoModerationRule,
    /// List of application commands referenced in the audit log
    application_commands: []ApplicationCommand,
};

/// https://discord.com/developers/docs/resources/audit-log#audit-log-entry-object-audit-log-entry-structure
pub const AuditLogEntry = struct {
    /// ID of the affected entity (webhook, user, role, etc.)
    target_id: ?Snowflake,
    /// Changes made to the `target_id`
    /// TODO: change this
    changes: []?AuditLogChange(noreturn),
    /// User or app that made the changes
    user_id: ?Snowflake,
    /// ID of the entry
    id: Snowflake,
    /// Type of action that occurred
    action_type: AuditLogEvents,
    /// Additional info for certain event types
    options: ?OptionalAuditEntryInfo,
    /// Reason for the change (1-512 characters)
    reason: ?[]const u8,
};

pub fn AuditLogChange(comptime T: type) type {
    return T;
}

/// https://discord.com/developers/docs/resources/audit-log#audit-log-entry-object-optional-audit-entry-info
pub const OptionalAuditEntryInfo = struct {
    ///
    /// ID of the app whose permissions were targeted.
    ///
    /// Event types: `APPLICATION_COMMAND_PERMISSION_UPDATE`,
    ///
    application_id: ?Snowflake,
    ///
    /// Name of the Auto Moderation rule that was triggered.
    ///
    /// Event types: `AUTO_MODERATION_BLOCK_MESSAGE`, `AUTO_MODERATION_FLAG_TO_CHANNEL`, `AUTO_MODERATION_USER_COMMUNICATION_DISABLED`,
    ///
    auto_moderation_rule_name: ?[]const u8,
    ///
    /// Trigger type of the Auto Moderation rule that was triggered.
    ///
    /// Event types: `AUTO_MODERATION_BLOCK_MESSAGE`, `AUTO_MODERATION_FLAG_TO_CHANNEL`, `AUTO_MODERATION_USER_COMMUNICATION_DISABLED`,
    ///
    auto_moderation_rule_trigger_type: ?[]const u8,
    ///
    /// Channel in which the entities were targeted.
    ///
    /// Event types: `MEMBER_MOVE`, `MESSAGE_PIN`, `MESSAGE_UNPIN`, `MESSAGE_DELETE`, `STAGE_INSTANCE_CREATE`, `STAGE_INSTANCE_UPDATE`, `STAGE_INSTANCE_DELETE`,
    ///
    channel_id: ?Snowflake,
    ///
    /// isize of entities that were targeted.
    ///
    /// Event types: `MESSAGE_DELETE`, `MESSAGE_BULK_DELETE`, `MEMBER_DISCONNECT`, `MEMBER_MOVE`,
    ///
    count: ?[]const u8,
    ///
    /// isize of days after which inactive members were kicked.
    ///
    /// Event types: `MEMBER_PRUNE`,
    ///
    delete_member_days: ?[]const u8,
    ///
    /// ID of the overwritten entity.
    ///
    /// Event types: `CHANNEL_OVERWRITE_CREATE`, `CHANNEL_OVERWRITE_UPDATE`, `CHANNEL_OVERWRITE_DELETE`,
    ///
    id: ?Snowflake,
    ///
    /// isize of members removed by the prune.
    ///
    /// Event types: `MEMBER_PRUNE`,
    ///
    members_removed: ?[]const u8,
    ///
    /// ID of the message that was targeted.
    ///
    /// Event types: `MESSAGE_PIN`, `MESSAGE_UNPIN`, `STAGE_INSTANCE_CREATE`, `STAGE_INSTANCE_UPDATE`, `STAGE_INSTANCE_DELETE`,
    ///
    message_id: ?Snowflake,
    ///
    /// Name of the role if type is "0" (not present if type is "1").
    ///
    /// Event types: `CHANNEL_OVERWRITE_CREATE`, `CHANNEL_OVERWRITE_UPDATE`, `CHANNEL_OVERWRITE_DELETE`,
    ///
    role_name: ?[]const u8,
    ///
    /// Type of overwritten entity - "0", for "role", or "1" for "member".
    ///
    /// Event types: `CHANNEL_OVERWRITE_CREATE`, `CHANNEL_OVERWRITE_UPDATE`, `CHANNEL_OVERWRITE_DELETE`,
    ///
    type: ?[]const u8,
    ///
    /// The type of integration which performed the action
    ///
    /// Event types: `MEMBER_KICK`, `MEMBER_ROLE_UPDATE`,
    ///
    integration_type: ?[]const u8,
};
