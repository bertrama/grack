require 'zlib'
require 'rack/request'
require 'rack/response'
require 'rack/utils'
require 'time'
require File.join(File.dirname(__FILE__), 'grack.rb')
require 'erb'
require 'kramdown'
require 'coderay'
require 'coderay_bash'
require 'yaml'


module Grack
  def self.load_config file_name
    config = YAML.load_file file_name
    adapter = Object
    config[:adapter].split('::').each do |piece|
      adapter = adapter.const_get(piece)
    end
    config[:adapter] = adapter
    config
  end
    
  class Docserver < App 
    class Template
      def initialize p
        p.each_pair do |k,v|
          bind k, v
        end
      end

      def bind k, v
        instance_variable_set ('@' + k.to_s).to_sym, v
      end

      def get_binding
        binding
      end
    end
    
    SERVICES = Grack::App::SERVICES + [
      ["GET",  'get_file',         "^(.*\\.txt)$",  'text/plain'],
      ["GET",  'get_file',         "^(.*\\.css)$",  'text/css'],
      ["GET",  'get_file',         "^(.*\\.js)$",   'text/javascript'],
      ["GET",  'get_file',         "^(.*\\.eot)$",  'application/vnd.ms-fontobject'],
      ["GET",  'get_file',         "^(.*\\.ttf)$",  'application/octet-stream'],
      ["GET",  'get_file',         "^(.*\\.svg)$",  'image/svg+xml'],
      ["GET",  'get_file',         "^(.*\\.woff)$", 'application/font-woff'],
      ["GET",  'get_md',           "^(.*\\.md)$"],
      ["GET",  'get_catchall',     "^(.*)$"],
    ]

    def initialize(config = false)
      @semaphore = Mutex.new
      super
    end

    def call(env)
      @semaphore.synchronize do
        super
      end
    end

    def find_git_base path 
      if path === @config[:checkout_root] or path === '.' or path.length === 0
        false
      elsif File.directory? path
        candidate = File.join(path, '.git')
        if File.exists? candidate
          "http://#{@req.host}#{app_root}#{path[@config[:checkout_root].length, path.length]}"
        else
          find_git_base File.dirname(path)
        end
      else
        find_git_base File.dirname(path)
      end
    end

    def breadcrumbs path
       parts   = path[@config[:checkout_root].length, path.length].split('/')
       last = parts.pop
       crumbs  = []
       partial = []
       parts.each do |part|
         partial << part
         crumbs << "<a href=\"#{app_root}#{partial.join('/')}/\">#{part}</a>"
       end
       crumbs << last
       " / " + crumbs.join(" / ")
    end

    def erb path, params = {}
      tpl = get_template path
      params[:path]        ||= app_root
      params[:body]        ||= ''
      params[:title]       ||= "...title..."
      params[:assets]      ||= @config[:assets]
      params[:git_base]    ||= find_git_base path
      params[:nav_links]   ||= @config[:nav_links]
      params[:breadcrumbs] ||= breadcrumbs path
      b = Template.new params
      renderer = ERB.new(File.read(tpl))
      renderer.result(b.get_binding)
    end

    def trim_git_path p
      if p.index(@config[:project_root]) === 0
        p[@config[:project_root].length, p.length]
      else
        p
      end
    end

    def get_listing path
      ret = '<ul>'
      Dir.entries( @config[:checkout_root] + path).each do |entry|
        ret << link_dir_entry(entry, path)
      end
      ret << '</ul>'
    end

    def get_dir path, dir
      ret = '<ul>'
      Dir.entries( dir ).each do |entry|
        if entry === '.' or entry === '.git'
        elsif entry === '..'
          if path.length > 0
            ret << link_dir_entry(entry, File.dirname(path))
          end
        elsif path === ''
          ret << link_dir_entry(entry, entry)
        else
          ret << link_dir_entry(entry, File.join(path, entry))
        end
      end
      ret << '</ul>'
    end

    def get_file_body file
      IO.read file
    end

    def get_file
      type = @rpc || 'text/plain'
      path = trim_git_path dir
      file = @config[:checkout_root] + path
      if File.exists? file
        respond body: get_file_body(file), type: type 
      else
        render_not_found
      end
    end

    def get_template path
      candidate = File.join(path, @config[:template])
      if File.directory?(path) and File.exist?(candidate)
        candidate
      elsif path.length > 0
        get_template File.dirname(path)
      else
        @config[:template]
      end
    end


    def get_md
      path = trim_git_path dir
      file = @config[:checkout_root] + path
      if File.exists? file
        respond body: erb(file, body: Kramdown::Document.new(IO.read(file)).to_html, title: File.basename(file, '.md'))
      else
        render_not_found
      end
    end

    def get_catchall
      path = trim_git_path dir
      file = @config[:checkout_root] + path
      if File.directory? file
        if file[-1, 1] != '/'
          scheme = @req.scheme === 'https' ? 'https' : 'http'
          return redirect "#{scheme}://#{@req.host}#{app_root}#{path}/"
        elsif File.exist? File.join(file, 'index.md')
          self.dir = File.join(self.dir, 'index.md')
          return get_md
        else 
          body = erb(file, body: get_dir(path, file), title: "Browsing /#{path}")
        end
      elsif File.exists? file
        body = get_file_body file
      else
        body = "get_catchall"
      end
      respond body: body
    end

    def app_root
      ENV['APP_ROOT']
    end

    def link_dir_entry entry, path
      path = path + File::SEPARATOR if File.directory?(@config[:checkout_root] + path);
      "<li><a href=\"#{app_root + path}\">#{entry}</a></li>"
    end

    def redirect target, status = 301
      @res = Rack::Response.new
      @res.status = status.to_i
      @res['Location'] = target
      @res.body   = []
      @res.finish
    end

    def respond options = {}
      options[:status]  ||= 200
      options[:type]    ||= 'text/html'
      options[:body]    ||= ''
      @res = Rack::Response.new
      @res.status          = options[:status].to_i
      @res['Content-type'] = options[:type]
      @res.body            = [options[:body]]
      @res.finish
    end

    # We want to override this from the base class.
    def get_git_dir(path)
      root = get_project_root
      path = File.join(root, path)
      if !is_subpath(File.expand_path(path), File.expand_path(root))
        false
      else
        path
      end
    end

    #Inheritance doesn't re-resolve the SERVICES array
    def self.match_routing(req)
      cmd = nil
      path = nil
      SERVICES.each do |method, handler, match, rpc|
        if m = Regexp.new(match).match(req.path_info)
          return ['not_allowed'] if method != req.request_method
          cmd = handler
          path = m[1]
          file = req.path_info.sub(path + '/', '')
          return [cmd, path, file, rpc]
        end
      end
      return nil
    end
  end
end
