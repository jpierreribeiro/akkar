create table if not exists ml_batch_jobs (
  job_id uuid primary key,
  tenant_id text not null,
  idempotency_key text not null,
  request_digest text not null,
  claim_token text,
  model_name text not null,
  model_alias text not null,
  model_version text,
  model_digest text,
  input_uri text not null,
  output_uri text not null,
  parameters jsonb not null default '{}'::jsonb,
  state text not null check (state in ('queued', 'running', 'succeeded', 'failed')),
  attempts integer not null default 0,
  error text,
  created_at timestamptz not null default now(),
  started_at timestamptz,
  finished_at timestamptz,
  unique (tenant_id, idempotency_key)
);

-- Makes bootstrap safe against a database created by an earlier example revision.
alter table ml_batch_jobs add column if not exists request_digest text;
alter table ml_batch_jobs add column if not exists claim_token text;
update ml_batch_jobs
   set request_digest = 'legacy:' || job_id::text
 where request_digest is null;
alter table ml_batch_jobs alter column request_digest set not null;

create index if not exists ml_batch_jobs_state_created_idx
  on ml_batch_jobs (state, created_at);

-- Apply with API, dispatcher and workers stopped. Re-running is idempotent.
alter table ml_batch_jobs add column if not exists input_version_id text;
alter table ml_batch_jobs add column if not exists input_sha256 text;
alter table ml_batch_jobs add column if not exists model_source text;
alter table ml_batch_jobs add column if not exists lease_until timestamptz;
alter table ml_batch_jobs add column if not exists request_id text;
alter table ml_batch_jobs add column if not exists traceparent text;
alter table ml_batch_jobs alter column output_uri drop not null;
update ml_batch_jobs set state='failed', finished_at=clock_timestamp(),
  error='legacy job lacks immutable inputs; submit with a new idempotency key',
  claim_token=null, lease_until=null
where state in ('queued', 'running') and
  (input_version_id is null or input_sha256 is null or model_source is null);

create table if not exists ml_batch_outbox (
  job_id uuid primary key references ml_batch_jobs(job_id),
  created_at timestamptz not null default clock_timestamp(),
  dispatched_at timestamptz
);
create index if not exists ml_batch_outbox_pending_idx
  on ml_batch_outbox (created_at) where dispatched_at is null;
