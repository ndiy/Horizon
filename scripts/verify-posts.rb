#!/usr/bin/env ruby
# Refuse to publish when the collector's summaries and Jekyll posts disagree.
#
# For every "horizon-<date>-<lang>.md" summary there must be a matching
# "<date>-summary-<lang>.md" post whose body (front matter removed, leading H1
# stripped, both sides stripped) equals the summary body. A mismatch means either
# the collector failed to write its post or the post is stale, and publishing it
# would present old content as today's digest.

require 'optparse'

posts_dir = nil
summaries_dir = nil
OptionParser.new do |opts|
  opts.banner = 'Usage: verify-posts.rb --posts-dir PATH --summaries-dir PATH'
  opts.on('--posts-dir PATH') { |v| posts_dir = v }
  opts.on('--summaries-dir PATH') { |v| summaries_dir = v }
end.parse!

abort('error: --posts-dir and --summaries-dir are required') if posts_dir.nil? || summaries_dir.nil?
abort("error: posts dir not found: #{posts_dir}") unless File.directory?(posts_dir)
abort("error: summaries dir not found: #{summaries_dir}") unless File.directory?(summaries_dir)

SUMMARY_PATTERN = /\Ahorizon-(?<date>\d{4}-\d{2}-\d{2})-(?<lang>[A-Za-z]+)\.md\z/

# Jekyll front matter is a leading "---" block; posts are written as
# "---\n...\n---\n\n" followed by the summary body minus its first H1.
def post_body(text)
  unless text.start_with?("---\n")
    abort('error: post is missing its Jekyll front matter')
  end
  closing = text.index("\n---\n", 3)
  abort('error: post front matter is not terminated') if closing.nil?
  text[(closing + 5)..].to_s
end

def summary_body(text)
  stripped = text.strip
  return stripped unless stripped.start_with?('# ')
  remainder = stripped.split("\n", 2)[1]
  remainder.nil? ? '' : remainder.strip
end

errors = []
checked = 0

Dir.children(summaries_dir).sort.each do |name|
  match = SUMMARY_PATTERN.match(name)
  next if match.nil?

  checked += 1
  date = match[:date]
  lang = match[:lang]
  summary_path = File.join(summaries_dir, name)
  post_name = "#{date}-summary-#{lang}.md"
  post_path = File.join(posts_dir, post_name)

  if !File.file?(post_path)
    errors << "#{name}: no matching post #{post_name}"
    next
  end

  expected = summary_body(File.read(summary_path, encoding: 'UTF-8'))
  actual = post_body(File.read(post_path, encoding: 'UTF-8')).strip
  if expected != actual
    errors << "#{name}: post #{post_name} body does not match the summary"
  end
end

if errors.any?
  warn errors.join("\n")
  abort("error: #{errors.length} summary/post mismatch(es); refusing to publish")
end

puts "verified #{checked} summary/post pair(s)"
