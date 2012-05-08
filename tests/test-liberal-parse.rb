#!/usr/bin/ruby -w

require 'liberal_uri'

def dump u
  return if u==nil

  puts " - scheme   '#{u.scheme}'"
  puts " - userinfo '#{u.userinfo}'"
  puts " - host     '#{u.host}'"
  puts " - port     '#{u.port}'"
  puts " - registry '#{u.registry}'"
  puts " - path     '#{u.path}'"
  puts " - opaque   '#{u.opaque}'"
  puts " - query    '#{u.query}'"
  puts " - fragment '#{u.fragment}'"
end


$stdin.each_line do |line|
  begin
    line.strip!
    u0 = URI.parse line
    u1 = URI.liberal_parse line

    raise "Mismatch on scheme" unless u0.scheme == u1.scheme
    raise "Mismatch on userinfo" unless u0.userinfo == u1.userinfo
    raise "Mismatch on host" unless u0.host == u1.host
    raise "Mismatch on port" unless u0.port == u1.port
    raise "Mismatch on path" unless u0.path == u1.path
    raise "Mismatch on query" unless u0.query == u1.query
    raise "Mismatch on fragment" unless u0.fragment == u1.fragment

  rescue Exception => e
    puts "While processing URL: '#{line}'"
    puts "Exception: #{e}"
    puts "u0:"
    dump(u0)
    puts "u1:"
    dump(u1)
    exit
  end
end


