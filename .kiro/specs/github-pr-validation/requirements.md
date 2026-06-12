# GitHub PR Validation for GrantStream Milestone Evidence

## Introduction

This feature extends grantstream-verifier (the GrantStream CLI tool) to support GitHub Pull Requests as a specific evidence type for milestone submission in the GrantStream grant escrow protocol. Currently, milestones accept generic IPFS URIs as evidence. This feature adds first-class support for GitHub PRs, enabling grantees to submit PRs as evidence and automating PR validation to ensure they meet specific criteria before being accepted by verifiers.

The feature integrates with the GitHub REST API to validate that submitted PRs exist, are merged, belong to the correct repository, and extracts metadata (title, merge date, author) that is stored alongside the milestone evidence in the indexer database.

## Glossary

- **Grantee**: The account receiving grant funds; responsible for submitting milestone evidence
- **Verifier**: The account designated to approve or reject milestone evidence submissions
- **Evidence**: Proof of work completion submitted by the grantee (currently IPFS URIs, soon GitHub PR URLs)
- **PR URL**: A GitHub Pull Request identifier in the form `https://github.com/{owner}/{repo}/pull/{number}`
- **PR Metadata**: Structured information extracted from a GitHub PR: title, merge date, author username, PR number, repository
- **Indexer DB**: Off-chain database that stores milestone metadata and associated PR details for querying and verification
- **Milestone**: A deliverable within a grant with an associated amount, status, and evidence
- **Repository Owner**: The GitHub organization or user that owns the repository containing the PR
- **Merged Status**: The state of a PR indicating it has been integrated into the target branch
- **Rate Limiting**: GitHub API rate-limit mechanism that restricts API calls; affects authentication strategy
- **CLI**: Command-line interface for grantstream-verifier; provides subcommands for grant operations
- **GitHub API Token**: Optional authentication credential for increased GitHub API rate limits

## Requirements

### Requirement 1: Accept GitHub PR URLs in Evidence Submission

**User Story:** As a grantee, I want to submit a GitHub PR URL as evidence for a milestone, so that I can prove my work completion by referencing my actual code contribution.

#### Acceptance Criteria

1. WHEN a grantee submits milestone evidence, THE CLI SHALL accept both IPFS URIs and GitHub PR URLs in the `--evidence-uri` parameter
2. WHEN a GitHub PR URL is submitted, THE Validator SHALL identify it as a GitHub PR by the URL format (matching pattern `https://github.com/[owner]/[repo]/pull/[number]`)
3. WHEN an invalid URL format is provided, THE Validator SHALL return a clear error indicating the URL format is not recognized
4. WHEN a grantee submits evidence, THE CLI SHALL distinguish between GitHub PR URLs and IPFS URIs before processing

### Requirement 2: Validate PR Existence via GitHub REST API

**User Story:** As a verifier, I want to ensure submitted PRs actually exist on GitHub, so that fake or malformed PR URLs cannot be accepted as evidence.

#### Acceptance Criteria

1. WHEN a GitHub PR URL is submitted, THE GitHub_Validator SHALL query the GitHub REST API using the extracted owner, repository, and PR number
2. WHEN the GitHub API confirms the PR exists, THE GitHub_Validator SHALL proceed to additional validation checks
3. IF the PR does not exist (HTTP 404 response), THEN THE GitHub_Validator SHALL return an error indicating the PR was not found
4. IF the GitHub API is unreachable or returns an error, THEN THE GitHub_Validator SHALL return a descriptive error including the HTTP status code

### Requirement 3: Validate PR is Merged

**User Story:** As a verifier, I want to ensure that milestone evidence PRs are actually merged, so that only completed work counts toward milestone approval.

#### Acceptance Criteria

1. WHEN a PR is successfully retrieved, THE GitHub_Validator SHALL check the PR's `merged` field from the GitHub REST API response
2. IF a PR is merged, THE GitHub_Validator SHALL continue processing and mark it as valid for this criterion
3. IF a PR is not merged (open or draft state), THEN THE GitHub_Validator SHALL return an error indicating the PR must be merged before it can be accepted as evidence
4. WHERE optional configuration specifies draft PRs are acceptable, THE GitHub_Validator SHALL accept draft PRs as meeting this criterion

### Requirement 4: Validate PR Belongs to Expected Repository

**User Story:** As a grant administrator, I want to ensure PRs submitted as evidence come from the designated repository, so that milestones are tied to work in the correct codebase.

#### Acceptance Criteria

1. WHERE a grant specifies a required repository (owner/repo pair), THE GitHub_Validator SHALL compare the PR's repository against this expected value
2. IF the PR repository matches the expected repository, THE GitHub_Validator SHALL continue processing
3. IF the PR repository does not match, THEN THE GitHub_Validator SHALL return an error indicating the PR is from an unexpected repository
4. WHERE no repository requirement is configured, THE GitHub_Validator SHALL accept PRs from any repository

### Requirement 5: Extract and Store PR Metadata

**User Story:** As an indexer, I want to store detailed PR information alongside milestone evidence, so that verifiers and administrators can review PR details without making additional API calls.

#### Acceptance Criteria

1. WHEN a PR is validated successfully, THE GitHub_Validator SHALL extract the following metadata: PR number, PR title, merge date (datetime), author username, repository owner, repository name
2. WHEN metadata is extracted, THE PR_Metadata_Extractor SHALL format the merge date as ISO 8601 timestamp
3. WHEN metadata extraction completes, THE Indexer_DB SHALL store all extracted metadata in association with the milestone evidence record
4. WHEN PR metadata is queried from the indexer, THE Query_Handler SHALL return the complete metadata structure including all extracted fields
5. WHERE merge date is not available (unmerged PR), THE PR_Metadata_Extractor SHALL store null or omit the field in the metadata record

### Requirement 6: Handle GitHub API Authentication

**User Story:** As a CLI operator, I want to authenticate with GitHub API to avoid rate limiting, so that the tool can validate multiple PRs without hitting the unauthenticated rate limit.

#### Acceptance Criteria

1. WHEN the CLI starts, THE Config_Loader SHALL check for a GitHub API token in environment variable `GITHUB_TOKEN` or `.env` file
2. WHERE a GitHub API token is configured, THE GitHub_Validator SHALL include it in the Authorization header for all GitHub API requests
3. WHERE no GitHub API token is configured, THE GitHub_Validator SHALL make unauthenticated requests (subject to stricter rate limits)
4. IF a GitHub API token is provided but invalid, THE Config_Loader SHALL return an error during startup
5. WHERE the GitHub API token is configured, THE GitHub_Validator SHALL use authenticated rate limits (5000 requests/hour) instead of unauthenticated limits (60 requests/hour)

### Requirement 7: Handle Rate Limiting Errors

**User Story:** As a CLI operator, I want the tool to handle GitHub API rate limits gracefully, so that transient rate-limit errors don't cause permanent failures.

#### Acceptance Criteria

1. WHEN the GitHub API returns a 429 (Too Many Requests) response, THE GitHub_Validator SHALL return an error indicating rate limiting has been triggered
2. WHEN rate limiting occurs, THE Error_Handler SHALL include the `X-RateLimit-Reset` header value in the error message to inform the user when they can retry
3. IF rate limiting occurs, THEN THE GitHub_Validator SHALL NOT retry automatically; the user must retry the command after the reset time
4. WHEN rate limit information is included in the response, THE Error_Handler SHALL display the information in a human-readable format (e.g., "Rate limited. Reset at 2024-12-20 15:30:00 UTC")

### Requirement 8: Handle PR Not Found / Invalid PR Errors

**User Story:** As a verifier, I want clear error messages when PR validation fails, so that I can quickly identify issues and communicate them to the grantee.

#### Acceptance Criteria

1. IF a PR URL is malformed, THEN THE URL_Parser SHALL return an error indicating the URL format is invalid
2. IF a PR does not exist (404), THEN THE GitHub_Validator SHALL return an error: "PR not found: {owner}/{repo}#{number}"
3. IF a PR is not merged, THEN THE GitHub_Validator SHALL return an error: "PR must be merged before being accepted as evidence: {PR URL}"
4. IF a PR is from the wrong repository, THEN THE GitHub_Validator SHALL return an error: "PR is from {actual_repo}, but expected {expected_repo}"
5. IF the GitHub API returns a 403 Forbidden response (permission issue), THEN THE GitHub_Validator SHALL return an error indicating access was denied

### Requirement 9: Store PR Metadata in Indexer Database

**User Story:** As an administrator, I want PR metadata persisted in the indexer database, so that I can query and audit milestone evidence across multiple milestones and grants.

#### Acceptance Criteria

1. WHEN a PR is validated and accepted, THE Indexer_DB SHALL create a record linking the milestone to the PR metadata
2. THE Indexer_DB record SHALL store: milestone ID, grant ID, PR URL, PR number, PR title, merge date, author username, repository owner, repository name, validation timestamp
3. WHEN querying a milestone, THE Indexer_DB SHALL return the associated PR metadata as a structured object
4. WHERE multiple PR evidence submissions exist for the same milestone (resubmissions), THE Indexer_DB SHALL store all historical submissions with timestamps to enable audit trails
5. IF Indexer_DB write fails, THEN THE Error_Handler SHALL log the error and return a message indicating the validation passed but persistence failed (allowing manual retry)

### Requirement 10: Integrate PR Validation into Submit Milestone Workflow

**User Story:** As a grantee, I want PR validation to happen automatically during milestone submission, so that I receive immediate feedback on whether my evidence is acceptable.

#### Acceptance Criteria

1. WHEN a grantee runs `submit-milestone` with a GitHub PR URL, THE CLI SHALL validate the PR before sending the blockchain transaction
2. IF PR validation passes, THE CLI SHALL proceed to submit the evidence on-chain
3. IF PR validation fails, THE CLI SHALL display the error and NOT submit the blockchain transaction
4. WHEN PR validation completes (pass or fail), THE CLI SHALL display the validation result to the user with clear messaging
5. WHERE validation passes, THE CLI SHALL display PR metadata (title, author, merge date) before confirming the transaction

### Requirement 11: Configure Expected Repository per Grant (Optional)

**User Story:** As a grant funder, I want to specify which GitHub repository(ies) contain expected evidence PRs, so that milestone evidence is constrained to relevant repositories.

#### Acceptance Criteria

1. WHERE a grant creation includes an optional `--github-repo` parameter, THE CLI SHALL store this repository specification with the grant metadata
2. WHEN a milestone is submitted for a grant with a repository requirement, THE GitHub_Validator SHALL validate that the PR belongs to the specified repository
3. WHERE no repository requirement is set, THE GitHub_Validator SHALL accept PRs from any repository
4. WHEN querying a grant, THE Grant_Query_Handler SHALL return the repository requirement (if configured) alongside other grant metadata

### Requirement 12: Handle Network and Timeout Errors

**User Story:** As a CLI operator, I want the tool to handle network failures gracefully, so that transient connectivity issues don't crash the application.

#### Acceptance Criteria

1. IF the GitHub API is unreachable (network error), THEN THE GitHub_Validator SHALL return an error: "Failed to reach GitHub API: {error details}"
2. IF a GitHub API request times out (exceeds 30 seconds), THEN THE GitHub_Validator SHALL return an error: "GitHub API request timed out"
3. WHEN a network error occurs, THE Error_Handler SHALL suggest retrying the command after checking network connectivity
4. IF network errors occur repeatedly (3+ attempts), THEN THE CLI SHALL return a consolidated error message advising the user to check their internet connection

### Requirement 13: Log PR Validation Activity

**User Story:** As a system administrator, I want PR validation attempts logged for debugging and audit purposes, so that I can investigate validation issues and track validation history.

#### Acceptance Criteria

1. WHEN a PR validation request is initiated, THE Logger SHALL record: timestamp, PR URL, user/wallet address initiating the request, validation status (pass/fail)
2. WHEN a PR validation succeeds, THE Logger SHALL record the extracted metadata
3. WHEN a PR validation fails, THE Logger SHALL record the failure reason and error details
4. WHEN GitHub API requests are made, THE Logger SHALL record the request (URL, authentication used) and response status code in debug-level logs
5. WHERE verbose logging is enabled (environment variable or CLI flag), THE Logger SHALL log additional details: full GitHub API response, intermediate validation steps

### Requirement 14: Parse GitHub PR URLs with Flexible Format Support

**User Story:** As a grantee, I want the tool to accept GitHub PR URLs in common formats, so that I don't need to remember exact URL formatting.

#### Acceptance Criteria

1. WHEN a PR URL is provided, THE URL_Parser SHALL accept the canonical format: `https://github.com/{owner}/{repo}/pull/{number}`
2. WHEN a PR URL is provided, THE URL_Parser SHALL accept the short format: `https://github.com/{owner}/{repo}/pull/{number}` (same as canonical)
3. WHERE a PR URL includes trailing fragments (e.g., `#discussion-12345`), THE URL_Parser SHALL extract the PR number and discard fragments
4. WHERE a PR URL includes query parameters, THE URL_Parser SHALL extract the PR number and discard parameters
5. IF a URL does not match any accepted GitHub PR format, THEN THE URL_Parser SHALL return an error with the format specification

### Requirement 15: Prevent Duplicate Milestone Evidence Submissions

**User Story:** As a verifier, I want to prevent the same PR from being submitted as evidence multiple times for the same milestone, so that duplicates cannot inflate the evidence record.

#### Acceptance Criteria

1. WHEN a milestone has existing evidence (PR or IPFS), THE Indexer_DB SHALL check if a new PR submission references the same PR
2. IF the same PR URL is resubmitted for the same milestone, THEN THE Duplicate_Check SHALL return an error: "This PR has already been submitted as evidence for this milestone"
3. WHERE different PRs are submitted for the same milestone (resubmission after rejection), THE Duplicate_Check SHALL allow the new submission
4. WHEN querying a milestone, THE Indexer_DB SHALL return all submitted evidence (including duplicates or resubmissions) with submission timestamps for audit purposes

---

## Implementation Notes

### Technical Integration Points

1. **CLI Extension**: The existing `submit-milestone` command will be extended to detect GitHub PR URLs and trigger validation before blockchain submission.

2. **GitHub API Library**: The reqwest HTTP client (already in Cargo.toml via ethers dependencies) will be used directly for GitHub REST API calls. No new major dependencies are required.

3. **Indexer Database**: The metadata storage layer is assumed to exist; this spec requires it to accept and persist PR metadata records alongside milestone evidence.

4. **Configuration**: GitHub API token and optional repository requirements will be added to the existing Config struct and loaded from environment variables or .env file.

5. **Error Handling**: Leverages the existing anyhow/thiserror error handling patterns in the codebase.

### Acceptance Criteria Testing Strategy

**Property-Based Testing Recommendations:**

1. **Round-Trip Properties**: URL parsing should correctly extract and reconstruct PR identifiers (owner, repo, number) from various URL formats.

2. **Invariants**: PR metadata extracted from GitHub API should maintain consistent structure across all validation paths.

3. **Metamorphic Properties**: Multiple validations of the same PR should yield identical results (unless PR state changes on GitHub).

4. **Model-Based Testing**: Compare actual GitHub API responses against expected schema for PR objects.

**Integration Testing Recommendations:**

1. Test with real (or mocked) GitHub API responses for common scenarios: merged PR, unmerged PR, PR not found, rate limiting.

2. Verify end-to-end flow: URL parsing → API call → metadata extraction → indexer storage → query retrieval.

3. Test error paths: invalid URLs, network timeouts, authentication failures, rate limits.

**Smoke Tests:**

1. Verify the CLI still functions without GitHub token configured (graceful degradation to unauthenticated mode).

2. Verify existing IPFS evidence submission continues to work unchanged.

---

## Acceptance Criteria Format

The acceptance criteria follow the EARS (Easy Approach to Requirements Syntax) pattern to ensure clarity and testability:

- **Ubiquitous (THE System SHALL)**: Requirements that always apply
- **Event-driven (WHEN/THEN)**: Requirements triggered by specific events or conditions  
- **State-driven (WHILE)**: Requirements that apply during specific states
- **Unwanted event (IF/THEN)**: Error handling and failure scenarios
- **Optional feature (WHERE)**: Requirements that depend on configuration or optional setup

All criteria are:

- **Specific and measurable**: Concrete behaviors with verifiable outcomes
- **Solution-independent**: Focused on what the system must do, not how
- **Testable**: Each criterion can be validated through unit, integration, or property-based tests
- **Atomic**: Each criterion tests one distinct behavior

