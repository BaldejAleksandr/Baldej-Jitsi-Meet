-- Gives the 'file-upload' feature to every participant that joined without a token.
-- Managed by Ansible (role jitsi_file_sharing). Load it on the main MUC component
-- (XMPP_MUC_MODULES in docker-jitsi-meet).
--
-- mod_jitsi_permissions sends permissions (jitsi_default_permissions) only to
-- moderators. This module covers the other participants:
--   * a participant that is not a moderator and has no features gets
--     { ['file-upload'] = true }, and the client receives it in <permissions>;
--   * only this one feature is set. For a session with features a missing feature
--     means "not allowed", and a participant without features is not allowed
--     anything that needs moderator rights, so the other checks stay the same;
--   * when such a participant becomes a moderator, the features are removed before
--     mod_jitsi_permissions handles the grant, so the moderator gets the full
--     jitsi_default_permissions.
-- Sessions with a token are not touched: their features come from the token.

local filters = require 'util.filters';
local jid = require 'util.jid';

local util = module:require 'util';
local is_admin = util.is_admin;
local get_room_from_jid = util.get_room_from_jid;
local is_healthcheck_room = util.is_healthcheck_room;
local room_jid_match_rewrite = util.room_jid_match_rewrite;
local presence_check_status = util.presence_check_status;

local MUC_NS = 'http://jabber.org/protocol/muc';
local PARTICIPANT_FEATURES = { ['file-upload'] = true };

local muc_domain_prefix = module:get_option_string('muc_mapper_domain_prefix', 'conference');
local muc_domain_base = module:get_option_string('muc_mapper_domain_base');

if not muc_domain_base or muc_domain_prefix..'.'..muc_domain_base ~= module.host then
    module:log('error', 'Load this module only on the main MUC component (%s.%s)',
        muc_domain_prefix, tostring(muc_domain_base));
    return;
end

local function copy_features(features)
    local res = {};
    for k, v in pairs(features) do
        res[k] = v;
    end
    return res;
end

-- Runs after the filter of mod_jitsi_permissions (priority -2), so it sees the
-- features that module has set for moderators.
local function filter_stanza(stanza, session)
    if stanza.name ~= 'presence' or not stanza.attr or not stanza.attr.to
        or stanza.attr.type == 'unavailable' then
        return stanza;
    end

    -- token users get their features from the token; already handled sessions skip
    if session.auth_token or session.jitsi_meet_context_features then
        return stanza;
    end

    if is_admin(jid.bare(stanza.attr.to)) then
        return stanza;
    end

    -- only the self-presence of the participant
    local muc_x = stanza:get_child('x', MUC_NS..'#user');
    if not muc_x or not presence_check_status(muc_x, '110') then
        return stanza;
    end

    local room = get_room_from_jid(room_jid_match_rewrite(jid.bare(stanza.attr.from)));
    if not room or is_healthcheck_room(room.jid) then
        return stanza;
    end

    for item in muc_x:childtags('item') do
        if item.attr.role == 'moderator' then
            -- moderators are handled by mod_jitsi_permissions
            return stanza;
        end
    end

    session.jitsi_meet_context_features = copy_features(PARTICIPANT_FEATURES);
    session.file_sharing_everyone = true;

    stanza:tag('permissions', { xmlns = 'http://jitsi.org/jitmeet' });
    for k, v in pairs(session.jitsi_meet_context_features) do
        stanza:tag('p', { name = k, val = tostring(v) }):up();
    end
    stanza:up();

    return stanza;
end

-- Before mod_jitsi_permissions (default priority 0) handles a grant of owner,
-- drop the features set here, so the new moderator gets the default permissions.
module:hook('muc-pre-set-affiliation', function(event)
    if event.affiliation ~= 'owner' then
        return;
    end

    local bare_session = prosody.bare_sessions[event.jid];
    if not bare_session then
        return;
    end

    for _, session in pairs(bare_session.sessions) do
        if session.file_sharing_everyone then
            session.jitsi_meet_context_features = nil;
            session.file_sharing_everyone = nil;
        end
    end
end, 10);

filters.add_filter_hook(function(session)
    filters.add_filter(session, 'stanzas/out', filter_stanza, -3);
end);

module:log('info', 'File upload is allowed for all participants');
