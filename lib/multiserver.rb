require 'zlib'
require 'rack/request'
require 'rack/response'
require 'rack/utils'
require 'time'
require File.join(File.dirname(__FILE__), 'grack.rb')
require File.join(File.dirname(__FILE__), 'docserver.rb')
require 'erb'
require 'kramdown'
require 'coderay'
require 'coderay_bash'
require 'yaml'
require 'geminabox'

module Grack
  class Multiserver < Docserver
    def initialize config
      Geminabox.data = config[:geminabox][:data]
      super
    end

    def call(env)
      if env['PATH_INFO'][0, 5] == "/#{@config[:geminabox][:path]}/" 
        env['SCRIPT_NAME'] = app_root + @config[:geminabox][:path]
        env['PATH_INFO'] = env['PATH_INFO'][@config[:geminabox][:path].length + 1, env['PATH_INFO'].length]
        Geminabox.call(env)
      else
        super
      end
    end

  end
end
