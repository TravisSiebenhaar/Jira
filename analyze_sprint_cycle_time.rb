#!/usr/bin/env ruby
# frozen_string_literal: true

# Check and require gems
begin
  require "excon"
  require "json"
  require "base64"
  require "date"
  require "optparse"
rescue LoadError => e
  puts "Missing gem: #{e.message}"
  puts "Install with: gem install excon"
  exit 1
end

# Load configuration from environment
JIRA_EMAIL = ENV["JIRA_EMAIL"] || raise("JIRA_EMAIL environment variable is required")
JIRA_API_TOKEN = ENV["JIRA_API_TOKEN"] || raise("JIRA_API_TOKEN environment variable is required")
JIRA_BASE_URL = ENV["JIRA_BASE_URL"] || raise("JIRA_BASE_URL environment variable is required (e.g., https://yourcompany.atlassian.net)")

# Optional: Default board ID (can be overridden with -b flag or JIRA_BOARD_ID env var)
JIRA_BOARD_ID = ENV["JIRA_BOARD_ID"]&.to_i

# Sprint pattern template - use {year}, {quarter} as placeholders
# Example: "Sprint {year}Q{quarter} #" or "Team Alpha '{year}Q{quarter} #"
SPRINT_PATTERN_TEMPLATE = ENV["SPRINT_PATTERN"] || "Sprint {year}Q{quarter} #"

class SprintCycleTimeAnalyzer
  # Statuses we're tracking time in
  TRACKED_STATUSES = [
    "In Development",
    "In Review",
    "Ready for Deploy",
  ].freeze

  attr_reader :board_id, :start_date, :end_date, :year, :quarter, :show_inflated_stories, :exclude_inflated_stories

  def initialize(board_id: nil, year: nil, quarter: nil, show_inflated_stories: false, exclude_inflated_stories: false)
    @auth_header = "Basic #{Base64.strict_encode64("#{JIRA_EMAIL}:#{JIRA_API_TOKEN}")}"
    @all_stories_data = {}  # Use hash to avoid duplicates, key = story key
    @show_inflated_stories = show_inflated_stories
    @exclude_inflated_stories = exclude_inflated_stories

    # Board configuration
    @board_id = board_id || JIRA_BOARD_ID || raise("Board ID is required. Set via -b flag or JIRA_BOARD_ID environment variable")

    # Year and quarter are now required
    @year = year
    @quarter = quarter

    # Calculate date range from year/quarter for sprint filtering
    if @year && @quarter
      full_year = "20#{@year}".to_i
      @start_date, @end_date = calculate_quarter_dates(full_year, @quarter)
    else
      raise "Year and quarter are required"
    end
  end

  def analyze
    @sprint_pattern = SPRINT_PATTERN_TEMPLATE
      .gsub("{year}", @year.to_s)
      .gsub("{quarter}", @quarter.to_s)

    puts "="*80
    puts "JIRA Cycle Time Analysis"
    puts "="*80
    puts "Board ID: #{@board_id}"
    puts "Period: 20#{@year} Q#{@quarter}"
    puts "Sprint Pattern: #{@sprint_pattern}*"
    puts "Tracked Statuses: #{TRACKED_STATUSES.join(", ")}\n"

    fetch_sprints_for_quarter
    collect_unique_stories
    calculate_cycle_times
    display_results
    display_inflated_stories if @show_inflated_stories
  end

  def fetch_sprints_for_quarter
    puts "\nFetching sprints for Q#{@quarter} 20#{@year}..."

    all_sprints = get_all_sprints

    # Filter sprints by name pattern using configured template
    # Replace # with a placeholder, escape, then replace placeholder with #\d+
    pattern_string = @sprint_pattern
      .gsub("#", "__NUMBER__")  # Temporary placeholder
    pattern_string = Regexp.escape(pattern_string)
      .gsub("__NUMBER__", "#\\d+")  # Replace placeholder with literal # plus digits

    sprint_pattern = Regexp.new(pattern_string)

    @quarter_sprints = all_sprints.select do |sprint|
      sprint["name"] =~ sprint_pattern
    end

    puts "Found #{@quarter_sprints.length} sprints in this quarter:"
    @quarter_sprints.each { |s| puts "  • #{s["name"]} (#{s["state"]})" }
    puts ""
  end

  def get_all_sprints
    all_sprints = []
    start_at = 0
    max_results = 50

    loop do
      response = Excon.get(
        "#{JIRA_BASE_URL}/rest/agile/1.0/board/#{@board_id}/sprint",
        headers: {
          "Authorization" => @auth_header,
          "Accept" => "application/json",
        },
        query: {
          startAt: start_at,
          maxResults: max_results,
        },
      )

      if response.status == 200
        data = JSON.parse(response.body)
        all_sprints.concat(data["values"])
        break if data["isLast"] || data["values"].empty?

        start_at += max_results
      else
        puts "❌ Failed to get sprints"
        puts "Response: #{response.body}"
        exit 1
      end
    end

    all_sprints
  end

  def collect_unique_stories
    puts "Collecting unique stories from sprints..."

    @quarter_sprints.each_with_index do |sprint, idx|
      puts "[#{idx + 1}/#{@quarter_sprints.length}] Processing #{sprint["name"]}..."

      issues = get_sprint_issues(sprint["id"])

      issues.each do |issue|
        key = issue["key"]
        # Only add if not already in our collection
        next if @all_stories_data[key]
        @all_stories_data[key] = {
          key: key,
          summary: issue.dig("fields", "summary"),
          story_points: issue.dig("fields", "customfield_10105"),
          status: issue.dig("fields", "status", "name"),
          changelog: nil,  # Will be fetched later
        }
      end
    end

    puts "Collected #{@all_stories_data.length} unique stories\n"
  end

  def get_sprint_issues(sprint_id)
    all_issues = []
    start_at = 0
    max_results = 100

    loop do
      response = Excon.get(
        "#{JIRA_BASE_URL}/rest/agile/1.0/sprint/#{sprint_id}/issue",
        headers: {
          "Authorization" => @auth_header,
          "Accept" => "application/json",
        },
        query: {
          startAt: start_at,
          maxResults: max_results,
          fields: "key,summary,customfield_10105,status",
          jql: "issuetype = Story",
        },
      )

      if response.status == 200
        data = JSON.parse(response.body)
        issues = data["issues"] || []
        all_issues.concat(issues)
        break if issues.empty? || issues.length < max_results

        start_at += max_results
      else
        puts "❌ Failed to get issues for sprint #{sprint_id}"
        return []
      end
    end

    all_issues
  end

  def calculate_cycle_times
    puts "Calculating cycle times..."

    stories = @all_stories_data.values.select { |s| s[:story_points] }
    total = stories.length

    stories.each_with_index do |story, idx|
      progress = ((idx + 1).to_f / total * 100).round
      filled = (progress / 2).round  # 50 chars for 100%
      bar = "█" * filled + "░" * (50 - filled)

      print "\r[#{bar}] #{progress}% (#{idx + 1}/#{total}) #{story[:key]}"

      changelog = get_issue_changelog(story[:key])
      business_days, status_breakdown = calculate_time_in_tracked_statuses(changelog)

      story[:business_days] = business_days
      story[:status_breakdown] = status_breakdown
    end

    print "\r" + " " * 100 + "\r"  # Clear the line
    puts "Calculation complete\n"
  end

  def get_issue_changelog(issue_key)
    all_histories = []
    start_at = 0
    max_results = 100

    loop do
      response = Excon.get(
        "#{JIRA_BASE_URL}/rest/api/3/issue/#{issue_key}",
        headers: {
          "Authorization" => @auth_header,
          "Accept" => "application/json",
        },
        query: {
          expand: "changelog",
          startAt: start_at,
          maxResults: max_results,
        },
      )

      if response.status == 200
        data = JSON.parse(response.body)
        changelog = data.dig("changelog", "histories") || []
        all_histories.concat(changelog)
        total = data.dig("changelog", "total") || 0
        break if changelog.empty? || all_histories.length >= total
        start_at += max_results
      else
        return []
      end

      sleep(0.05)
    end

    all_histories
  end

  def calculate_time_in_tracked_statuses(changelog)
    status_changes = []

    changelog.each do |history|
      history["items"].each do |item|
        next unless item["field"] == "status"

        status_changes << {
          timestamp: DateTime.parse(history["created"]),
          from_status: item["fromString"],
          to_status: item["toString"],
        }
      end
    end

    status_changes.sort_by! { |change| change[:timestamp] }

    total_business_days = 0
    status_breakdown = Hash.new(0)
    current_tracked_status = nil
    current_tracked_start = nil

    status_changes.each do |change|
      # If leaving a tracked status, calculate time spent
      if current_tracked_status && TRACKED_STATUSES.include?(current_tracked_status)
        business_days = calculate_business_days(current_tracked_start, change[:timestamp])
        total_business_days += business_days
        status_breakdown[current_tracked_status] += business_days
        current_tracked_status = nil
        current_tracked_start = nil
      end

      # If entering a tracked status, record it
      if TRACKED_STATUSES.include?(change[:to_status])
        current_tracked_status = change[:to_status]
        current_tracked_start = change[:timestamp]
      end
    end

    # If still in a tracked status, count up to now
    if current_tracked_status && TRACKED_STATUSES.include?(current_tracked_status)
      business_days = calculate_business_days(current_tracked_start, DateTime.now)
      total_business_days += business_days
      status_breakdown[current_tracked_status] += business_days
    end

    [total_business_days, status_breakdown]
  end

  def display_results
    stories = @all_stories_data.values

    if stories.empty?
      puts "❌ No stories found"
      return
    end

    # Filter out inflated stories if flag is set
    if @exclude_inflated_stories
      original_count = stories.length
      stories = stories.reject { |s| story_inflated?(s) }
      excluded_count = original_count - stories.length
    end

    stories_with_points = stories.select { |s| s[:story_points] }
    stories_without_points = stories.length - stories_with_points.length

    puts "\n" + "="*80
    puts "CYCLE TIME ANALYSIS"
    puts "="*80
    puts ""
    puts "Total Stories: #{stories.length}#{ @exclude_inflated_stories && excluded_count > 0 ? " (#{excluded_count} inflated stories excluded)" : ""}"
    puts "With Story Points: #{stories_with_points.length}"
    puts "Without Story Points: #{stories_without_points}"
    puts ""

    # Group by story points and calculate averages
    grouped = stories_with_points.group_by { |s| s[:story_points] }

    puts "Average Business Days in Tracked Statuses by Story Points:"
    puts "─" * 80

    grouped.keys.sort.each do |points|
      stories_for_points = grouped[points]
      days_array = stories_for_points.map { |s| s[:business_days] }.compact

      next if days_array.empty?

      avg = (days_array.sum.to_f / days_array.length).round(1)
      median = days_array.sort[days_array.length / 2].to_s.rjust(2, "0")
      min = days_array.min.to_s.rjust(2, "0")
      max = days_array.max.to_s.rjust(2, "0")

      puts "#{points} points (#{stories_for_points.length.to_s.rjust(2, "0")} stories): avg #{avg} days | median #{median} | min #{min} | max #{max}"

      # Calculate status breakdown percentages
      status_totals = Hash.new(0)
      stories_for_points.each do |story|
        next unless story[:status_breakdown]

        story[:status_breakdown].each do |status, days|
          status_totals[status] += days
        end
      end

      total_days_all_stories = status_totals.values.sum
      if total_days_all_stories > 0
        puts "  Status breakdown:"
        TRACKED_STATUSES.each do |status|
          days = status_totals[status]
          percentage = (days.to_f / total_days_all_stories * 100).round(1)
          puts "    #{status.ljust(20)} #{percentage.to_s.rjust(5)}% (#{days.to_s.rjust(4)} days total)"
        end
      end
      puts ""
    end

    puts ""
  end

  def display_inflated_stories
    stories_with_points = @all_stories_data.values.select { |s| s[:story_points] && s[:business_days] }

    inflated_stories = stories_with_points.select { |story| story_inflated?(story) }

    if inflated_stories.empty?
      puts "\n" + "="*80
      puts "POTENTIALLY INFLATED STORIES"
      puts "="*80
      puts "\n✅ No potentially inflated stories found (where business_days > story_points * 10) \n"
      return
    end

    puts "\n" + "="*80
    puts "POTENTIALLY INFLATED STORIES"
    puts "="*80
    puts "\nCriteria: business_days > (story_points * 10)"
    puts "Found #{inflated_stories.length} potentially inflated stories \n"

    # Group by story points
    grouped = inflated_stories.group_by { |s| s[:story_points] }

    grouped.keys.sort.each do |points|
      stories_for_points = grouped[points]
      expected_days = points * 10

      puts "\n📊 #{points} Point Stories (expected ≤ #{expected_days} days, found #{stories_for_points.length} inflated):"
      puts "─" * 80

      stories_for_points.sort_by { |s| -s[:business_days] }.each do |story|
        overage = story[:business_days] - expected_days
        # Avoid division by zero for 0-point stories
        percentage_over = expected_days > 0 ? ((overage.to_f / expected_days) * 100).round : 0

        puts "  • #{story[:key].ljust(12)} | #{story[:business_days].to_s.rjust(2)} days (+#{overage.to_s.rjust(2)} / +#{percentage_over}%) | #{story[:status]}"
        puts "    #{story[:summary][0..75]}#{story[:summary].length > 75 ? "..." : ""}"
      end
    end

    puts ""
  end

  private

  def story_inflated?(story)
    return false unless story[:story_points] && story[:business_days]

    expected_days = story[:story_points] * 10
    story[:business_days] > expected_days
  end

  def calculate_quarter_dates(year, quarter)
    case quarter
    when 1
      start_date = Date.new(year, 1, 1)
      end_date = Date.new(year, 3, 31)
    when 2
      start_date = Date.new(year, 4, 1)
      end_date = Date.new(year, 6, 30)
    when 3
      start_date = Date.new(year, 7, 1)
      end_date = Date.new(year, 9, 30)
    when 4
      start_date = Date.new(year, 10, 1)
      end_date = Date.new(year, 12, 31)
    else
      raise "Invalid quarter: #{quarter}. Must be 1-4."
    end

    [start_date, end_date]
  end

  def calculate_business_days(start_time, end_time)
    start_date = start_time.to_date
    end_date = end_time.to_date

    business_days = 0
    current_date = start_date

    while current_date < end_date
      # Check if it's a weekday (Monday=1 to Friday=5)
      business_days += 1 if (1..5).include?(current_date.wday)
      current_date = current_date.next_day
    end

    business_days
  rescue => e
    puts "   ⚠️  Error calculating business days: #{e.message}"
    0
  end
end

# Main execution
if __FILE__ == $0
  options = {}

  OptionParser.new do |opts|
    opts.banner = "Usage: ruby analyze_sprint_cycle_time.rb [options]"
    opts.separator ""
    opts.separator "Environment Variables:"
    opts.separator "  Required:"
    opts.separator "    JIRA_EMAIL         Your Jira email address"
    opts.separator "    JIRA_API_TOKEN     Your Jira API token"
    opts.separator "    JIRA_BASE_URL      Your Jira base URL (e.g., https://yourcompany.atlassian.net)"
    opts.separator ""
    opts.separator "  Optional:"
    opts.separator "    JIRA_BOARD_ID      Default board ID (can be overridden with -b flag)"
    opts.separator "    SPRINT_PATTERN     Sprint name pattern with {year} and {quarter} placeholders"
    opts.separator "                       Default: \"Sprint {year}Q{quarter} #\""
    opts.separator "                       Example: \"Team Alpha {year}Q{quarter} #\""
    opts.separator ""
    opts.separator "Options:"

    opts.on("-b", "--board BOARD_ID", Integer, "Jira board ID (required if JIRA_BOARD_ID not set)") do |b|
      options[:board_id] = b
    end

    opts.on("-y", "--year YEAR", "Year (2-digit format, e.g., 25 for 2025). Required with -q") do |y|
      options[:year] = y
    end

    opts.on("-q", "--quarter QUARTER", Integer, "Quarter (1-4). Required with -y") do |q|
      options[:quarter] = q
    end

    opts.on("--show-inflated-stories", "Show potentially inflated stories (business_days > story_points * 10)") do
      options[:show_inflated_stories] = true
    end

    opts.on("--exclude-inflated-stories", "Exclude inflated stories from the main report") do
      options[:exclude_inflated_stories] = true
    end

    opts.on("-h", "--help", "Show this help message") do
      puts opts
      exit
    end

    opts.separator ""
    opts.separator "Examples:"
    opts.separator "  # Set required environment variables"
    opts.separator "  export JIRA_EMAIL=\"your@email.com\""
    opts.separator "  export JIRA_API_TOKEN=\"your_token_here\""
    opts.separator "  export JIRA_BASE_URL=\"https://yourcompany.atlassian.net\""
    opts.separator "  export JIRA_BOARD_ID=\"123\""
    opts.separator "  export SPRINT_PATTERN=\"Team Sprint {year}Q{quarter} #\""
    opts.separator ""
    opts.separator "  # Run analysis"
    opts.separator "  ruby analyze_sprint_cycle_time.rb -y 25 -q 4"
    opts.separator "  ruby analyze_sprint_cycle_time.rb -y 25 -q 4 --show-inflated-stories"
    opts.separator "  ruby analyze_sprint_cycle_time.rb -y 25 -q 4 --exclude-inflated-stories"
    opts.separator "  ruby analyze_sprint_cycle_time.rb -b 500 -y 24 -q 2  # Override board ID"
  end.parse!

  unless options[:year] && options[:quarter]
    puts "Error: Both --year and --quarter are required"
    puts "Run with --help for usage information"
    exit 1
  end

  analyzer = SprintCycleTimeAnalyzer.new(**options)
  analyzer.analyze
end
