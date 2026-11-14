#!/usr/bin/env ruby
# Print "title<TAB>href" for every entry in an Atom feed; exits non-zero if the
# document is not well-formed Atom.

require 'rexml/document'

path = ARGV[0] or abort('usage: feed-entries.rb <feed.xml>')
document = REXML::Document.new(File.read(path, encoding: 'UTF-8'))
root = document.root
abort("error: #{path} root is <#{root&.name}>, expected <feed>") unless root&.name == 'feed'

root.each_element('entry') do |entry|
  title = entry.elements['title']&.text.to_s.strip
  link = entry.elements['link']&.attributes&.[]('href').to_s
  puts "#{title}\t#{link}"
end
