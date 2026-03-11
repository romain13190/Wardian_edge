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
    credentials_encrypted TEXT NOT NULL,
    created_at BIGINT NOT NULL,
    updated_at BIGINT
);
CREATE INDEX IF NOT EXISTS idx_cred_user ON integration_credentials(user_id, provider);

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
