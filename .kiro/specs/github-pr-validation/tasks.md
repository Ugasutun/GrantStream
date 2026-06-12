# Implementation Plan: GitHub PR Validation for GrantStream Milestone Evidence

## Overview

This implementation plan provides a comprehensive task list for extending the GrantStream CLI to validate GitHub Pull Request URLs as milestone evidence. The plan is organized by the 5 core components from the design (URL Parser, GitHub API Client, Evidence Detector, Indexer DB Integration, Configuration), with explicit tasks for each of the 12 correctness properties that require property-based testing.

The implementation is ordered with prerequisites first, ensuring each task builds on previous work. Testing tasks (marked with `*`) are optional but strongly recommended for production quality.

---

## Tasks

### Phase 1: Setup & Configuration

- [ ] 1. Set up github_pr_validation module structure
  - Create `src/github_pr_validation/` directory
  - Create `src/github_pr_validation/mod.rs` with module exports
  - Create individual module files: `url_parser.rs`, `github_client.rs`, `evidence_detector.rs`, `indexer_db.rs`, `error.rs`
  - Import `github_pr_validation` module in `src/lib.rs` or main module tree
  - _Complexity: Simple_
  - _Requirements: —_

- [ ] 2. Extend Config struct with GitHub token configuration
  - Add `github_token: Option<String>` field to Config struct
  - Extend `Config::load()` to read `GITHUB_TOKEN` from environment or .env file
  - Add optional `GITHUB_TOKEN` documentation to `.env.example`
  - Validate token is non-empty if provided (optional: test token with GitHub API)
  - _Complexity: Simple_
  - _Requirements: 6.1, 6.2, 6.3_

---

### Phase 2: URL Parser Component

- [ ] 3. Implement URL parsing and evidence type classification
  - Create `url_parser.rs` with `EvidenceType` and `GitHubPRIdentifier` data structures
  - Implement `parse_evidence_url()` function to classify and parse URLs
  - Implement `extract_github_pr_parts()` for GitHub URL extraction (manually parse owner, repo, number)
  - Implement URL fragment/parameter stripping logic (remove `#...` and `?...` before parsing)
  - Define comprehensive `ParseError` types for all failure modes
  - Handle canonical format: `https://github.com/{owner}/{repo}/pull/{number}`
  - Validate owner and repo are non-empty strings; number is valid u64
  - Classify IPFS URIs (schemes: `ipfs://`, or content hash patterns like `Qm...`)
  - _Complexity: Medium_
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 14.1, 14.3, 14.4, 14.5_

- [ ]* 3.1 Write unit tests for URL parsing
  - Test canonical GitHub PR URL parsing
  - Test GitHub URL with fragment stripping
  - Test GitHub URL with query parameters
  - Test IPFS URI classification
  - Test invalid URL rejection (malformed owner/repo/number)
  - Test empty/whitespace handling
  - Test URL with uppercase letters
  - _Requirements: 1.2, 14.1, 14.3, 14.4_

- [ ]* 3.2 Write property-based tests for URL parsing
  - **Property 1: GitHub PR URL Parsing** — For any valid GitHub PR URL in canonical format, parsing SHALL extract correct owner, repo, and number
  - **Property 2: Fragment and Parameter Stripping** — For any GitHub PR URL with fragments/parameters, parsing SHALL extract PR identifier correctly and discard fragments/parameters
  - **Property 3: Evidence Type Classification** — For any valid evidence URI, classifier SHALL identify it as GitHub PR, IPFS URI, or unrecognized format without misclassification
  - **Property 4: Invalid Format Rejection** — For any string not matching valid patterns, parsing SHALL return error with clear message
  - _Validates: Requirements 1.1–1.4, 14.1, 14.3, 14.4, 14.5_

---

### Phase 3: GitHub API Client Component

- [ ] 4. Create GitHub API client and HTTP request building
  - Create `github_client.rs` with `GitHubConfig`, `GitHubPRResponse`, `GitHubUser`, `GitHubRef`, `GitHubRepository`, `GitHubOwner` data structures
  - Create `PRMetadata` struct with all extraction fields (pr_number, pr_title, pr_url, merged_at, author_username, repo_owner, repo_name, submission_timestamp)
  - Implement `build_github_request()` to construct GET request to GitHub REST API endpoint
  - Add Authorization header with Bearer token when `config.api_token` is present
  - Set User-Agent header to `grantstream-cli/0.1.0`
  - Set request timeout to 30 seconds
  - Define comprehensive error types: `GitHubValidationError`, `GitHubAPIError`, `MergeStatusError`, `RepositoryOwnershipError`
  - _Complexity: Medium_
  - _Requirements: 2.1, 6.2, 6.3, 6.4, 6.5, 8.1_

- [ ] 5. Implement PR metadata extraction function
  - Implement `extract_metadata()` pure function to transform GitHub API response to `PRMetadata`
  - Extract all fields: pr_number, pr_title, pr_url (reconstructed from identifier), merged_at (ISO 8601), author_username, repo_owner, repo_name
  - Format submission_timestamp as ISO 8601 string (current UTC time)
  - Handle null merged_at for unmerged PRs (store as None/null)
  - Handle special characters in author_username and pr_title correctly
  - _Complexity: Simple_
  - _Requirements: 5.1, 5.2_

- [ ] 6. Implement GitHub API request execution and error handling
  - Implement `fetch_pr_from_github()` async function to execute HTTP GET request
  - Handle timeout errors (30s) → return `GitHubValidationError::Timeout`
  - Handle network errors (connection refused, DNS failure) → return `GitHubValidationError::NetworkError`
  - Handle 404 (PR not found) → return `GitHubValidationError::PRNotFound`
  - Handle 403 (permission denied) → return `GitHubAPIError::HTTPError(403)`
  - Handle 429 (rate limited) → extract `X-RateLimit-Reset` header and return `GitHubAPIError::RateLimited`
  - Handle other non-2xx status codes → return `GitHubAPIError::HTTPError(status, body)`
  - Parse JSON response into `GitHubPRResponse` struct
  - Handle JSON parsing errors → return `GitHubAPIError::InvalidResponse`
  - _Complexity: Medium_
  - _Requirements: 2.2, 2.4, 6.5, 7.1, 7.2, 8.2–8.5, 12.1, 12.2_

- [ ] 7. Implement PR validation logic (merged status and repository checks)
  - Implement `validate_merged_status()` to check `response.merged == true`
  - For unmerged PRs (merged=false), return `MergeStatusError::NotMerged`
  - Implement `validate_repository_ownership()` to compare PR repo against `config.required_repo`
  - If required_repo is None, always return success
  - If required_repo is Some, extract actual repo from response and compare owner/name
  - On mismatch, return `RepositoryOwnershipError::WrongRepository`
  - _Complexity: Simple_
  - _Requirements: 3.1, 3.2, 3.3, 4.1, 4.2, 4.3, 4.4_

- [ ] 8. Implement main validation and metadata extraction orchestration
  - Implement `validate_and_extract_pr()` async function as main entry point
  - Sequence: build request → fetch PR → validate merged → validate repository → extract metadata → return PRMetadata
  - Fail-fast: stop on first validation failure
  - Include detailed error context in all error returns
  - _Complexity: Medium_
  - _Requirements: 2.1, 2.2, 2.3, 2.4, 3.1–3.4, 4.1–4.4, 5.1_

- [ ]* 8.1 Write unit tests for GitHub API client
  - Test successful PR fetch and metadata extraction
  - Test 404 error handling (PR not found)
  - Test unmerged PR rejection
  - Test wrong repository rejection
  - Test rate limit error (429) with reset time extraction
  - Test network timeout
  - Test JSON parsing error
  - Test metadata extraction with special characters in author/title
  - Test metadata with null merged_at field
  - _Requirements: 2.1, 2.2, 2.3, 2.4, 3.1, 3.2, 3.3, 4.1, 4.2, 4.3, 4.4, 5.1, 5.2_

- [ ]* 8.2 Write property-based tests for GitHub API client
  - **Property 5: PR Metadata Extraction Invariant** — For any valid GitHub PR API response, extracting metadata and serializing/deserializing SHALL preserve all fields identically (round-trip)
  - **Property 6: Repository Validation Logic** — For any GitHub PR response and repository requirement pair, validation logic SHALL correctly determine if PR belongs to expected repository
  - **Property 7: Merge Status Validation** — For any GitHub PR response with merged=true, validation SHALL pass; for merged=false, validation SHALL fail
  - **Property 10: ISO 8601 Date Formatting** — For any GitHub API timestamp, formatting and parsing SHALL produce equivalent datetime values
  - **Property 11: Authentication Header Inclusion** — For any request when token configured, Authorization header SHALL be present; when not configured, header SHALL be absent
  - _Validates: Requirements 3.1–3.4, 4.1–4.4, 5.1, 5.2, 6.2, 6.3_

---

### Phase 4: Evidence Detector Component

- [ ] 9. Implement evidence routing and duplicate detection
  - Create `evidence_detector.rs` with `process_evidence()` async function
  - Parse evidence_uri using `url_parser::parse_evidence_url()`
  - Classify as GitHub PR or IPFS URI
  - For GitHub PR:
    - Call `indexer_db::check_duplicate_pr()` to detect duplicate submissions
    - If duplicate found, return `EvidenceValidationError::Duplicate`
    - If not duplicate, call `github_client::validate_and_extract_pr()`
    - If validation succeeds, call `indexer_db::store_pr_metadata()`
    - Return success with metadata (even if storage fails; log warning)
  - For IPFS URI:
    - Return success (no additional validation needed)
  - Define `EvidenceValidationResult` struct with evidence_type, pr_metadata, validation_passed fields
  - _Complexity: Medium_
  - _Requirements: 1.4, 10.1, 10.2, 10.3, 10.4, 10.5, 15.1, 15.2, 15.3_

- [ ]* 9.1 Write unit tests for evidence detector
  - Test GitHub PR detection and validation path
  - Test IPFS URI pass-through (no validation)
  - Test duplicate detection blocking resubmission
  - Test duplicate allows different PR for same milestone
  - Test error propagation from URL parser
  - Test error propagation from GitHub client
  - Test metadata storage failure (warning, not error)
  - _Requirements: 1.4, 10.1–10.5, 15.1, 15.2, 15.3_

- [ ]* 9.2 Write property-based tests for evidence detector
  - **Property 3: Evidence Type Classification** — For any valid evidence URI, classifier SHALL correctly identify it as GitHub PR, IPFS URI, or unrecognized, without misclassification
  - **Property 9: Duplicate Detection** — For any milestone with existing PR evidence, submitting same PR URL SHALL be rejected; submitting different PR SHALL be allowed
  - _Validates: Requirements 1.1, 1.4, 15.1, 15.2, 15.3_

---

### Phase 5: Indexer Database Integration

- [ ] 10. Design and implement indexer database schema for PR metadata
  - Define `PRMetadataRecord` data structure with id, grant_id, milestone_id, pr_url, pr_number, pr_title, merged_at, author_username, repo_owner, repo_name, submission_timestamp, validation_passed fields
  - Create or extend indexer database schema to support PR metadata storage
  - Schema design: table `pr_evidence` with unique constraint on (grant_id, milestone_id, pr_url) to prevent exact duplicates
  - Allow resubmissions with different PRs and store all historical submissions with timestamps
  - Add indexes on: grant_id, milestone_id, (grant_id, milestone_id) for query performance
  - _Complexity: Medium_
  - _Requirements: 5.3, 9.1, 9.2, 9.4, 15.1, 15.4_

- [ ] 11. Implement PR metadata storage functions
  - Implement `store_pr_metadata()` async function to insert PR metadata record into indexer
  - Generate unique record ID (UUID or timestamp-based)
  - Set validation_passed=true (called only on successful validation)
  - Handle unique constraint violations gracefully (return duplicate error)
  - Return full `PRMetadataRecord` on success
  - _Complexity: Simple_
  - _Requirements: 5.3, 9.1, 9.2, 9.4_

- [ ] 12. Implement PR metadata query functions
  - Implement `get_milestone_pr_evidence()` async function to retrieve all PR evidence for a milestone
  - Query by grant_id and milestone_id
  - Return ordered by submission_timestamp (desc) to show most recent first
  - Handle no results gracefully (return empty vec)
  - Implement `check_duplicate_pr()` async function to check if PR already submitted for milestone
  - Query by grant_id, milestone_id, and pr_url
  - Return boolean (found or not)
  - _Complexity: Simple_
  - _Requirements: 5.4, 9.3, 15.2_

- [ ]* 12.1 Write unit tests for indexer database integration
  - Test successful PR metadata storage
  - Test retrieval of stored metadata
  - Test duplicate detection on resubmission
  - Test multiple PRs for same milestone
  - Test query returns historical submissions with timestamps
  - Test error handling on storage failure
  - Test edge cases: special characters in PR title/author, null merged_at
  - _Requirements: 5.3, 5.4, 9.1–9.4, 15.1, 15.2, 15.4_

- [ ]* 12.2 Write property-based tests for indexer database
  - **Property 8: Metadata Storage and Retrieval** — For any PR metadata stored in indexer, querying milestone SHALL return stored metadata unchanged
  - **Property 9: Duplicate Detection** — For any milestone with existing PR evidence, duplicate submission SHALL be rejected; different PR SHALL be allowed
  - _Validates: Requirements 5.3, 5.4, 15.1, 15.2, 15.3_

---

### Phase 6: Integration with submit_milestone Command

- [ ] 13. Extend submit_milestone command to detect and validate GitHub PRs
  - Modify `src/commands/submit_milestone.rs` to integrate evidence validation
  - Load GitHub configuration via `Config::load_github_config()`
  - Create `reqwest::Client` for HTTP requests
  - Call `evidence_detector::process_evidence()` before blockchain submission
  - On validation failure, display error and return (do NOT submit blockchain tx)
  - On validation success:
    - If GitHub PR: display PR metadata (number, title, author, merged_at) with formatting
    - For IPFS: proceed without additional display
  - Proceed to blockchain submission (existing code path)
  - _Complexity: Medium_
  - _Requirements: 1.4, 10.1, 10.2, 10.3, 10.4, 10.5_

- [ ]* 13.1 Write unit tests for submit_milestone integration
  - Test GitHub PR validation success → display metadata → submit blockchain
  - Test GitHub PR validation failure → display error → no blockchain submission
  - Test IPFS URI → skip GitHub validation → submit blockchain
  - Test error handling: rate limit, timeout, PR not found
  - Test user confirmation message display
  - _Requirements: 10.1–10.5_

- [ ] 14. Implement user-facing error messages and logging
  - Implement error message formatting for all validation failures:
    - URL parse errors: "Invalid GitHub PR URL: {url}. Expected format: ..."
    - PR not found: "PR not found: {owner}/{repo}#{number}"
    - Not merged: "PR must be merged before being accepted as evidence: {url}"
    - Wrong repository: "PR is from {actual}, but expected {expected}"
    - Rate limited: "GitHub API rate limited. Reset at {time}"
    - Network error: "Failed to reach GitHub API: {details}"
    - Timeout: "GitHub API request timed out (30s)"
    - Duplicate: "This PR has already been submitted as evidence for this milestone"
  - Display metadata on success (PR title, author, merge date)
  - Add logging:
    - INFO: "Validating GitHub PR: {url}", "PR metadata extracted: {...}", "PR stored for milestone"
    - WARN: "Failed to store PR metadata: {error}"
    - ERROR: "PR validation failed: {error}"
    - DEBUG: "GitHub API request: {method} {url}", "Response status: {status}"
  - _Complexity: Simple_
  - _Requirements: 8.1–8.5, 13.1–13.5_

- [ ]* 14.1 Write unit tests for error messages and logging
  - Test error message formatting for all error types
  - Test message includes original URL or PR identifier
  - Test error message provides actionable next steps
  - Test logging output at appropriate levels (INFO, WARN, ERROR, DEBUG)
  - _Requirements: 8.1–8.5, 13.1–13.5_

---

### Phase 7: Error Handling & Configuration

- [ ] 15. Implement comprehensive error handling and HTTP client setup
  - Create `error.rs` module with all error types:
    - `ParseError` (InvalidGitHubPRFormat, InvalidPRNumber, UnrecognizedEvidenceType)
    - `GitHubAPIError` (RateLimited, HTTPError, InvalidResponse)
    - `GitHubValidationError` (PRNotFound, NotMerged, WrongRepository, APIError, NetworkError, Timeout)
    - `DuplicateError`
    - `DBStorageError`
  - Use `thiserror` macro for all error types with descriptive messages
  - Implement error chaining and context for debugging
  - Create HTTP client with sane defaults (30s timeout, User-Agent header)
  - _Complexity: Simple_
  - _Requirements: 2.1–2.4, 3.1–3.4, 7.1–7.4, 8.1–8.5, 12.1–12.4_

- [ ]* 15.1 Write unit tests for error handling
  - Test all error types produce correct Display output
  - Test error context is preserved through error chains
  - Test error messages are user-friendly (no internal details)
  - Test HTTP client has correct timeout and headers
  - _Requirements: 8.1–8.5_

---

### Phase 8: Testing & Validation

- [ ] 16. Run full property-based test suite with multiple iterations
  - Execute all 12 property-based tests with 100+ iterations each
  - Properties covered:
    - Property 1: GitHub PR URL Parsing
    - Property 2: Fragment and Parameter Stripping
    - Property 3: Evidence Type Classification
    - Property 4: Invalid Format Rejection
    - Property 5: PR Metadata Extraction Invariant
    - Property 6: Repository Validation Logic
    - Property 7: Merge Status Validation
    - Property 8: Metadata Storage and Retrieval
    - Property 9: Duplicate Detection
    - Property 10: ISO 8601 Date Formatting
    - Property 11: Authentication Header Inclusion
    - Property 12: Error Message Consistency
  - All tests must pass without counterexamples
  - Run with verbose output to inspect generated test cases
  - _Complexity: Simple_
  - _Requirements: 1.1–1.4, 3.1–3.4, 4.1–4.4, 5.1–5.5, 6.1–6.5, 7.1–7.4, 8.1–8.5_

- [ ]* 16.1 Run integration tests with mocked GitHub API
  - Test successful PR validation end-to-end (parsing → API call → metadata extraction → storage → retrieval)
  - Test failure paths: PR not found (404), unmerged PR, wrong repository, rate limited (429)
  - Test duplicate submission detection
  - Test backward compatibility: IPFS URIs still work unchanged
  - Test configuration: with GitHub token (authenticated), without token (unauthenticated)
  - Test CLI integration: submit-milestone with GitHub PR URL
  - All tests must pass without production API calls (use mockito or similar for HTTP mocking)
  - _Requirements: 2.1–2.4, 3.1–3.4, 10.1–10.5, 15.1–15.4_

- [ ] 17. Verify backward compatibility with IPFS URIs
  - Submit IPFS URI evidence using existing submit-milestone command
  - Verify IPFS submission works unchanged (GitHub validation skipped)
  - Verify blockchain transaction is submitted for IPFS URIs
  - Verify no GitHub API calls are made for IPFS URIs
  - _Complexity: Simple_
  - _Requirements: 1.1, 1.4, 10.1_

- [ ] 18. Final checkpoint - Ensure all tests pass
  - Run full test suite: `cargo test github_pr_validation`
  - All unit tests pass
  - All property-based tests pass without counterexamples
  - All integration tests pass
  - No warnings or clippy lints
  - Code formatting adheres to project style (cargo fmt)
  - Ask the user if questions arise about test results or implementation details.

---

## Property-Based Testing Summary

This implementation includes 12 correctness properties that are tested with property-based testing. Each property is assigned to a specific task for verification:

| Property | Task | Status | Validates |
|----------|------|--------|-----------|
| 1. GitHub PR URL Parsing | 3.2 | To-Do | Requirements 1.2, 14.1 |
| 2. Fragment and Parameter Stripping | 3.2 | To-Do | Requirements 14.3, 14.4 |
| 3. Evidence Type Classification | 3.2, 9.2 | To-Do | Requirements 1.1, 1.4 |
| 4. Invalid Format Rejection | 3.2 | To-Do | Requirements 1.3, 14.5 |
| 5. PR Metadata Extraction Invariant | 8.2 | To-Do | Requirements 5.1, 5.4 |
| 6. Repository Validation Logic | 8.2 | To-Do | Requirements 4.1, 4.2, 4.3, 4.4 |
| 7. Merge Status Validation | 8.2 | To-Do | Requirements 3.1, 3.2, 3.3, 3.4 |
| 8. Metadata Storage and Retrieval | 12.2 | To-Do | Requirements 5.3, 5.4 |
| 9. Duplicate Detection | 9.2, 12.2 | To-Do | Requirements 15.1, 15.2, 15.3 |
| 10. ISO 8601 Date Formatting | 8.2 | To-Do | Requirements 5.2 |
| 11. Authentication Header Inclusion | 8.2 | To-Do | Requirements 6.2, 6.3 |
| 12. Error Message Consistency | Task 14 | To-Do | Requirements 8.1–8.5 |

---

## Task Dependencies

```
Phase 1 (Setup)
├── Task 1: Module structure (no dependencies)
└── Task 2: Config extension (depends on Task 1)

Phase 2 (URL Parser)
├── Task 3: URL parsing (depends on Task 1)
├── Task 3.1: Unit tests (depends on Task 3)
└── Task 3.2: PBT tests (depends on Task 3)

Phase 3 (GitHub API Client)
├── Task 4: API client setup (depends on Task 1)
├── Task 5: Metadata extraction (depends on Task 4)
├── Task 6: Request execution (depends on Task 4)
├── Task 7: Validation logic (depends on Task 6)
├── Task 8: Orchestration (depends on Tasks 5, 6, 7)
├── Task 8.1: Unit tests (depends on Task 8)
└── Task 8.2: PBT tests (depends on Task 8)

Phase 4 (Evidence Detector)
├── Task 9: Routing logic (depends on Tasks 3, 8, 12)
├── Task 9.1: Unit tests (depends on Task 9)
└── Task 9.2: PBT tests (depends on Task 9)

Phase 5 (Indexer DB)
├── Task 10: Schema design (no functional dependencies)
├── Task 11: Storage functions (depends on Task 10)
├── Task 12: Query functions (depends on Task 10, 11)
├── Task 12.1: Unit tests (depends on Task 12)
└── Task 12.2: PBT tests (depends on Task 12)

Phase 6 (CLI Integration)
├── Task 13: submit_milestone integration (depends on Tasks 2, 9)
├── Task 13.1: Unit tests (depends on Task 13)
└── Task 14: Error messages & logging (depends on Tasks 13, 15)

Phase 7 (Error Handling)
├── Task 15: Comprehensive error handling (depends on Task 1)
└── Task 15.1: Unit tests (depends on Task 15)

Phase 8 (Validation)
├── Task 16: Property test suite (depends on Tasks 3.2, 8.2, 9.2, 12.2, 14.1, 15.1)
├── Task 16.1: Integration tests (depends on all implementation tasks)
├── Task 17: Backward compatibility (depends on Task 13)
└── Task 18: Final checkpoint (depends on Tasks 16, 16.1, 17)
```

---

## Testing Strategy Summary

### Test Coverage Goals

- **Unit Tests** (40% of test suite): URL parsing, metadata extraction, error formatting, configuration
- **Property-Based Tests** (40% of test suite): All 12 correctness properties with 100+ iterations each
- **Integration Tests** (20% of test suite): End-to-end flows with mocked GitHub API

### Test Execution

```bash
# Unit tests
cargo test github_pr_validation::unit --lib

# Property-based tests (with 100+ iterations)
cargo test github_pr_validation::property --lib

# Integration tests (with mocked GitHub API)
cargo test github_pr_validation::integration --test '*'

# Full suite
cargo test github_pr_validation
```

### Optional Test Marking

Tasks marked with `*` are optional sub-tasks that can be skipped for faster MVP delivery:
- 3.1, 3.2: URL parser tests
- 8.1, 8.2: GitHub API client tests
- 9.1, 9.2: Evidence detector tests
- 12.1, 12.2: Indexer database tests
- 13.1: submit_milestone integration tests
- 14.1: Error message and logging tests
- 15.1: Error handling tests
- 16.1: Integration tests

The core implementation tasks (3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15) are required for feature completeness.

---

## Notes

- All tasks reference specific requirements and design sections for traceability
- Each task builds on previous work to ensure proper sequencing
- Property-based testing is integrated throughout to catch edge cases early
- Checkpoints (Task 18) verify the complete implementation
- Optional test tasks (marked with `*`) can be included incrementally for improved quality
- Error handling and logging are comprehensive for production use
- Backward compatibility with existing IPFS workflow is explicitly verified

