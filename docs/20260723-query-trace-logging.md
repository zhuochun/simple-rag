# Query Trace Logging Specification

Status: ready for implementation; implementation is not part of this document.

Decision owner: repository owner.

Last updated: 2026-07-23.

## 1. Change frame

`simple-rag` shall optionally persist a durable trace for each accepted standard
or expanded query. A trace shall contain the effective query plan, complete
ranked retrieval evidence with trace-safe diagnostics, execution timings, and
enough version and index context to support later performance and relevance
evaluation.

Future agents should be able to select comparable recorded queries, replay
them after a retrieval change, measure latency and ranking movement, and inspect
the retrieved text when judging relevance.

The repository owner has accepted these design constraints:

- logging is opt-in through configuration;
- SQLite is the authoritative trace store;
- traces use a dedicated database, separate from every retrieval index;
- the first delivery creates `query_traces` and its indexes only; and
- `query_evaluations` is a future extension and shall not be created now.

Incorrect logging could collect private queries and note contents without
consent, change query behavior, add latency or failures, or record too little
context to compare retrieval runs.

## 2. Evidence and current behavior

The following behavior is confirmed from the current repository:

- `QueryPlanner` builds a `QueryPlan` containing the original query, optional
  semantic rewrite, keyword variants, and executable source lists.
- `Retriever` is the shared standard and expanded retrieval boundary. It builds
  the plan, executes source-list retrieval, fuses chunk candidates, aggregates
  files, and returns the canonical payload.
- The server's `/q` and `/q_plus` routes delegate through `ServerRuntime` to the
  shared retriever.
- `run-query` first attempts the matching server and otherwise builds the shared
  retriever locally. It compacts results only after retrieval, so logging at the
  retriever boundary can preserve one full and consistent result shape.
- The latency benchmark already measures total, embedding, and local retrieval
  time. The quality benchmark already compares overlap, Jaccard similarity,
  rank displacement, and elapsed time across scenarios.
- SQLite is already a required project dependency and the authority for
  retrieval indexes.

No durable per-query history currently exists. The result payload exposes the
rewrite, variants, fallback, count, and ranked data, but does not expose the
full source-list plan and does not persist timings or comparison context.

## 3. Desired behavior

When query logging is disabled, all query entry points, results, errors, and
side effects shall remain unchanged and no trace database shall be opened or
created.

When query logging is enabled:

1. Each valid `q` or `q_plus` invocation that reaches the shared retriever shall
   produce exactly one `query_traces` row when the initialized trace store
   remains writable. It may produce zero rows only under the explicitly defined
   per-query trace-write failure policy and shall never produce more than one.
2. A successful invocation shall record the effective plan, complete ranked
   result data with trace-safe diagnostic fields, stage timings, requested and
   effective modes, selected paths, and comparison context.
3. An invocation that fails after the shared retriever's input validation shall
   record an error trace when the trace database remains writable.
4. An input rejected by the shared retriever's validation shall retain current
   error behavior and shall not create a trace because it is not an accepted
   invocation. Entry-point parsing and path selection that occur before the
   retriever are outside the trace boundary.
5. A server-backed `run-query` invocation shall be recorded by the server only.
   The CLI shall not write a second row.
6. A locally executed `run-query` invocation shall be recorded by its local
   retriever.
7. The canonical query result returned to the caller shall not acquire trace
   fields and shall not change shape.

Only standard and expanded query retrieval is in scope. Similar-note lookup,
duplicate detection, random selection, article extraction, and discussion are
not query traces in this change.

## 4. Configuration contract

Logging shall be disabled when `queryLog` is absent or when a valid
`queryLog.enabled` value is `false`.

The supported configuration is:

```json
{
  "queryLog": {
    "enabled": true,
    "db": "D:\\Data\\simple-rag\\query-traces.sqlite"
  }
}
```

Configuration rules:

- `queryLog` must be a JSON object when present.
- `enabled` must be a JSON boolean when present.
- `db` must be a JSON string when present and is required and non-blank when
  `enabled` is `true`.
- An absolute `db` path is used as written.
- A relative `db` path is resolved against the directory containing the loaded
  configuration file, not the process working directory.
- Parent directories may be created when logging is enabled.
- The configured trace database must not resolve to the same file as any
  configured retrieval-index database. A collision is a configuration error.
- Collision detection first compares normalized absolute paths, using
  case-insensitive comparison on Windows. For existing files it also uses
  filesystem identity, and for a not-yet-created trace database it resolves the
  existing parent directory before comparing the target. Either a path or file-
  identity match is sufficient to reject the configuration.
- Unknown `queryLog` fields are configuration errors. This prevents misspelled
  privacy or storage settings from being silently ignored.
- Enabling logging means the user accepts local persistence of raw query text
  and retrieved note text. Redaction and text-free trace modes are not part of
  the first delivery because they would not support the accepted relevance
  evaluation goal.

If the enabled database cannot be initialized, the server or local retriever
shall fail before accepting queries and report a configuration/setup error.
Explicitly requested logging must not silently degrade to disabled logging.

## 5. Trace ownership and lifecycle

The shared retriever owns query tracing because it is the first
common component that can observe the complete plan and the last common
component before presentation-specific compaction.

The trace boundary begins on entry to `Retriever#retrieve_q` or
`Retriever#retrieve_q_plus`. Wall and monotonic start times are captured before
the shared `RetrievalInputValidator` runs. A validation rejection is not stored;
after validation succeeds, the logical invocation owns one trace identifier
generated before planning. The trace is inserted after the invocation succeeds
or fails. The insert is a single transaction and the stored row is immutable
after insertion.

The trace writer shall be injected. A no-op writer represents disabled logging.
Benchmarks and tests that construct a retriever directly shall not start logging
unless they explicitly inject an enabled writer. This prevents benchmark runs
from contaminating the real-query corpus.

Trace persistence is synchronous in the first delivery. Timing measurements
shall stop before JSON serialization and SQLite persistence, so trace timings
describe retrieval behavior rather than observer overhead. The implementation
must separately measure caller-visible trace projection, serialization, and
insertion overhead. On the repository's representative query benchmark with
`top_n = 10`, uncontended enabled logging must add no more than 25 ms at p95.
Lock waiting is separately bounded by the configured 250 ms SQLite busy timeout.

## 6. SQLite database contract

The trace database is independent from retrieval-index databases. On opening
an enabled trace store, the implementation shall configure:

```sql
PRAGMA journal_mode = WAL;
PRAGMA busy_timeout = 250;
PRAGMA foreign_keys = ON;
PRAGMA synchronous = NORMAL;
```

The first delivery shall create exactly one application table:

```sql
CREATE TABLE IF NOT EXISTS query_traces (
  id                 TEXT PRIMARY KEY,
  schema_version     INTEGER NOT NULL,
  started_at         TEXT NOT NULL,
  completed_at       TEXT NOT NULL,
  status             TEXT NOT NULL CHECK (status IN ('ok', 'error')),
  source             TEXT NOT NULL CHECK (source IN ('server', 'local_cli')),

  query              TEXT NOT NULL,
  query_hash         TEXT NOT NULL,
  requested_mode     TEXT NOT NULL CHECK (requested_mode IN ('q', 'q_plus')),
  effective_mode     TEXT CHECK (effective_mode IN ('q', 'q_plus')),
  paths_json         TEXT NOT NULL,
  top_n              INTEGER NOT NULL CHECK (top_n > 0),

  plan_json          TEXT,
  result_json        TEXT,
  result_count       INTEGER,
  fallback_json      TEXT,
  error_class        TEXT,
  error_summary      TEXT,

  planning_ms        REAL,
  retrieval_ms       REAL,
  fusion_ms          REAL,
  aggregation_ms     REAL,
  total_ms           REAL NOT NULL,

  app_version           TEXT NOT NULL,
  code_revision         TEXT,
  retrieval_code_digest TEXT NOT NULL,
  config_digest         TEXT NOT NULL,
  index_fingerprint     TEXT NOT NULL,
  index_state           TEXT NOT NULL
    CHECK (index_state IN ('stable', 'changed', 'unknown')),

  CHECK (
    (status = 'ok' AND result_json IS NOT NULL AND result_count IS NOT NULL
      AND error_class IS NULL AND error_summary IS NULL)
    OR
    (status = 'error' AND result_json IS NULL AND result_count IS NULL
      AND error_class IS NOT NULL AND error_summary IS NOT NULL)
  )
);
```

JSON values are stored as UTF-8 JSON text produced by the application. The
schema does not require SQLite JSON functions because the application
serializes the values.

The database schema version is also stored in `PRAGMA user_version`:

- a new, empty database is created as version `1` in the same initialization
  transaction that creates the table and indexes;
- an existing version `1` database is validated for the required table,
  columns, constraints, and indexes before queries are accepted;
- a database with application objects but `user_version = 0`, an unsupported
  version, or a version-1 shape that does not match this contract causes setup
  to fail without altering the file; and
- no automatic schema repair, downgrade, or migration is part of this delivery.

The first delivery shall create these indexes:

```sql
CREATE INDEX IF NOT EXISTS idx_query_traces_started_at
  ON query_traces(started_at);

CREATE INDEX IF NOT EXISTS idx_query_traces_query_history
  ON query_traces(query_hash, started_at);

CREATE INDEX IF NOT EXISTS idx_query_traces_comparison_context
  ON query_traces(
    app_version,
    code_revision,
    retrieval_code_digest,
    config_digest,
    index_fingerprint,
    index_state,
    requested_mode
  );

CREATE INDEX IF NOT EXISTS idx_query_traces_status_started_at
  ON query_traces(status, started_at);
```

`query_evaluations` is intentionally absent. A later specification may add it
as an append-only table related to `query_traces.id`, without modifying raw
trace rows.

## 7. Field semantics

### Identity and time

- `id`: randomly generated UUID for the logical invocation.
- `schema_version`: integer `1` for this contract.
- `started_at` and `completed_at`: UTC RFC 3339 timestamps with fractional
  seconds. They describe retrieval execution, excluding trace persistence.
- `source`: `server` when the server owns execution; `local_cli` only when
  `run-query` performs local fallback execution.

### Request

- `query`: normalized query used by the planner, not the caller's untrimmed
  transport value.
- `query_hash`: lowercase hexadecimal SHA-256 of the UTF-8 bytes of `query`.
- `requested_mode`: mode requested by the entry point.
- `effective_mode`: actual mode used for the returned ranking. It is `q` when
  expanded planning falls back to the standard plan and is null if execution
  fails before an effective mode is known.
- `paths_json`: ordered JSON array of selected lookup names. It shall not store
  filesystem directories or database paths.
- `top_n`: requested maximum file count after validation.

### Plan

`plan_json` stores a normalized trace plan rather than a Ruby object dump:

```json
{
  "effective": {
    "original_query": "...",
    "semantic_rewrite": null,
    "keyword_variants": [],
    "lists": [
      {
        "name": "vec:original",
        "backend": "vector",
        "query_type": "original",
        "query": "...",
        "phrase": false,
        "weight": 1.2
      }
    ]
  },
  "attempted_expansion": null
}
```

Every effective list records `name`, `backend`, `query_type`, `query`, `phrase`,
and `weight`, even when a value is false or empty. This makes plan comparison
independent of Ruby defaulting behavior.

### Retrieval diagnostics (October 2026 extension)

New executor traces add an optional `retrieval` object to `plan_json` without
changing the version-1 SQLite schema. Older records and custom executors may
omit it. It contains `embeddings` and `searches` arrays sorted by source-list
name and lookup name. No diagnostics are collected when tracing is disabled.

Embedding samples contain `source_list`, `elapsed_ms`, `cache_status`
(`hit`, `miss`, `wait`, or `uncached`), `stage`, and `status`. `wait` means
another request owns the same in-flight embedding load; it does not mean a
provider queue wait. `uncached` means the callable did not report cache state.

Search samples contain `source_list`, `backend`, `lookup`, `elapsed_ms`,
`stage`, and `status`. Vector jobs additionally report `embedding_wait_ms`.
Connection checkout reports `pool_wait_ms` (including mutex acquisition),
`open_ms`, and `connection` (`opened` or `reused`). `search_ms` measures index
search and candidate projection after checkout, and `candidate_count` counts
retained candidates before cross-lookup merging. Durations are monotonic
milliseconds. `elapsed_ms` includes any embedding wait, checkout, and search;
concurrent sample durations must not be added to infer wall-clock latency.
An unfinished substage is absent. Failed samples retain completed timing data,
the failure `stage`, and `error_class`, but never raw exception messages.

Lexical jobs now run while a single per-request worker prepares embeddings in
plan order. At most eight SQLite workers run per request. Every worker is
joined before the query returns, embedding errors retain precedence over
search errors, and final source lists retain plan order. Multi-term queries
include non-phrase BM25 even below six tokens; single-token queries keep just
the equivalent phrase list to avoid duplicate lexical voting.

For a successful expanded plan, `attempted_expansion` is null because the
effective plan already contains the expansion. When expanded planning fails
and falls back, `effective` contains the standard plan and
`attempted_expansion` contains any semantic rewrite and keyword variants
produced before failure, plus the stable fallback reason, error class, and
trace-safe error summary.

If planning fails without an effective plan, `plan_json` may contain
`effective: null` and the available attempted-expansion data. It is null only
when failure occurs before any plan information exists.

### Result and failure

- `result_json`: a trace projection of the complete canonical hash returned by
  `Retriever`, serialized before CLI compaction or other presentation changes.
  It preserves the full ranked files, scores, matched chunk text, retrieval
  evidence, modes, rewrite, variants, count, and stable fallback reason. Any
  diagnostic message within the caller payload is replaced by its trace-safe
  representation; tracing does not modify the payload returned to the caller.
- `result_count`: the canonical result count, repeated as an integer for indexed
  or aggregate analysis without parsing JSON.
- `fallback_json`: null without fallback; otherwise the stable fallback reason,
  failure stage, exception class, and trace-safe error summary.
- `error_class` and `error_summary`: the public Ruby exception class name and a
  trace-safe summary for a failed invocation. Backtraces and raw exception
  messages are not stored.

A trace-safe error summary is generated from the failure stage and an allowlist
of static application messages that cannot interpolate user input,
configuration, filesystem paths, provider URLs, or provider responses. All
other failures use a generic summary such as `query planning failed` or
`retrieval failed`. Summaries are limited to 256 Unicode characters. In
particular, raw provider response bodies and provider URLs are never copied
from current exception messages into `plan_json`, `result_json`,
`fallback_json`, or `error_summary`.

Provider credentials, request headers, environment variables, raw embeddings,
and stack traces shall never be stored.

### Timing and comparison context

All durations use a monotonic clock and are stored in milliseconds:

- `planning_ms`: standard plan construction, or the complete expanded-planning
  attempt plus fallback-plan construction.
- `retrieval_ms`: source-list execution, including embedding and SQLite search.
- `fusion_ms`: chunk-candidate fusion.
- `aggregation_ms`: file aggregation and final ranking.
- `total_ms`: elapsed monotonic time from shared retriever entry through shared
  validation, planning, retrieval, fusion, and aggregation, or until a failure
  after validation. Entry-point argument parsing, path resolution, server HTTP
  serialization, CLI formatting, and trace persistence are excluded.

`total_ms` need not equal the rounded sum of stage fields. A stage field is null
when failure occurs before that stage starts or completes.

Comparison context is captured once per invocation:

- `app_version`: the `simple-rag` package version.
- `code_revision`: source-control revision when it can be established without a
  per-query subprocess; otherwise null.
- `retrieval_code_digest`: SHA-256 of the bytes of the retrieval implementation
  files selected by the implementation. The file set must include planning,
  execution, fusion, aggregation, storage search, configuration interpretation,
  and the trace schema version. When retrieval responsibilities move to new
  files, include their bytes too; a changed file set changes this digest and
  starts a new comparison cohort without changing the SQLite schema version.
  It is computed once at process startup so uncommitted or unversioned
  retrieval changes remain distinguishable without per-query subprocesses.
- `config_digest`: SHA-256 of the loaded configuration file bytes.
- `index_fingerprint`: SHA-256 captured immediately after shared validation and
  before planning. It is derived from the selected lookup names, table names,
  and normalized presence, size, and modification time of each selected SQLite
  database and its WAL file. Normal WAL absence has an explicit `absent` marker;
  a missing database or failed metadata read has a deterministic marker that
  contains only the failure class, never a path or raw message. It is a change
  discriminator, not proof that corpus contents are identical.
- `index_state`: the selected index metadata is captured again after retrieval
  timing stops. `stable` means the before and after fingerprints match,
  `changed` means they differ, and `unknown` means either capture included a
  metadata-read failure. Future comparisons should normally exclude `changed`
  and `unknown` traces. Context-capture failure must not fail retrieval.

## 8. Transactions, concurrency, and failure behavior

Each trace is inserted with one prepared statement inside one transaction. A
process shall share one trace-store instance and serialize writes through that
instance. WAL mode and `busy_timeout` provide bounded coordination with another
process using the same configured trace database.

Trace insertion shall never change a successful retrieval into a failed query.
If trace projection, serialization, or insertion fails after retrieval:

- return the original canonical result unchanged;
- emit one concise warning to stderr containing the trace id and error class;
- do not retry within the query request; and
- do not write a partial or replacement row.

If insertion fails while recording a retrieval error, preserve and raise the
original retrieval error; the trace-write error is secondary and is reported
only through the warning.

Closing the runtime shall close the trace-store connection after in-flight
synchronous writes finish. No background queue, dropped-record policy, retry
queue, or recovery journal is part of the first delivery.

## 9. Privacy, retention, and recovery

The trace database contains raw user queries and copied note text. It inherits
the sensitivity of the indexed knowledge bases and must remain local unless the
user deliberately shares it. Documentation shall warn users not to commit or
upload the database casually.

The trace database path is user data and should normally live outside the
repository. If placed under this repository's `tmp` directory it is ignored by
Git, but that location is not guaranteed durable.

The first delivery performs no automatic retention, rotation, deletion,
redaction, encryption, or export. The user owns backup and removal. Deleting the
separate trace database shall not affect retrieval indexes or query behavior;
the next enabled startup may recreate an empty trace store.

SQLite schema or open failures do not trigger destructive repair. The
implementation shall report the problem and leave the file intact for manual
inspection or recovery.

## 10. Evaluation use

Traces record what retrieval returned; judging relevance requires a separate
review. Future agents may use traces to choose representative real queries and
compare only records or replay runs with compatible requests and comparison
context.

The trace supports these later measures:

- median and p95 `total_ms` by mode and comparison context;
- zero-result, error, and expanded-query fallback rates;
- top-k overlap, Jaccard similarity, additions, removals, and rank displacement;
- qualitative or rubric-based relevance review using the query and matched
  chunk text; and
- query-specific regression review through `query_hash` history.

Agents must not compare raw retrieval scores as though they were calibrated
across different plans or code versions. They must distinguish retrieval
quality from latency and must identify index or configuration changes when
interpreting a result difference.

A later `query_evaluations` change may store evaluator identity, rubric version,
scores, and notes keyed to `query_traces.id`. Those judgments shall be additive
and shall never overwrite the raw trace.

## 11. Representative behavior examples

### Standard successful query

With logging enabled, a valid `q` request returns the same ranked response as
today and inserts one `ok` row containing the standard plan, complete ranked
result evidence with trace-safe diagnostics, all completed stage timings, and
`effective_mode = 'q'`.

### Expanded successful query

A valid `q_plus` request whose rewrite and variants are usable inserts one `ok`
row. The effective plan contains both original and expanded source lists, and
both requested and effective modes are `q_plus`.

### Expanded query fallback

If expanded planning produces no usable expanded plan, the caller receives the
existing standard-query fallback response. One `ok` trace records
`requested_mode = 'q_plus'`, `effective_mode = 'q'`, the effective standard
plan, the partial expansion attempt, and the fallback metadata.

### Retrieval failure

If embedding or SQLite retrieval fails after validation, the original error
behavior is preserved. When writable, one `error` trace records available plan
data, completed timings, and error class plus trace-safe summary without a
result payload.

### Logging disabled

With `queryLog` absent or disabled, neither server startup nor local CLI query
execution creates or opens a trace database. Query behavior is byte-for-byte
compatible at the JSON response boundary.

### Trace-store failure after startup

If the trace database becomes locked beyond the busy timeout or unwritable, a
successful query still returns successfully. The process warns once for that
failed write and does not insert a partial row.

## 12. Affected surfaces

The change affects these responsibilities without changing their public query
contracts:

- configuration loading and relative-path resolution;
- server and local-CLI construction of the shared retriever;
- query planning and retrieval-stage timing;
- retriever lifecycle and close behavior;
- a new dedicated SQLite trace-store boundary;
- documentation of the opt-in privacy and storage behavior; and
- tests for canonical plan serialization, result preservation, fallback,
  failures, concurrency, and configuration validation.

The HTTP request and response shapes, CLI output formats, query selection
rules, retrieval ranking, index schemas, embedding dimensions, and existing
benchmark report schemas must remain unchanged.

## 13. Acceptance claims

- `CHG-trace-opt-in — Disabled means no trace effects`: Without explicit
  `queryLog.enabled: true`, no trace file is opened or created and observable
  query behavior is unchanged.
- `CHG-trace-once — One accepted invocation produces exactly one trace when
  writable`: Server, server-backed CLI, and local CLI execution do not duplicate
  a logical query trace; zero rows are allowed only after the specified
  trace-write failure.
- `CHG-trace-plan-result — Successful traces preserve evaluation evidence`: An
  `ok` trace contains the effective executable plan and complete ranked result
  evidence before presentation compaction, with only diagnostic content
  replaced by its trace-safe projection.
- `CHG-trace-fallback — Expanded fallback remains explainable`: A fallback trace
  distinguishes requested and effective modes and preserves both the effective
  standard plan and available expansion-attempt evidence.
- `CHG-trace-context — Comparisons expose relevant drift`: Each trace identifies
  application, configuration, and selected-index state sufficiently to flag
  likely non-comparable runs.
- `CHG-trace-timing — Timings describe retrieval stages`: Trace measurements use
  a monotonic clock, expose the defined stages, and exclude trace persistence.
- `CHG-trace-isolation — Trace persistence cannot break retrieval`: A runtime
  write failure never replaces a successful result or masks the original
  retrieval error.
- `CHG-trace-private — Sensitive content is explicit`: Logging requires opt-in,
  documentation identifies stored query and note text, and prohibited secret
  material is absent.
- `CHG-trace-separate — Evaluation data cannot contaminate retrieval indexes`:
  The configured trace database is distinct from every retrieval-index file.
- `CHG-trace-raw-immutable — Raw evidence is append-only`: A completed trace row
  is never edited by the logging feature or a future evaluation workflow.

## 14. Delivery boundary and readiness

The first delivery includes configuration validation, dedicated trace
database initialization, successful and failed query tracing through the shared
retriever, canonical serialization, timing capture, lifecycle handling,
documentation, and focused automated verification.

That delivery excludes:

- creating `query_evaluations`;
- building an evaluation UI, agent grader, replay runner, or JSONL exporter;
- changing benchmark report formats;
- adding logging for non-query operations;
- automatic retention, rotation, cleanup, redaction, or encryption;
- asynchronous persistence, retry queues, or cross-machine collection; and
- changing retrieval algorithms, scores, ranking, output payloads, or index
  schemas.

Readiness: **ready**. The repository owner has selected the product
and storage decisions. An implementer may rely on the configuration, trace
scope, schema, field semantics, failure policy, privacy boundary, and acceptance
claims in this document. The implementer must not infer permission to add
evaluation tables, retention behavior, broader telemetry, or retrieval changes.
