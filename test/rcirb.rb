#!/usr/bin/env ruby
# Starts irb with $rc, a client of the node given (localhost_11211 by
# default), such as $rc.set('key', 'value') and $rc.get('key').

require 'irb'

$LOAD_PATH << File.expand_path('../lib', __dir__)

require 'roma/tools/text_client'

$rc = Roma::Tools::TextClient.new([ARGV.shift || 'localhost_11211'])

IRB.start
