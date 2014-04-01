$LOAD_PATH.unshift File.expand_path(File.dirname(__FILE__) + '/lib')

use Rack::ShowExceptions

require 'git_adapter'
require 'docserver'

config = Grack.load_config('config.yml')

run Grack::Docserver.new(config)
