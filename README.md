# Jira Utilities

A collection of standalone Ruby scripts for analyzing and working with Jira data.

## Prerequisites

- Ruby 3.x
- Jira API token ([Generate here](https://id.atlassian.com/manage-profile/security/api-tokens))
- `excon` gem: `gem install excon`

## Common Setup

All scripts require these environment variables:

```bash
export JIRA_EMAIL='your@email.com'
export JIRA_API_TOKEN='your_api_token_here'
export JIRA_BASE_URL='https://yourcompany.atlassian.net'
```

**Tip:** Add these to your `~/.zshrc` or `~/.bashrc` for persistent configuration.

---

## Scripts

### 📊 Sprint Cycle Time Analyzer

Analyzes how long stories spend in tracked statuses across sprints in a quarter.

<details>
<summary><strong>View Details</strong></summary>

#### Description

Calculates business days (Monday-Friday, excluding weekends) that stories spend in configured statuses during a sprint. Provides insights into:
- Average cycle time by story point value
- Median, min, and max cycle times
- Potentially inflated stories (taking longer than expected)
- Story exclusion based on inflation criteria

#### Configuration

**Required Environment Variables:**
- `JIRA_EMAIL` - Your Jira email address
- `JIRA_API_TOKEN` - Your Jira API token
- `JIRA_BASE_URL` - Your Jira instance URL

**Optional Environment Variables:**
- `JIRA_BOARD_ID` - Default board ID (can be overridden with `-b` flag)
- `SPRINT_PATTERN` - Sprint naming pattern (default: `"Sprint {year}Q{quarter} #"`)
  - Use `{year}` and `{quarter}` as placeholders
  - Example: `"Team Alpha '{year}Q{quarter} #"`

**Tracked Statuses:**

By default, the script tracks time in:
- "In Development"
- "In Review"
- "Ready for Deploy"

To customize, edit the `TRACKED_STATUSES` constant in the script.

#### Usage

```bash
ruby analyze_sprint_cycle_time.rb -y <year> -q <quarter> [options]
```

**Required Flags:**
- `-y, --year YEAR` - Year (2-digit format, e.g., 25 for 2025)
- `-q, --quarter QUARTER` - Quarter (1-4)

**Optional Flags:**
- `-b, --board BOARD_ID` - Jira board ID (overrides JIRA_BOARD_ID env var)
- `--show-inflated-stories` - Display stories where `business_days > (story_points * 10)`
- `--exclude-inflated-stories` - Exclude inflated stories from main report
- `-h, --help` - Show help message

#### Examples

```bash
# Basic analysis for Q4 2025
ruby analyze_sprint_cycle_time.rb -y 25 -q 4

# Show inflated stories
ruby analyze_sprint_cycle_time.rb -y 25 -q 4 --show-inflated-stories

# Exclude inflated stories from averages
ruby analyze_sprint_cycle_time.rb -y 25 -q 4 --exclude-inflated-stories

# Use a specific board
ruby analyze_sprint_cycle_time.rb -b 500 -y 25 -q 4

# Custom sprint pattern
export SPRINT_PATTERN="Team Alpha '{year}Q{quarter} #"
ruby analyze_sprint_cycle_time.rb -y 25 -q 4
```

#### Output

**Cycle Time Analysis:**
```
================================================================================
CYCLE TIME ANALYSIS
================================================================================

Total Stories: 42
With Story Points: 40
Without Story Points: 2

Average Business Days in Tracked Statuses by Story Points:
────────────────────────────────────────────────────────────────────────────────
1 points (05 stories): avg 2.4 days | median 02 | min 01 | max 04
2 points (08 stories): avg 3.8 days | median 03 | min 02 | max 06
3 points (12 stories): avg 5.2 days | median 05 | min 03 | max 08
5 points (10 stories): avg 8.7 days | median 08 | min 05 | max 15
8 points (05 stories): avg 12.3 days | median 11 | min 08 | max 18
```

**Inflated Stories Report (with `--show-inflated-stories`):**
```
================================================================================
POTENTIALLY INFLATED STORIES
================================================================================

Criteria: business_days > (story_points * 10)
Found 3 potentially inflated stories

📊 3 Point Stories (expected ≤ 30 days, found 1 inflated):
────────────────────────────────────────────────────────────────────────────────
  • PROJ-1234    | 42 days (+12 / +40%) | In Review
    Implement complex authentication flow with OAuth integration...
```

#### How It Works

1. **Fetches all sprints** matching the configured pattern for the specified quarter
2. **Collects unique stories** across all matching sprints
3. **Analyzes changelog** for each story to calculate time in tracked statuses
4. **Calculates business days** (excludes weekends, does not account for holidays)
5. **Generates statistics** grouped by story point value

#### Notes

- Business day calculation uses Monday-Friday only (no holiday calendar)
- Stories without story points are excluded from analysis
- Duplicate stories across sprints are counted only once
- If a story is currently in a tracked status, time is counted up to the present

</details>

---

## Contributing

When adding new scripts:

1. Keep them standalone (minimal dependencies)
2. Use environment variables for configuration
3. Add detailed documentation in a collapsible section above
4. Follow the existing code style

## License

MIT
