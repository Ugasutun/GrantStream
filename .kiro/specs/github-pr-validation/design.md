# GitHub PR Validation for GrantStream Milestone Evidence — Design Document

## Overview

This design implements GitHub Pull Request validation as a first-class evidence type in the GrantStream CLI tool. The feature extends the existing `submit-milestone` command to accept GitHub PR URLs alongside existing IPFS URIs, validates PRs against specific criteria (existence, merged status, repository ownership), and persists PR metadata in the indexer database for querying and auditing.

### Key Objectives

1. **Seamless URL Detection**: Automatically identify GitHub PR URLs vs. IPFS URIs without user intervention
2. **Robust Validation**: Query GitHub REST API to verify PR existence, merge status, and repository
3. **Rich Metadata**: Extract and store PR details for verifier review without additional API calls
4. **Graceful Error Handling**: Clear error messages for rate limiting, network failures, and invalid submissions
5. **Flexible Configuration**: Support optional repository constraints and GitHub API authentication
6. **Non-Breaking Integration**: Preserve existing IPFS workflow; PR validation is additive

### Architectural Philosophy

The design follows these principles:

- **Separation of Concerns**: URL parsing, API validation, metadata extraction, and database persistence are separate, testable layers
- **Pure Functions Where Possible**: Core validation logic (URL parsing, metadata extraction) uses pure functions for property-based testing
- **Graceful Degradation**: System works with or without GitHub API token (with rate limit trade-off)
- **Fail-Fast Validation**: Validate PR before blockchain submission to prevent wasted gas fees
- **Audit Trail**: Store all submissions (including duplicates/resubmissions) with timestamps for forensic investigation

---

## Architecture

### High-Level System Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                     submit-milestone command                    │
│                   (CLI entry point)                             │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         ▼
        ┌────────────────────────────────┐
        │    Evidence Type Detector      │
        │  (URL Parser & Classifier)     │
        │  - Identify GitHub PR vs IPFS  │
        │  - Extract PR components       │
        └────────────┬───────────────────┘
                     │
         ┌───────────┴──────────────┐
         ▼                          ▼
   [GitHub PR]              [IPFS URI]
         │                          │
         │                          ▼
         │                   [Store IPFS + Submit]
         │
         ▼
   ┌─────────────────────────────────┐
   │   GitHub PR Validator           │
   │  (Multi-step validation)        │
   │  1. Query GitHub REST API       │
   │  2. Check merged status         │
   │  3. Verify repository owner     │
   │  4. Extract metadata            │
   └────────────┬────────────────────┘
                │
                ├─ Success ──────────────────┐
                │                            │
                │                            ▼
                │                 ┌──────────────────────┐
                │                 │  Metadata Storage    │
                │                 │  (Indexer DB)        │
                │                 │  - Persist PR meta   │
                │                 │  - Link to milestone │
                │                 └──────────────────────┘
                │                            │
                │                            ▼
                │                 ┌──────────────────────┐
                │                 │ Blockchain Submit    │
                │                 │ (submit-milestone)   │
                │                 └──────────────────────┘
                │
                └─ Failure ─────────────────┐
                                            ▼
                                 ┌──────────────────────┐
                                 │  Error Display       │
                                 │  (User feedback)     │
                                 │  - Don't submit TX   │
                                 │  - Clear error msg   │
                                 └──────────────────────┘
```

### Component Interaction Diagram

```
┌──────────────────────────────────────────────────────────────────────┐
│                                                                      │
│  CLI Layer (submit_milestone command)                               │
│  ┌────────────────────────────────────────────────────────────────┐│
│  │ Input: evidence_uri, grant_id, milestone_id                  ││
│  │ Output: Success (submit TX) or Error (display message)       ││
│  └─────────────────────┬──────────────────────────────────────────┘│
│                        │                                             │
├────────────────────────┼─────────────────────────────────────────────┤
│                        ▼                                              │
│  Validation Layer                                                     │
│  ┌────────────────────────────────────────────────────────────────┐│
│  │ URLParser → TypeDetector → PRValidator → MetadataExtractor   ││
│  │                                                                ││
│  │ Each component is independently testable                     ││
│  │ Error propagation: validation stops on first error           ││
│  └─────────────────────┬──────────────────────────────────────────┘│
│                        │                                             │
├────────────────────────┼─────────────────────────────────────────────┤
│                        ▼                                              │
│  GitHub API Layer (via reqwest client)                               │
│  ┌────────────────────────────────────────────────────────────────┐│
│  │ Request: GET /repos/{owner}/{repo}/pulls/{number}            ││
│  │ Response: PR object with merged, title, mergedAt, user, etc.  ││
│  │                                                                ││
│  │ Handles:                                                       ││
│  │ - Authentication (Bearer token if configured)                ││
│  │ - Rate limiting (429 with X-RateLimit-Reset header)          ││
│  │ - Network errors (timeout, connection refused)               ││
│  │ - 404 (PR not found)                                          ││
│  │ - 403 (permission denied)                                     ││
│  └─────────────────────┬──────────────────────────────────────────┘│
│                        │                                             │
├────────────────────────┼─────────────────────────────────────────────┤
│                        ▼                                              │
│  Persistence Layer (Indexer DB)                                      │
│  ┌────────────────────────────────────────────────────────────────┐│
│  │ Store PR metadata linked to milestone                        ││
│  │ Schema: PRMetadata {                                           ││
│  │   pr_number, pr_title, pr_url,                               ││
│  │   merged_at, author_username,                                ││
│  │   repo_owner, repo_name,                                     ││
│  │   grant_id, milestone_id,                                    ││
│  │   submission_timestamp, validation_passed                    ││
│  │ }                                                             ││
│  └────────────────────────────────────────────────────────────────┘│
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Components and Interfaces

### 1. URL Parser (`github_pr_validation::url_parser`)

**Responsibility**: Identify and extract PR identifiers from GitHub URLs

**Data Structures**:

```rust
/// Parsed GitHub PR identifier
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitHubPRIdentifier {
    pub owner: String,      // GitHub organization or username
    pub repo: String,       // Repository name
    pub number: u64,        // PR number (issue number, not commit SHA)
}

/// Evidence type classification
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EvidenceType {
    GitHubPR(GitHubPRIdentifier),
    IpfsUri(String),
}
```

**Core Functions**:

```rust
/// Parse a raw URL string into an EvidenceType
/// Accepts:
/// - https://github.com/{owner}/{repo}/pull/{number}
/// - https://github.com/{owner}/{repo}/pull/{number}#fragment
/// - https://github.com/{owner}/{repo}/pull/{number}?param=value
/// - ipfs://Qm... or similar IPFS URIs
pub fn parse_evidence_url(url: &str) -> Result<EvidenceType, ParseError>;

/// Extract PR identifier from a GitHub PR URL
/// Returns: GitHubPRIdentifier or error if URL format is invalid
fn extract_github_pr_parts(url: &str) -> Result<GitHubPRIdentifier, ParseError>;

/// Classify a URL as GitHub PR or IPFS URI
fn classify_url(url: &str) -> EvidenceType;
```

**Error Handling**:

```rust
#[derive(Debug, thiserror::Error)]
pub enum ParseError {
    #[error("Invalid GitHub PR URL: {0}. Expected format: https://github.com/{{owner}}/{{repo}}/pull/{{number}}")]
    InvalidGitHubPRFormat(String),

    #[error("Invalid PR number: {0}")]
    InvalidPRNumber(String),

    #[error("URL is neither a valid GitHub PR nor IPFS URI: {0}")]
    UnrecognizedEvidenceType(String),
}
```

**Algorithm** (Pseudocode):

```
Input: url (string)

If url contains "github.com":
    Remove fragment (#...) and query params (?...)
    Split by "/" and extract [owner, repo, number]
    
    If number is not a valid u64:
        Return InvalidPRNumber error
    
    Validate owner and repo are non-empty:
        If invalid:
            Return InvalidGitHubPRFormat error
    
    Return GitHubPR(owner, repo, number)

Else if url matches IPFS pattern (ipfs://, Qm..., etc):
    Return IpfsUri(url)

Else:
    Return UnrecognizedEvidenceType error
```

**Design Rationale**:

- **Fragment/Parameter Stripping**: GitHub PR URLs may be shared with fragments (`#discussion-123`) or parameters. Stripping these allows flexible URL input without breaking validation.
- **Pure Function**: Parsing is deterministic and side-effect-free, enabling property-based testing.
- **Separation from API Calls**: URL parsing succeeds/fails locally before any HTTP requests.

---

### 2. GitHub API Client (`github_pr_validation::github_client`)

**Responsibility**: Communicate with GitHub REST API, handle authentication and rate limiting

**Data Structures**:

```rust
/// Configuration for GitHub API client
#[derive(Debug, Clone)]
pub struct GitHubConfig {
    /// Optional API token for authentication (from GITHUB_TOKEN env var)
    pub api_token: Option<String>,
    
    /// Optional repository requirement (from grant config or --github-repo)
    pub required_repo: Option<(String, String)>, // (owner, repo)
}

/// GitHub PR data from REST API response
#[derive(Debug, Clone, serde::Deserialize)]
pub struct GitHubPRResponse {
    pub number: u64,
    pub title: String,
    pub merged: bool,
    pub merged_at: Option<String>, // ISO 8601 datetime
    pub user: GitHubUser,           // PR author
    #[serde(rename = "head")]
    pub head_ref: GitHubRef,        // Source branch
}

#[derive(Debug, Clone, serde::Deserialize)]
pub struct GitHubUser {
    pub login: String,              // GitHub username
}

#[derive(Debug, Clone, serde::Deserialize)]
pub struct GitHubRef {
    pub repo: Option<GitHubRepository>,
}

#[derive(Debug, Clone, serde::Deserialize)]
pub struct GitHubRepository {
    pub owner: GitHubOwner,
    pub name: String,
}

#[derive(Debug, Clone, serde::Deserialize)]
pub struct GitHubOwner {
    pub login: String,
}

/// Extracted and normalized PR metadata
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct PRMetadata {
    pub pr_number: u64,
    pub pr_title: String,
    pub pr_url: String,
    pub merged_at: Option<String>, // ISO 8601, null if unmerged
    pub author_username: String,
    pub repo_owner: String,
    pub repo_name: String,
    pub submission_timestamp: String, // ISO 8601
}
```

**Core Functions**:

```rust
/// Validate a GitHub PR and extract metadata
/// Performs all validation steps: existence, merged status, repo ownership
pub async fn validate_and_extract_pr(
    identifier: &GitHubPRIdentifier,
    config: &GitHubConfig,
    http_client: &reqwest::Client,
) -> Result<PRMetadata, GitHubValidationError>;

/// Query GitHub REST API for PR details
async fn fetch_pr_from_github(
    identifier: &GitHubPRIdentifier,
    config: &GitHubConfig,
    http_client: &reqwest::Client,
) -> Result<GitHubPRResponse, GitHubAPIError>;

/// Validate PR is merged
fn validate_merged_status(response: &GitHubPRResponse) -> Result<(), MergeStatusError>;

/// Validate PR belongs to expected repository (if configured)
fn validate_repository_ownership(
    response: &GitHubPRResponse,
    required_repo: &Option<(String, String)>,
) -> Result<(), RepositoryOwnershipError>;

/// Extract PR metadata from GitHub API response
fn extract_metadata(
    identifier: &GitHubPRIdentifier,
    response: &GitHubPRResponse,
) -> PRMetadata;

/// Build GitHub API request with authentication header
fn build_github_request(
    identifier: &GitHubPRIdentifier,
    config: &GitHubConfig,
) -> reqwest::RequestBuilder;
```

**Error Handling**:

```rust
#[derive(Debug, thiserror::Error)]
pub enum GitHubValidationError {
    #[error("PR not found: {owner}/{repo}#{number}")]
    PRNotFound { owner: String, repo: String, number: u64 },

    #[error("PR must be merged before being accepted as evidence: {url}")]
    NotMerged { url: String },

    #[error("PR is from {actual_repo}, but expected {expected_repo}")]
    WrongRepository { actual_repo: String, expected_repo: String },

    #[error("GitHub API error: {0}")]
    APIError(#[from] GitHubAPIError),

    #[error("Network error: {0}")]
    NetworkError(String),

    #[error("GitHub API request timed out")]
    Timeout,
}

#[derive(Debug, thiserror::Error)]
pub enum GitHubAPIError {
    #[error("Rate limited. Reset at {reset_time}")]
    RateLimited { reset_time: String },

    #[error("HTTP {status}: {message}")]
    HTTPError { status: u16, message: String },

    #[error("Failed to parse GitHub API response: {0}")]
    InvalidResponse(String),
}
```

**Algorithm** (Pseudocode):

```
Input: PR identifier, config, http_client

1. Build HTTP request with GitHub API endpoint
   If config has API token:
       Add Authorization: Bearer {token} header

2. Execute GET request (with 30s timeout)
   If timeout:
       Return Timeout error
   If network error:
       Return NetworkError
   If 429 (rate limited):
       Extract X-RateLimit-Reset header
       Return RateLimited error with reset time
   If 403 (permission denied):
       Return HTTPError(403)
   If 404 (not found):
       Return PRNotFound error
   If non-2xx status:
       Return HTTPError with status and body

3. Parse response JSON into GitHubPRResponse
   If parsing fails:
       Return InvalidResponse error

4. Validate merged status:
   If response.merged == false AND draft-allow not configured:
       Return NotMerged error

5. Validate repository ownership:
   If config.required_repo is set:
       Extract actual repo from response
       If actual_repo != required_repo:
           Return WrongRepository error

6. Extract metadata:
   Return PRMetadata object with all fields

Output: PRMetadata or error
```

**Design Rationale**:

- **Composition Over Inheritance**: Each validation step is a separate, independently testable function
- **Mock-Friendly**: Pure functions where possible; HTTP client is injected for easy mocking
- **Timeout Configuration**: All requests have a 30-second timeout to prevent hanging
- **Rate Limit Awareness**: Headers are parsed to provide actionable reset times

---

### 3. Evidence Type Detector (`github_pr_validation::evidence_detector`)

**Responsibility**: Route evidence URIs to appropriate validation pipeline

**Core Functions**:

```rust
/// Main entry point: classify evidence and trigger validation
pub async fn process_evidence(
    evidence_uri: &str,
    grant_id: u64,
    milestone_id: u64,
    config: &Config,
    indexer_db: &IndexerDB,
    http_client: &reqwest::Client,
) -> Result<EvidenceValidationResult, EvidenceValidationError>;

/// Result of evidence processing
#[derive(Debug)]
pub struct EvidenceValidationResult {
    pub evidence_type: EvidenceType,
    pub pr_metadata: Option<PRMetadata>, // Only for GitHub PRs
    pub validation_passed: bool,
}
```

**Algorithm**:

```
Input: evidence_uri, grant_id, milestone_id, config, indexer_db

1. Parse evidence_uri using URL parser
   If parsing fails:
       Return error

2. Classify as GitHub PR or IPFS URI
   
   If GitHub PR:
       a. Check for duplicates in indexer_db:
          Query for existing PR submission for this milestone
          If same PR URL already submitted:
              Return duplicate error
       
       b. Validate PR:
          Call github_client::validate_and_extract_pr()
          If validation fails:
              Return error
       
       c. Store metadata:
          Call indexer_db.store_pr_metadata(metadata)
          If storage fails:
              Log error, but don't abort
              Return message indicating validation passed but storage failed
       
       d. Return success with metadata
   
   Else IPFS URI:
       a. Store URI reference in indexer_db (optional)
       b. Return success

Output: EvidenceValidationResult or error
```

---

### 4. Indexer Database Integration (`github_pr_validation::indexer_db`)

**Responsibility**: Persist PR metadata and link to milestones

**Data Model**:

```rust
/// PR metadata record in indexer database
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct PRMetadataRecord {
    pub id: String,                     // Unique record ID
    pub grant_id: u64,
    pub milestone_id: u64,
    pub pr_url: String,
    pub pr_number: u64,
    pub pr_title: String,
    pub merged_at: Option<String>,      // ISO 8601, null if unmerged
    pub author_username: String,
    pub repo_owner: String,
    pub repo_name: String,
    pub submission_timestamp: String,   // ISO 8601
    pub validation_passed: bool,
}
```

**Core Functions**:

```rust
/// Store PR metadata in indexer database
pub async fn store_pr_metadata(
    db: &IndexerDB,
    grant_id: u64,
    milestone_id: u64,
    metadata: &PRMetadata,
) -> Result<PRMetadataRecord, DBError>;

/// Retrieve all PR metadata for a milestone
pub async fn get_milestone_pr_evidence(
    db: &IndexerDB,
    grant_id: u64,
    milestone_id: u64,
) -> Result<Vec<PRMetadataRecord>, DBError>;

/// Check if a specific PR has already been submitted for this milestone
pub async fn check_duplicate_pr(
    db: &IndexerDB,
    grant_id: u64,
    milestone_id: u64,
    pr_url: &str,
) -> Result<bool, DBError>;
```

**Schema** (Example - assumes external DB):

```sql
CREATE TABLE pr_evidence (
    id TEXT PRIMARY KEY,
    grant_id BIGINT NOT NULL,
    milestone_id BIGINT NOT NULL,
    pr_url TEXT NOT NULL,
    pr_number BIGINT NOT NULL,
    pr_title TEXT NOT NULL,
    merged_at TEXT,           -- ISO 8601, nullable
    author_username TEXT NOT NULL,
    repo_owner TEXT NOT NULL,
    repo_name TEXT NOT NULL,
    submission_timestamp TEXT NOT NULL,  -- ISO 8601
    validation_passed BOOLEAN NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    UNIQUE(grant_id, milestone_id, pr_url)  -- Prevent exact duplicates
);

-- Allow resubmissions with different PRs (no global unique on PR)
-- Store timestamp to track when each submission occurred
```

**Design Rationale**:

- **Non-Destructive Resubmissions**: Allows multiple PR submissions for same milestone (with different PRs) for audit trail
- **Prevents Exact Duplicates**: Same PR URL cannot be submitted twice for same milestone
- **Flexible Schema**: Stores null merge_at for unmerged/draft PRs
- **Timestamp Tracking**: Enables forensic analysis of submission history

---

### 5. Configuration Integration (`github_pr_validation::config`)

**Responsibility**: Load and manage GitHub-specific configuration

**Extension to existing Config**:

```rust
impl Config {
    /// Load GitHub-specific configuration
    pub fn load_github_config() -> Result<GitHubConfig> {
        let api_token = std::env::var("GITHUB_TOKEN").ok();
        
        // Validate token if provided (optional: call GitHub API to verify)
        if let Some(ref token) = api_token {
            if token.is_empty() {
                anyhow::bail!("GITHUB_TOKEN is set but empty");
            }
            // Optional: validate token by making a test request
        }
        
        Ok(GitHubConfig {
            api_token,
            required_repo: None, // Set by grant config if needed
        })
    }
}
```

**Environment Variables**:

```
# GitHub API authentication (optional, for increased rate limits)
GITHUB_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxx

# Optional: default repository requirement for all milestones
# (can be overridden per-grant with --github-repo flag)
GITHUB_REQUIRED_REPO=owner/repo
```

**Design Rationale**:

- **Optional Token**: System works without token (60 req/hr limit)
- **Standard Environment Variable**: Uses GitHub's standard `GITHUB_TOKEN` convention
- **No Validation On Startup**: Token is validated lazily (on first API call) to allow offline CLI usage

---

## Data Models

### GitHub PR Data Flow

```
GitHub REST API Response
    │
    ├─ /repos/{owner}/{repo}/pulls/{number}
    │   {
    │     "number": 42,
    │     "title": "Add feature X",
    │     "merged": true,
    │     "merged_at": "2024-01-15T14:30:00Z",
    │     "user": {"login": "alice"},
    │     "head": {
    │       "repo": {
    │         "owner": {"login": "org"},
    │         "name": "repo-name"
    │       }
    │     }
    │   }
    │
    ▼
GitHubPRResponse (serde deserialized)
    │
    ├─ Validation checks:
    │  ├─ merged == true?
    │  ├─ repo matches expected?
    │
    ▼
PRMetadata (extracted & normalized)
    │
    ├─ pr_number: 42
    ├─ pr_title: "Add feature X"
    ├─ pr_url: "https://github.com/org/repo-name/pull/42"
    ├─ merged_at: "2024-01-15T14:30:00Z"
    ├─ author_username: "alice"
    ├─ repo_owner: "org"
    ├─ repo_name: "repo-name"
    ├─ submission_timestamp: "2024-01-15T14:35:00Z" (now)
    │
    ▼
Indexer Database (persisted)
    │
    └─ Linked to: grant_id, milestone_id
       Enables queries: "Show all PRs for milestone X"
```

---

## Error Handling

### Error Hierarchy

```
┌─ EvidenceValidationError
│   ├─ ParseError
│   │   ├─ InvalidGitHubPRFormat
│   │   ├─ InvalidPRNumber
│   │   └─ UnrecognizedEvidenceType
│   │
│   ├─ GitHubValidationError
│   │   ├─ PRNotFound
│   │   ├─ NotMerged
│   │   ├─ WrongRepository
│   │   ├─ APIError (contains)
│   │   │   ├─ RateLimited
│   │   │   ├─ HTTPError
│   │   │   └─ InvalidResponse
│   │   ├─ NetworkError
│   │   └─ Timeout
│   │
│   ├─ DuplicateError
│   └─ DBStorageError
│
└─ User-Facing Error Messages (formatted for display)
```

### User-Facing Error Messages

```
# URL Parse Error
"Error: Invalid GitHub PR URL: https://example.com/pr/42"
"         Expected format: https://github.com/{owner}/{repo}/pull/{number}"

# PR Not Found
"Error: PR not found: owner/repo#42"
"       Check the PR number and repository are correct"

# Not Merged
"Error: PR must be merged before being accepted as evidence: https://github.com/owner/repo/pull/42"
"       Merge the PR and try again"

# Wrong Repository
"Error: PR is from owner/repo2, but expected owner/repo"
"       Submit a PR from owner/repo for this grant"

# Rate Limited
"Error: GitHub API rate limited"
"       Reset at 2024-12-20 15:30:00 UTC"
"       Please retry after this time"

# Network Error
"Error: Failed to reach GitHub API: connection refused"
"       Check your internet connection and retry"

# Timeout
"Error: GitHub API request timed out (30s)"
"       GitHub may be experiencing issues. Please retry."

# Duplicate
"Error: This PR has already been submitted as evidence for this milestone"
"       Submit a different PR or contact support"

# DB Storage Error (but validation passed)
"Warning: PR validation passed, but failed to store metadata in indexer"
"         Validation result: Passed"
"         You may retry the submission"
```

### Error Propagation Strategy

1. **Parse → Validate → Store** (fail-fast)
   - If parsing fails: return immediately, don't call API
   - If validation fails: return immediately, don't store
   - If storage fails: return warning but consider validation successful

2. **User Context**
   - Always display the original user input for reference
   - Suggest corrective action where possible
   - Include technical details in debug logs

---

## Testing Strategy

### Property-Based Testing (Using fast-check or Quickcheck-like library for Rust)

This feature is highly suitable for property-based testing because:

1. **URL Parsing**: Generates many URL formats (canonical, with fragments, with parameters) and verifies parsing behavior
2. **Metadata Extraction**: Generates random GitHub PR responses and verifies metadata is extracted correctly
3. **Invariants**: PR metadata extracted for the same PR should always be identical
4. **Round-Trip**: Serialize → deserialize metadata should preserve values
5. **Error Cases**: Invalid URL formats should always fail parsing; valid URLs should always parse

#### Property 1: URL Parsing Canonical Format

*For any* valid GitHub PR URL in the form `https://github.com/{owner}/{repo}/pull/{number}`, parsing SHALL extract the owner, repo, and number correctly and classify it as a GitHub PR.

**Validates: Requirements 1.2, 14.1**

#### Property 2: URL Parsing with Fragments

*For any* valid GitHub PR URL with a fragment (e.g., `#discussion-123`), parsing SHALL extract the PR identifier correctly by discarding the fragment.

**Validates: Requirements 14.3**

#### Property 3: URL Parsing with Query Parameters

*For any* valid GitHub PR URL with query parameters (e.g., `?page=1`), parsing SHALL extract the PR identifier correctly by discarding the parameters.

**Validates: Requirements 14.4**

#### Property 4: URL Classification

*For any* string input, the evidence type classifier SHALL correctly identify it as either a GitHub PR URL, an IPFS URI, or an unrecognized format.

**Validates: Requirements 1.1, 1.4**

#### Property 5: PR Metadata Extraction Round-Trip

*For any* valid GitHub PR API response object, extracting metadata and then serializing/deserializing it SHALL preserve all fields identically.

**Validates: Requirements 5.1, 5.5**

#### Property 6: Repository Validation

*For any* GitHub PR response and repository requirement pair, the repository validation logic SHALL correctly determine if the PR belongs to the expected repository.

**Validates: Requirements 4.1, 4.2, 4.3, 4.4**

#### Property 7: Merge Status Validation

*For any* GitHub PR response with merged=true, the validation SHALL pass; for any response with merged=false, validation SHALL fail (unless draft-allow is configured).

**Validates: Requirements 3.1, 3.2, 3.3**

#### Property 8: Invalid URL Format Rejection

*For any* string that does not match GitHub PR or IPFS URI patterns, parsing SHALL return an error.

**Validates: Requirements 1.3, 14.5**

#### Property 9: Error Message Consistency

*For any* validation error, the error message SHALL contain the original PR URL and a descriptive reason.

**Validates: Requirements 8.1–8.5**

#### Property 10: Metadata Storage and Retrieval

*For any* PR metadata stored in the indexer, querying the milestone SHALL return the same metadata.

**Validates: Requirements 5.3, 5.4, 9.3**

#### Property 11: Duplicate Detection

*For any* milestone with existing PR evidence, submitting the same PR URL SHALL trigger duplicate detection and prevent storage.

**Validates: Requirements 15.1, 15.2**

#### Property 12: ISO 8601 Date Formatting

*For any* GitHub API timestamp string, formatting to ISO 8601 SHALL produce a valid RFC 3339 datetime string.

**Validates: Requirements 5.2**

---

### Unit Tests

**Unit tests** verify specific examples and edge cases that complement property-based tests:

1. **URL Parsing Examples**
   - Parse GitHub PR URL with canonical format
   - Parse IPFS URI with `ipfs://` scheme
   - Reject malformed URLs (missing owner, repo, or number)
   - Handle URLs with uppercase letters

2. **Metadata Extraction**
   - Extract all required fields from API response
   - Handle missing optional fields (merged_at for unmerged PRs)
   - Handle author username with special characters

3. **Error Cases**
   - Format 404 error for PR not found
   - Format rate limit error with reset time
   - Format timeout error with retry suggestion

4. **Configuration**
   - Load GitHub token from environment variable
   - Use authenticated requests when token is configured
   - Make unauthenticated requests when token is absent

5. **Integration with Submit Milestone**
   - Parse GitHub PR URL from --evidence-uri argument
   - Validate before blockchain submission
   - Display metadata to user for confirmation
   - Proceed to blockchain submission on success

---

### Integration Tests

**Integration tests** verify end-to-end workflows with mocked GitHub API:

1. **Successful PR Validation**
   - Mock GitHub API response for merged PR
   - Verify metadata extraction
   - Verify storage in indexer DB
   - Verify blockchain transaction proceeds

2. **Failure Paths**
   - PR not found (404) → proper error message
   - Unmerged PR → proper error message
   - Wrong repository → proper error message
   - Rate limited (429) → show reset time

3. **Duplicate Submission**
   - Submit PR once → succeeds
   - Submit same PR again → duplicate error

4. **Backward Compatibility**
   - IPFS URI submission continues to work unchanged
   - Existing submit-milestone behavior unaffected

5. **Configuration**
   - With GitHub token → use authenticated requests
   - Without GitHub token → use unauthenticated requests

---

### Smoke Tests

1. **CLI Starts Without GITHUB_TOKEN**
   - CLI should work even if `GITHUB_TOKEN` is not set
   - Graceful degradation to unauthenticated rate limits

2. **IPFS Evidence Still Works**
   - Submitting IPFS URIs as evidence should continue unchanged

---

## Implementation Approach

### Module Organization

```
src/
├── commands/
│   └── submit_milestone.rs (extended to detect & validate GitHub PRs)
│
├── github_pr_validation/   (new module)
│   ├── mod.rs
│   ├── url_parser.rs       (parse & classify evidence URLs)
│   ├── github_client.rs    (GitHub REST API interaction)
│   ├── evidence_detector.rs (route to appropriate validation)
│   ├── indexer_db.rs       (persistence & queries)
│   └── error.rs            (error types)
│
├── config.rs (extended with GitHub configuration)
└── main.rs (unchanged)
```

### Dependencies

**No new major dependencies required**. Existing dependencies support the implementation:

- `reqwest` (already via `ethers`) — HTTP client for GitHub API
- `tokio` (already imported) — async runtime
- `serde` / `serde_json` (already imported) — JSON parsing
- `thiserror` (already imported) — error types

**Minor additions (if needed)**:
- `regex` (for URL parsing, or use manual parsing)
- `chrono` (for ISO 8601 date handling, or use string parsing)

### Key Implementation Decisions

1. **No New HTTP Client**
   - Reuse `reqwest::Client` created in existing code
   - Pass client as parameter to GitHub API functions (dependency injection)

2. **Manual URL Parsing**
   - Avoid adding regex dependency if possible
   - Use string splitting and parsing for simplicity and testability

3. **Mock-Based Testing**
   - Don't make real API calls in tests
   - Use `mockito` or similar for HTTP mocking

4. **Fail-Fast Validation**
   - Validate PR before blockchain submission
   - Prevents wasted gas fees on invalid evidence

5. **Pure Functions for Core Logic**
   - URL parsing, metadata extraction, validation logic are pure
   - Easy to test with property-based testing
   - Side effects (HTTP, DB) isolated

---

## Integration with Existing Code

### Changes to `submit_milestone` Command

```rust
// Before: evidence_uri can only be IPFS
// After: evidence_uri can be GitHub PR URL or IPFS

pub async fn run(cfg: Config, args: SubmitMilestoneArgs) -> Result<()> {
    // 1. Load GitHub configuration
    let github_config = GitHubConfig::load()?;
    
    // 2. Create HTTP client
    let http_client = reqwest::Client::new();
    
    // 3. Process evidence (validates if GitHub PR)
    let validation = evidence_detector::process_evidence(
        &args.evidence_uri,
        args.grant_id,
        args.milestone_id,
        &github_config,
        &db,
        &http_client,
    ).await?;
    
    // 4. If GitHub PR, display metadata for user confirmation
    if let Some(metadata) = validation.pr_metadata {
        println!("PR: {} ({})", metadata.pr_title, metadata.pr_url);
        println!("Author: {}", metadata.author_username);
        if let Some(merged_at) = metadata.merged_at {
            println!("Merged: {}", merged_at);
        }
        println!("\nProceeding with blockchain submission...");
    }
    
    // 5. Submit blockchain transaction (unchanged)
    let client = build_signing_client(&cfg.rpc_url, &cfg.private_key).await?;
    // ... existing blockchain code ...
}
```

### Changes to `Config` Struct

```rust
impl Config {
    /// Extended to load GitHub-specific config
    pub fn load(path: Option<&Path>) -> Result<Self> {
        // ... existing code ...
        // Load GitHub config separately (optional)
    }
}
```

### No Changes to Blockchain Layer

- Smart contract interaction (`contract.rs`) unchanged
- CLI argument parsing (`cli.rs`) unchanged
- All other commands unchanged

---

## Correctness Properties

*A property is a characteristic or behavior that should hold true across all valid executions of a system—essentially, a formal statement about what the system should do. Properties serve as the bridge between human-readable specifications and machine-verifiable correctness guarantees.*

### Property 1: GitHub PR URL Parsing

*For any* valid GitHub PR URL in the canonical format `https://github.com/{owner}/{repo}/pull/{number}`, parsing SHALL extract the correct owner, repo, and number, and classify the evidence as a GitHub PR.

**Validates: Requirements 1.2, 14.1**

### Property 2: Fragment and Parameter Stripping

*For any* GitHub PR URL with fragments (`#...`) or query parameters (`?...`), parsing SHALL extract the PR identifier correctly and discard all fragments and parameters.

**Validates: Requirements 14.3, 14.4**

### Property 3: Evidence Type Classification

*For any* valid evidence URI, the classifier SHALL correctly identify it as either a GitHub PR URL, an IPFS URI, or an unrecognized format, and SHALL never misclassify one type as another.

**Validates: Requirements 1.1, 1.4**

### Property 4: Invalid Format Rejection

*For any* string that does not match valid GitHub PR or IPFS URI patterns, parsing SHALL return an error with a clear message indicating the format is invalid.

**Validates: Requirements 1.3, 14.5, 8.1**

### Property 5: PR Metadata Extraction Invariant

*For any* valid GitHub PR API response, extracting metadata and serializing/deserializing it SHALL preserve all fields identically (round-trip invariant).

**Validates: Requirements 5.1, 5.4**

### Property 6: Repository Validation Logic

*For any* GitHub PR response and repository requirement configuration, the validation logic SHALL correctly determine whether the PR belongs to the expected repository, returning true only when owner/repo matches exactly.

**Validates: Requirements 4.1, 4.2, 4.3, 4.4**

### Property 7: Merge Status Validation

*For any* GitHub PR response with `merged=true`, validation SHALL pass; for any response with `merged=false`, validation SHALL fail unless draft-allow mode is configured.

**Validates: Requirements 3.1, 3.2, 3.3, 3.4**

### Property 8: Metadata Storage and Retrieval

*For any* PR metadata stored in the indexer, querying the corresponding milestone SHALL return the stored metadata unchanged.

**Validates: Requirements 5.3, 9.2, 9.3**

### Property 9: Duplicate Detection

*For any* milestone that already has a submitted PR, attempting to submit the same PR URL again SHALL be rejected with a duplicate error, while submitting a different PR SHALL be allowed.

**Validates: Requirements 15.1, 15.2, 15.3**

### Property 10: ISO 8601 Date Formatting

*For any* GitHub API timestamp string in ISO 8601 format, formatting and parsing SHALL produce equivalent datetime values (allowing for minor precision differences in seconds/milliseconds).

**Validates: Requirements 5.2**

### Property 11: Authentication Header Inclusion

*For any* request to GitHub API when authentication is configured, the Authorization header SHALL contain "Bearer {token}"; when no authentication is configured, the header SHALL be absent.

**Validates: Requirements 6.2, 6.3**

### Property 12: Error Message Consistency

*For any* validation failure, the error message SHALL include the original evidence URI and a descriptive reason for the failure.

**Validates: Requirements 8.2–8.5**

---

## Error Handling

### HTTP Error Codes and Mapping

| HTTP Code | Scenario | Error Type | User Message |
|-----------|----------|-----------|--------------|
| 200 OK | PR retrieved successfully | None (success) | — |
| 404 Not Found | PR does not exist | `PRNotFound` | "PR not found: owner/repo#number" |
| 403 Forbidden | Insufficient permissions | `HTTPError` | "GitHub API access denied (403)" |
| 429 Too Many Requests | Rate limit exceeded | `RateLimited` | "Rate limited. Reset at {time}" |
| 500+ Server Error | GitHub experiencing issues | `HTTPError` | "GitHub API error: {status} {message}" |
| Timeout (30s) | Request hung | `Timeout` | "GitHub API request timed out" |
| Connection Error | Network unreachable | `NetworkError` | "Failed to reach GitHub API: {details}" |

### Handling Not Merged (Draft) PRs

- **Default (Strict)**: Draft/unmerged PRs rejected with error "PR must be merged"
- **Optional (Draft-Allow)**: Configuration to accept draft PRs (TBD in future iteration)

---

## Testing Strategy

### Test Coverage Goals

1. **Unit Tests** (40% of tests)
   - URL parsing: canonical, with fragments, with parameters, invalid formats
   - Metadata extraction: all fields, missing optional fields, special characters
   - Error formatting: all error types, proper message content
   - Configuration: token loading, optional parameters

2. **Property-Based Tests** (40% of tests)
   - URL parsing properties (Properties 1–4)
   - Metadata round-trip (Properties 5, 8)
   - Validation logic (Properties 6–7, 11)
   - Duplicate detection (Property 9)

3. **Integration Tests** (20% of tests)
   - End-to-end: GitHub PR validation → metadata extraction → storage → query
   - Error paths: not found, unmerged, wrong repo, rate limited
   - Backward compatibility: IPFS URIs still work
   - CLI integration: submit-milestone with GitHub PR

### Test Execution

```bash
# Unit tests
cargo test github_pr_validation::unit --lib

# Property-based tests (with 100+ iterations)
cargo test github_pr_validation::property --lib

# Integration tests (requires mocked GitHub API)
cargo test github_pr_validation::integration --test '*'

# Full suite
cargo test github_pr_validation
```

---

## Logging and Observability

### Log Levels

**DEBUG**: Full request/response details, intermediate validation steps
**INFO**: Validation attempts, success/failure, metadata extracted
**WARN**: Storage failures (but validation passed), fallback behavior
**ERROR**: Validation failures, API errors, network errors

### Log Examples

```
[INFO] Validating GitHub PR: https://github.com/org/repo/pull/42
[INFO] Extracted PR metadata: {"pr_number": 42, "title": "Add feature X", "author": "alice", ...}
[INFO] PR metadata stored for grant 1, milestone 2

[WARN] Failed to store PR metadata: database connection timeout
[WARN] Validation passed, but indexer storage failed. User may retry submission.

[ERROR] PR validation failed: PR not found (github.com/org/repo#42)
[ERROR] GitHub API rate limited. Reset at 2024-12-20 15:30:00 UTC

[DEBUG] GitHub API request: GET https://api.github.com/repos/org/repo/pulls/42
[DEBUG] Request headers: Authorization: Bearer ***, User-Agent: grantstream-cli/0.1.0
[DEBUG] Response status: 200, Content-Length: 1234
[DEBUG] Parsed response: {json output}
```

### Verbose Mode

Enable with environment variable `GRANTSTREAM_VERBOSE=1` or flag `--verbose`:

- Full GitHub API responses
- All intermediate validation steps
- Timing information for each validation stage
- Configuration values (token presence, required repo, etc.)

---

## Future Enhancements

1. **Draft PR Support**: Optional configuration to accept unmerged/draft PRs
2. **PR History Filtering**: Only PRs merged after grant creation date
3. **Multiple Repository Support**: Allow multiple repos per grant
4. **Webhook Validation**: Real-time PR validation when merged (not just on submission)
5. **GitHub App Integration**: Use GitHub App authentication instead of personal token (higher rate limits)
6. **PR Verification**: Optional signature verification (proving grantee ownership of PR author account)

---

## Design Summary

This design provides:

✅ **Seamless Integration**: URL detection automatically routes to appropriate validator
✅ **Robust Validation**: Multi-step checks ensure PR legitimacy
✅ **Rich Metadata**: All PR details persisted for audit trail
✅ **Clear Error Messages**: Users understand failures and how to fix them
✅ **Flexible Configuration**: Works with or without API token, optional repo requirements
✅ **Non-Breaking**: Existing IPFS workflow completely unchanged
✅ **Testable**: Pure functions enable comprehensive property-based testing
✅ **Production-Ready**: Rate limiting, timeouts, error handling all covered
