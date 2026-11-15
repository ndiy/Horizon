#!/usr/bin/env ruby
# Refuse to publish a release whose internal links point at files it does not ship.
#
# The site is served from a directory listing of one release, so a link is live
# only if it resolves to a file inside that release. Jekyll happily emits markup
# for pages its config excludes, which is how three documentation links and an
# English feed link reached production as 404s; nothing about the build failed.
#
# Only internal references are checked: absolute URLs leave this service, and
# fragments/pseudo-schemes are not file lookups.

require 'cgi'
require 'set'

destination = ARGV[0] or abort('usage: check-site-links.rb <built-site-dir>')
abort("error: #{destination} is not a directory") unless File.directory?(destination)

SKIP_PREFIXES = ['http://', 'https://', '//', 'mailto:', 'tel:', 'data:', 'javascript:', 'irc:'].freeze
REF_PATTERN = /(?:href|src)\s*=\s*"([^"]*)"/i

def skip?(ref)
  ref.empty? || ref.start_with?('#') || SKIP_PREFIXES.any? { |p| ref.downcase.start_with?(p) }
end

# A page's URL is its path inside the release, so "/x/y.html" is a root-relative
# path while "x/y" is resolved against the page's own directory.
def resolve(page_url, ref)
  path = ref.split('#', 2).first.split('?', 2).first
  path = CGI.unescapeHTML(path)
  return File.join('/', path) if path.start_with?('/')
  File.join(File.dirname(page_url), path)
end

# A candidate exists if it is a file, or a directory with an index, or has an
# ".html" extension Jekyll would have produced for an extensionless link.
def exists?(root, url_path)
  candidates = [url_path, "#{url_path}.html"]
  candidates += ["#{url_path}/index.html"] if url_path != '/'
  candidates.any? do |candidate|
    full = File.join(root, candidate)
    File.file?(full)
  end
end

missing = []
pages = Dir.glob(File.join(destination, '**', '*.html'))

pages.sort.each do |page|
  text = File.read(page, encoding: 'UTF-8')
  page_url = '/' + page.delete_prefix("#{destination}/")
  text.scan(REF_PATTERN) do |(ref)|
    next if skip?(ref.strip)
    url_path = resolve(page_url, ref.strip)
    next if exists?(destination, url_path)
    missing << "#{page_url}: #{ref.strip}"
  end
end

if missing.any?
  warn missing.uniq.sort.join("\n")
  abort("error: #{missing.uniq.length} internal link(s) do not resolve inside the release; refusing to publish")
end

puts "verified #{pages.length} page(s) with no dead internal links"
