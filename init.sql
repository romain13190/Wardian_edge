-- Wardian Edge — Database Initialization
-- Creates tables for local data storage (conversations, documents, vectors, memory)

CREATE EXTENSION IF NOT EXISTS vector;

-- Conversations (matches cloud schema for gateway-backed storage)
CREATE TABLE IF NOT EXISTS conversations (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    org_id TEXT,
    title TEXT,
    model_id TEXT,
    messages JSONB,
    created_at BIGINT NOT NULL,
    updated_at BIGINT,
    pinned BOOLEAN NOT NULL DEFAULT FALSE,
    conversation_summary TEXT,
    open_threads JSONB,
    key_facts JSONB,
    summary_updated_at BIGINT,
    summary_message_count INT,
    summary_token_est INT,
    encrypted_data TEXT,
    encrypted BOOLEAN DEFAULT false
);
CREATE INDEX IF NOT EXISTS idx_conv_user ON conversations(user_id);
CREATE INDEX IF NOT EXISTS idx_conv_org ON conversations(org_id);

-- Messages
CREATE TABLE IF NOT EXISTS messages (
    id TEXT PRIMARY KEY,
    conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    user_id TEXT,
    org_id TEXT,
    role TEXT NOT NULL,
    content TEXT,
    tokens INT,
    cost_cents INT,
    is_encrypted BOOLEAN DEFAULT FALSE,
    created_at BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_msg_conv ON messages(conversation_id);

-- Auto-create conversation row when a message arrives before the conversation
-- is explicitly saved (race condition between edge_save_messages / edge_save_conversation)
CREATE OR REPLACE FUNCTION auto_create_conversation()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO conversations (id, user_id, org_id, created_at)
    VALUES (NEW.conversation_id, COALESCE(NEW.user_id, ''), COALESCE(NEW.org_id, ''), NEW.created_at)
    ON CONFLICT (id) DO NOTHING;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_auto_create_conversation ON messages;
CREATE TRIGGER trg_auto_create_conversation
    BEFORE INSERT ON messages
    FOR EACH ROW
    EXECUTE FUNCTION auto_create_conversation();

-- Documents
CREATE TABLE IF NOT EXISTS documents (
    id TEXT PRIMARY KEY,
    org_id TEXT,
    user_id TEXT NOT NULL,
    name TEXT NOT NULL,
    content_type TEXT,
    size_bytes INTEGER,
    text_content TEXT,
    visibility TEXT NOT NULL DEFAULT 'private',
    metadata JSONB,
    created_at BIGINT NOT NULL,
    updated_at BIGINT
);
CREATE INDEX IF NOT EXISTS idx_doc_org ON documents(org_id, user_id);

-- Document chunks with vector embeddings
CREATE TABLE IF NOT EXISTS document_chunks (
    id TEXT PRIMARY KEY,
    document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    org_id TEXT,
    user_id TEXT NOT NULL,
    chunk_index INTEGER NOT NULL,
    content TEXT NOT NULL,
    token_count INTEGER,
    visibility TEXT NOT NULL DEFAULT 'private',
    created_at BIGINT NOT NULL,
    embedding vector(4096)
);
CREATE INDEX IF NOT EXISTS idx_chunks_org ON document_chunks(org_id, visibility);
CREATE INDEX IF NOT EXISTS idx_chunks_user ON document_chunks(org_id, user_id, visibility);
CREATE INDEX IF NOT EXISTS idx_chunks_doc ON document_chunks(document_id);

-- User memory (semantic facts)
CREATE TABLE IF NOT EXISTS user_memory (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    org_id TEXT DEFAULT '',
    category TEXT DEFAULT 'general',
    content TEXT NOT NULL,
    embedding vector(4096),
    importance REAL DEFAULT 0.5,
    access_count INTEGER DEFAULT 0,
    last_accessed BIGINT,
    expires_at BIGINT,
    created_at BIGINT NOT NULL,
    updated_at BIGINT
);
CREATE INDEX IF NOT EXISTS idx_memory_user ON user_memory(user_id, org_id);

-- Integration credentials (encrypted OAuth tokens)
CREATE TABLE IF NOT EXISTS integration_credentials (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    org_id TEXT DEFAULT '',
    provider TEXT NOT NULL,
    encrypted_access_token TEXT NOT NULL,
    encrypted_refresh_token TEXT,
    token_expiry BIGINT,
    scopes TEXT,
    email_address TEXT,
    created_at BIGINT NOT NULL,
    updated_at BIGINT,
    UNIQUE(user_id, provider)
);
CREATE INDEX IF NOT EXISTS idx_cred_user ON integration_credentials(user_id, provider);

-- Vault files (encrypted file storage)
CREATE TABLE IF NOT EXISTS vault_files (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    encrypted_envelope TEXT NOT NULL DEFAULT '',
    envelope_iv TEXT NOT NULL DEFAULT '',
    blob_key TEXT NOT NULL,
    blob_size BIGINT NOT NULL,
    created_at BIGINT NOT NULL,
    indexed BOOLEAN NOT NULL DEFAULT false,
    rag_document_id TEXT,
    filename TEXT,
    content_type TEXT,
    source TEXT,
    storage_backend TEXT NOT NULL DEFAULT 'edge'
);
CREATE INDEX IF NOT EXISTS idx_vault_files_user ON vault_files(user_id);

-- Audit logs
CREATE TABLE IF NOT EXISTS audit_logs (
    id TEXT PRIMARY KEY,
    user_id TEXT,
    org_id TEXT,
    action TEXT NOT NULL,
    resource_type TEXT,
    resource_id TEXT,
    details JSONB,
    created_at BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_audit_org ON audit_logs(org_id, created_at);

-- ============================================================
-- Agents (matches cloud migration 008_agents)
-- ============================================================

-- Agent templates
CREATE TABLE IF NOT EXISTS agent_templates (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT,
    icon TEXT,
    category TEXT,
    default_prompt TEXT,
    default_mcp_servers JSONB,
    default_triggers JSONB,
    default_skills JSONB,
    default_config JSONB,
    created_at BIGINT NOT NULL
);

-- Agents
CREATE TABLE IF NOT EXISTS agents (
    id TEXT PRIMARY KEY,
    org_id TEXT NOT NULL,
    name TEXT NOT NULL,
    description TEXT,
    icon TEXT,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'paused', 'disabled')),
    system_prompt TEXT,
    model TEXT,
    mcp_servers JSONB,
    skills JSONB,
    config JSONB,
    template_id TEXT,
    created_by TEXT NOT NULL,
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_agents_org_id ON agents(org_id);

-- Agent access control
CREATE TABLE IF NOT EXISTS agent_access (
    agent_id TEXT NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
    user_id TEXT NOT NULL,
    role TEXT NOT NULL CHECK (role IN ('viewer', 'operator')),
    granted_by TEXT NOT NULL,
    granted_at BIGINT NOT NULL,
    PRIMARY KEY (agent_id, user_id)
);

-- Agent triggers
CREATE TABLE IF NOT EXISTS agent_triggers (
    id TEXT PRIMARY KEY,
    agent_id TEXT NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
    type TEXT NOT NULL CHECK (type IN ('cron', 'heartbeat', 'event')),
    cron_expression TEXT,
    interval_minutes INT,
    check_config JSONB,
    event_source TEXT,
    event_type TEXT,
    event_filter JSONB,
    enabled BOOLEAN NOT NULL DEFAULT true,
    last_fired_at BIGINT,
    created_at BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_agent_triggers_agent_id ON agent_triggers(agent_id);

-- Agent runs
CREATE TABLE IF NOT EXISTS agent_runs (
    id TEXT PRIMARY KEY,
    agent_id TEXT NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
    trigger_id TEXT REFERENCES agent_triggers(id) ON DELETE SET NULL,
    trigger_type TEXT NOT NULL CHECK (trigger_type IN ('cron', 'heartbeat', 'event', 'manual')),
    status TEXT NOT NULL DEFAULT 'running' CHECK (status IN ('running', 'pending_approval', 'approved', 'rejected', 'completed', 'failed')),
    messages JSONB,
    pending_actions JSONB,
    result_summary TEXT,
    token_usage JSONB,
    cost_cents INT,
    duration_ms INT,
    reviewed_by TEXT,
    reviewed_at BIGINT,
    created_at BIGINT NOT NULL,
    completed_at BIGINT
);
CREATE INDEX IF NOT EXISTS idx_agent_runs_agent_id ON agent_runs(agent_id);
CREATE INDEX IF NOT EXISTS idx_agent_runs_status ON agent_runs(status);

-- Agent memory
CREATE TABLE IF NOT EXISTS agent_memory (
    id TEXT PRIMARY KEY,
    agent_id TEXT NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
    org_id TEXT NOT NULL,
    fact TEXT NOT NULL,
    category TEXT NOT NULL CHECK (category IN ('preference', 'learning', 'context', 'history')),
    confidence REAL NOT NULL DEFAULT 1.0,
    source_run_id TEXT REFERENCES agent_runs(id) ON DELETE SET NULL,
    created_at BIGINT NOT NULL,
    expires_at BIGINT
);
CREATE INDEX IF NOT EXISTS idx_agent_memory_agent_id ON agent_memory(agent_id);

-- Notifications
CREATE TABLE IF NOT EXISTS notifications (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    type TEXT NOT NULL,
    agent_id TEXT REFERENCES agents(id) ON DELETE CASCADE,
    run_id TEXT REFERENCES agent_runs(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    read BOOLEAN NOT NULL DEFAULT false,
    created_at BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_notifications_user_unread ON notifications(user_id) WHERE NOT read;

-- ============================================================
-- Activity (matches cloud migration 010_activity)
-- ============================================================

-- Activity Events
CREATE TABLE IF NOT EXISTS activity_events (
    id TEXT PRIMARY KEY,
    org_id TEXT,
    user_id TEXT NOT NULL,
    event_type TEXT NOT NULL,
    event_subtype TEXT,
    source_type TEXT NOT NULL,
    source_id TEXT,
    source_name TEXT,
    title TEXT NOT NULL,
    summary TEXT,
    reasoning TEXT,
    details JSONB,
    requires_approval BOOLEAN NOT NULL DEFAULT false,
    approval_status TEXT,
    approval_action JSONB,
    approval_batch_id TEXT,
    approved_at BIGINT,
    approved_by TEXT,
    mcp_server TEXT,
    created_at BIGINT NOT NULL,
    read_at BIGINT
);
CREATE INDEX IF NOT EXISTS idx_activity_user_time ON activity_events(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_activity_pending ON activity_events(user_id, approval_status) WHERE approval_status = 'pending';
CREATE INDEX IF NOT EXISTS idx_activity_org ON activity_events(org_id, created_at DESC);

-- Approval Batches
CREATE TABLE IF NOT EXISTS approval_batches (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    org_id TEXT,
    title TEXT NOT NULL,
    reasoning TEXT,
    source_conversation_id TEXT,
    status TEXT NOT NULL DEFAULT 'pending',
    action_count INT NOT NULL DEFAULT 0,
    created_at BIGINT NOT NULL,
    resolved_at BIGINT
);
CREATE INDEX IF NOT EXISTS idx_batches_user_pending ON approval_batches(user_id, status) WHERE status = 'pending';

-- Action Policies
CREATE TABLE IF NOT EXISTS action_policies (
    id TEXT PRIMARY KEY,
    org_id TEXT,
    user_id TEXT,
    mcp_server TEXT NOT NULL,
    tool_name TEXT NOT NULL,
    policy TEXT NOT NULL,
    conditions JSONB,
    created_from TEXT,
    created_at BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_policies_user_org ON action_policies(user_id, org_id);

-- User Devices (push notification tokens)
CREATE TABLE IF NOT EXISTS user_devices (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    platform TEXT NOT NULL,
    push_token TEXT NOT NULL,
    device_name TEXT,
    notification_prefs JSONB NOT NULL DEFAULT '{"approvals":true,"automations":true,"errors":true,"briefings":true}'::jsonb,
    created_at BIGINT NOT NULL,
    last_seen_at BIGINT
);
CREATE INDEX IF NOT EXISTS idx_devices_user ON user_devices(user_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_devices_token ON user_devices(push_token);
