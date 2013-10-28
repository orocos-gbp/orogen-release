begin
    require 'typelib'
rescue LoadError
    STDERR.puts "Cannot require 'typelib'"
    STDERR.puts "If you are using Rock, the 'typelib' package should have been installed automatically."
    STDERR.puts "First, make sure that you have loaded autoproj's env.sh script before continuing"
    STDERR.puts "Second, typelib should be installed in tools/typelib from the root of your Rock installation."
    STDERR.puts "If it is not the case, report this to the rock developers. To workaround, run"
    STDERR.puts "  amake typelib"
    STDERR.puts "and try again."
    exit 1
end

require 'logger'
require 'orogen/version'
require 'orogen/base'

require 'orogen/spec'
require 'orogen/gen'

Orocos.load_orogen_plugins
