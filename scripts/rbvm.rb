require 'digest/md5'
require 'fileutils'
require 'open3'
require 'optparse'
require 'shellwords'
#require 'uri'
require 'yaml'
#require 'rubygems/commands/list_command'

class String
  def blank?; return !(self !~ /^\s*\z/m); end
end

class NilClass
  def blank?; true; end
end

class Rbvm
  attr_reader(
    :ruby_string, # ruby-1.9.2-p180
    :interpreter, # ruby
    :version, # 1.9.2
    :patchlevel, # 180
    :gemset, # my_gemset
    :ruby_home, # $HOME/.rbvm/rubies/ruby-1.9.2-p180
    :gem_home, # $HOME/.rbvm/gems/ruby-1.9.2-p180@my_gemset
    :global_gem_home, # $HOME/.rbvm/gems/ruby-1.9.2-p180@global
    :gem_base, # $HOME/.rbvm/gems/ruby-1.9.2-p180
    :gem_path, # $HOME/.rbvm/gems/ruby-1.9.2-p180@my_gemset:$HOME/.rbvm/gems/ruby-1.9.2-p180@global
    :path, # $PATH
    #:archive_name, # ruby-1.9.2-p180.tar.bz2
    :system_ruby
  )

  attr_accessor :env_output

  # if set_env is false, no environment variables are sent back to the shell to be set.
  def initialize(str = nil, existing = nil)

    @system_ruby = false
    self.env_output = {}
    str = get_alias(str)

    case str
    when 'system'
      @system_ruby = true
      return

    when '', nil
      if existing
        # find version from existing rubies
        @interpreter, @version, @patchlevel, @gemset =
          parse_ruby_string(get_existing_ruby(config_db("interpreter")))
      else
        @interpreter = config_db("interpreter")
        @version = config_db(interpreter, "version")
        @patchlevel = config_db(interpreter, version, "patchlevel")
      end

    else
      @interpreter, @version, @patchlevel, @gemset = parse_ruby_string(str)

      if interpreter.nil? && version
        case version
        when /^1\.(8\.[6-7]|9\.[1-3])$/
          @interpreter = "ruby"
        when /^1\.[3-6].*$/
          @interpreter = "jruby"
        when /^1\.[0-2]\.\d$/
          @interpreter = "rbx"
        when /^\d*$/
          @interpreter = "maglev"
        when /^0\.8|nightly$/
          @interpreter = "macruby"
        end
      elsif interpreter.nil? && version.nil?
        log("Ruby string not understood: #{str}", "debug")
      end

      if !interpreters.include?(interpreter)
        log("Invalid ruby interpreter: #{interpreter}", "debug")
      end

      if existing
        i, v, p, g = parse_ruby_string(get_existing_ruby(str))
        @version ||= v
        @patchlevel ||= p
      else
        @version ||= config_db(interpreter, "version")
        @patchlevel ||= config_db(interpreter, version, "patchlevel")
      end
    end

    # TODO use existing to pick suitable ruby if specified

    @ruby_string = "#{interpreter}"
    @ruby_string += "-#{version}" if version
    if patchlevel
      if interpreter == "ruby"
        @patchlevel.delete!('p')
        @ruby_string += "-p#{patchlevel}"
      else
        @ruby_string += "-#{patchlevel}"
      end
    end

    @ruby_home = File.join(env.path, "rubies", ruby_string)
    @gem_base = File.join(env.gems_path, ruby_string)
    if gemset
      @gem_home = "#{gem_base}#{env.gemset_separator}#{gemset}"
    else
      @gem_home = gem_base
    end
    @global_gem_home = "#{gem_base}#{env.gemset_separator}global"
    @gem_path = "#{gem_home}:#{global_gem_home}"

    # TODO why aren't some interpreters in config/known?
    if !known?
      log("Unknown ruby specification: #{str} -> #{ruby_string}. Proceeding...", "debug")
    end
    if !valid?
      reset
      @ruby_string = str
      log("Invalid ruby specificiation: #{str}", "debug")
      return
    elsif existing && !installed?
      reset
      @ruby_string = str
      log("No installed ruby with specificiation: #{str}", "debug")
      return
    end
  end

  def reset
    @ruby_string = @interpreter = @version = @patchlevel = @gemset = nil
    @ruby_home = @gem_home = @global_gem_home = @gem_base = @gem_path = @path = nil
    @system_ruby = false
    self.env_output = {}
  end

  def get_existing_ruby(str)
    Dir.chdir(File.join(env.path, 'rubies')) do
      return Dir["#{str}*"][-1]
    end
  end

  # parse string into [interpreter, version, (patchlevel, (gemset))].
  def parse_ruby_string(str)
    if str =~ /^(#{interpreters.join('|')})?-?(.*?)(?:-(.*?))?(?:#{env.gemset_separator}(.*))?$/
      interpreter = $1 if !$1.blank?
      version = $2 if !$2.blank?
      patchlevel = $3 if !$3.blank?
      gemset = $4 if !$4.blank?
    end

    return [interpreter, version, patchlevel, gemset]
  end

  def interpreters
    return [
      "ruby",
      'jruby',
      'rbx',
      'ree',
      'maglev',
      'mput',
      'macruby',
      'ironruby'
    ]
  end

  def ruby_string_with_gemset
    return "%s%s%s" % [ruby_string, env.gemset_separator, gemset] if gemset
    return ruby_string
  end

  def get_alias(str)
    return self.class.config_alias[str] || str
  end

  [:config_md5, :env, :options].each do |sym|
    define_method(sym) do
      return self.class.send(sym)
    end
  end

  def config_db(*args); self.class.config_db(*args); end

  def archive_name
    return @archive_name ||= eval(%Q{"#{config_db(interpreter, version, 'archive_name')}"})
  end

  def archive_url
    return @archive_url if @archive_url
    url = eval %Q{"#{config_db(interpreter, version, 'url')}"}
    url.concat("/") if url[-1] != "/"
    return @archive_url = url.concat(archive_name)
  end

  def src_path
    return @src_path ||= File.join(env.src_path, ruby_string)
  end

  def path
    return @path if @path
    if installed_and_working?
      @path = "#{gem_home}/bin:#{global_gem_home}/bin:#{ruby_home}/bin:#{clean_path(ENV['PATH'])}"
    else
      @path = clean_path(ENV['PATH'])
    end
    return @path
  end

  def exec_cmd(*cmds)
    if Hash === cmds.last
      opts = cmds.pop
    else
      opts = {}
    end

    if cmds[0].is_a?(Array)
      log_cmd = cmds.collect{|a| a.join(' ')}.join(' | ')
    else
      log_cmd = cmds.join(' ')
    end
    log(log_cmd)

    if opts.delete(:pipeline)
      out_r, out_w = IO.pipe
      err_r, err_w = IO.pipe

      opts = {:out => out_w, :err => err_w}.merge(opts)
      statuses = Open3.pipeline(*cmds, opts)

      out_w.close
      output = out_r.read
      out_r.close

      err_w.close
      error = err_r.read
      err_r.close

      # if the pipe fails, might not return an exitstatus
      exiterror = !statuses.index{|status| (status.exitstatus || 1) > 0 }.nil?
    else
      output, error, status = Open3.capture3(*cmds, opts)
      exiterror = status.exitstatus > 0
    end

    log(output) if !output.empty?
    log(error, "warn") if !error.empty?
    raise "`#{log_cmd}': #{error}" if exiterror
    return output
  end

  def catch_error(err_msg = nil)
    if !block_given?
      $stderr.puts "rbvm.rb ERROR! You need to provide a block to execute!"
      raise
    end
    begin
      output = yield
    rescue Exception => e
      log(e.message, "error") if e.message
      log(e.backtrace.join("\n"), "debug")
      log(err_msg, "error") if err_msg
      raise e
    end
    return output
  end #catch_error()

  # Takes a hash of names => values, and a block with a shell command
  # It sets each variable as an environment variable: ENV["key"] = value
  # The environment variables are then unset before exiting.
  # Previous env variables are preserved.
  #def with_env(*vars, &block)
  def with_env(vars) #, &block)
    return if !block_given?
    #vars.each {|v| ENV[v] = eval(v, block.binding)}
    temp = {}
    vars.each do |k, v|
      temp[k.to_s] = ENV[k.to_s]
      ENV[k.to_s] = v
    end
    output = yield
    vars.each do |k,v|
      if temp[k.to_s] 
        ENV[k.to_s] = temp[k.to_s]
      else
        ENV.delete(k.to_s)
      end
    end
    return output
  end

  def exec_cmd_with_current_env(*cmd, environment)
    catch_error do
      temp_env = {GEM_HOME: gem_home, PATH: path, GEM_PATH: gem_path}.merge(environment.dup)
      with_env(temp_env) do
        exec_cmd(*cmd)
      end
    end
  end

  def log(message, level = "debug")
    self.class.log(message, level)
  end #log()

  def print_info(*args)
    with_env(GEM_HOME: gem_home, PATH: path, GEM_PATH: gem_path) do
      version_string = exec_cmd("ruby", "-v").chomp
      version_string =~ /^(\w*?)\s(.*?)\s\(((.*?)\s.*)\)\s\[(.*)\]$/
      local_interpreter = $1
      local_version = $2
      local_patchlevel = $3
      local_date = $4
      local_platform = $5
      vars = {
        ruby_string: ruby_string || 'system',
        system: {
          uname: exec_cmd('uname', '-a').chomp,
          bash: "#{exec_cmd('which', 'bash').chomp} => #{bash = exec_cmd('bash', '--version'); bash =~ /^.*$/; $&}",
          zsh: "#{exec_cmd('which', 'zsh').chomp} => #{exec_cmd('zsh', '--version').chomp}"
        },
        rbvm: { version: self.class.get_version_line },
        rbvm_env: env,
        ruby: {
          interpreter: local_interpreter,
          version: local_version,
          date: local_date,
          platform: local_platform,
          patchlevel: local_patchlevel,
          full_version: version_string
        },
        homes: { gem: gem_home, ruby: ruby_home },
        binaries: {
          ruby: exec_cmd('which', 'ruby').chomp,
          irb: exec_cmd('which', 'irb').chomp,
          gem: exec_cmd('which', 'gem').chomp,
          rake: exec_cmd('which', 'rake').chomp
        },
        environment: {
          PATH: ENV['PATH'],
          GEM_HOME: ENV['GEM_HOME'],
          GEM_PATH: ENV['GEM_PATH'],
          MY_RUBY_HOME: ENV['MY_RUBY_HOME'],
          IRBRC: ENV['IRBRC'],
          RUBYOPT: ENV['RUBYOPT'],
          gemset: gemset
        }
      }

      if args.empty?
        print_hash = ->(h, l = 1) do
          h.each do |k,v|
            if Hash === v
              $shellout.puts "#{"  "*l}#{k}:"
              print_hash[v, l+1]
              $shellout.puts 
              next
            end
            k = "#{k}:".ljust(25-l*2)
            $shellout.puts "#{"  "*l}#{k}#{v}"
          end
        end
        print_hash[vars]
      else # args.empty?
        args.each do |arg|
          value = vars
          arg.split('.').each do |key|
            if !value.key? key.to_sym
              $stderr.puts "Invalid key: use <key.key>"
              return
            end
            value = value[key.to_sym]
          end
          $shellout.puts value
        end
      end # args.empty
    end #with_env do
    return
  end

  def actual_file(file)
    if File.symlink?(file)
      return exec_cmd("readlink", '-n', file).strip
    end
    return file
  end

  #def wrap_binary(path, binary, prefix = nil)
    #if !File.exists?(File.join(ruby_home, "bin", binary))
      #log("Binary '#{binary}' not found.", "error")
      #return
    #end

    ## remove the existing wrapper if it exists
    #if File.exists?(File.join(path, binary))
      ##exec_cmd(%[rm -f #{File.join(path, binary)}])
      #FileUtils.rm_f(File.join(path, binary))
    #end

    ## make sure the wrapper path exists
    #catch_error("Could not create path #{path}.") do
      #exec_cmd("mkdir -p #{path.shellescape}")
    #end

    #File.open(File.join(path, "#{prefix}#{binary}")) do |f|
      #f.puts <<EOF
##!/usr/bin/env bash

#if [[ -s "#{env.home}/environments/#{ruby_string}" ]] ; then
  #source "#{env.home}/environments/#{ruby_string}"
  #exec #{binary} "$@"
#else
  #echo "ERROR: Missing RVM environment file: '#{env.home}/environments/#{ruby_string}'" >&2
  #exit 1
#fi
#EOF
    #end #File.open do

    #exec_cmd(%[chmod +x #{File.join(path, "#{prefix}#{binary}").shellescape}])
  #end


  # prefix must be fixed before calling
  #def wrapper(prefix = nil, *binaries)
    ## Default list of binaries
    #if binaries.empty?
      #binaries = default_binaries()
    #end

    ## load environment
    ## Do these need to happen?
    ## rbvm_select()
    ## rbvm_use()
    
    ## verify environment files exist
    #ensure_has_environment_files()

    #binaries.each do |binary|
      #wrapper_path = File.join(env.path, "wrappers", ruby_string)

      ## check bin path exists
      #if !File.directory?(File.join(env.home, "bin"))
        #exec_cmd(%[mkdir -p "#{File.join(env.home, "bin").shellescape}"])
      #end

      ## create default symlink if requested
      #if self.class.options[:default]

      #end

      #wrap_binary(wrapper_path, binary, prefix)
      
      ##symlink
      #if binary == "ruby"
        #destination = "#{env.home}/bin/#{ruby_string}"
      #else
        #destination = "#{env.home}/bin/#{binary}-#{ruby_string}"
      #end

      ##exec_cmd(%[rm -f #{destination}])
      #FileUtils.rm_f(destination)
      #exec_cmd(%[ln -nsf #{wrapper_path}/#{prefix}#{binary} #{destination}])

    #end #do |binary|
    
  #end

  def dummy_def
  end

  def create_alias(name)
    raise "Invalid ruby" if !installed_and_working?
    aliases = self.class.config_alias
    if temp = aliases[name]
      log("Alias already exists: #{name} = #{temp}, overwriting.", "warn")
      aliases[name] = ruby_string
      File.open(File.join(env.path, 'config', 'alias'), 'w') do |f|
        aliases.each {|k,v| f.puts("#{k}=#{v}") }
      end
    else
      log("Adding new alias: #{name} = #{ruby_string}", "info")
      File.open(File.join(env.path, 'config', 'alias'), 'a') do |f|
        f.puts("#{name}=#{ruby_string}")
      end
    end
    # TODO create alias symlinks for rubies
    return
  end

  def valid?
    return !interpreter.blank? && !version.blank?
  end

  def installed?
    return valid? && !ruby_home.blank? && File.directory?(ruby_home)
  end
  
  def installed_and_working?
    return installed? && !gem_home.blank? && File.directory?(gem_home)
  end

  def known?
    return config_md5.keys.include?(archive_name)
  end

  def gemset_exists?
    return installed_and_working? && !gemset.blank?
    #if gemset.nil? || gemset.empty?
      #log("No gemset name specified", "error")
      #return false
    #end

    #if !File.directory?(gem_home)
      #log("Gemset directory does not exist: #{gem_home}", "error")
      #return false
    #end

    #return true
  end

  def create_gemset(gemset_name = nil)
    raise "Invalid ruby" if !installed?
    if gemset.nil? && gemset_name.nil?
      log("No gemset name specified", "warn")
      #raise "No gemset name specified, aborting."
    end

    local_gem_home = gemset_name ? "#{gem_home}#{env.gemset_separator}#{gemset_name}" : gem_home

    if !ruby_home || !File.directory?(ruby_home)
      log("Ruby version for gemset does not exist: #{ruby_string}", "error")
      raise "Ruby version for gemset does not exist: #{ruby_string}, aborting."
    end

    log("Creating gemset directory: #{local_gem_home}", "info")
    if File.directory?(local_gem_home)
      log("Gemset directory already exists: #{local_gem_home}", "warn")
    else
      Dir.mkdir(local_gem_home)
    end

    ["specifications", "cache"].each do |subdir|
      Dir.mkdir("#{local_gem_home}/#{subdir}") if !File.directory?("#{local_gem_home}/#{subdir}")
    end
    return
  end

  def delete_gemset
    if gemset_exists?
      log("Removing gemset: #{ruby_string_with_gemset}", "info")
      FileUtils.rm_rf(gem_home)
    else
      log("No gemset name with that name exists: #{ruby_string_with_gemset}. Cannot delete gemset.", "error")
      raise "No gemset name with that name exists: #{ruby_string_with_gemset}. Cannot delete gemset."
    end
  end

  def rename_gemset(rbvm_dest)
    if gemset_exists?
      rbvm_dest = Rbvm.new(rbvm_dest) if String === rbvm_dest
      if rbvm_dest.gemset.blank?
        log("Destination gemset not specified: #{rbvm_dest.ruby_string_with_gemset}", "error")
        raise "Gemset not renamed!"
      end
      if rbvm_dest.ruby_string == ruby_string
        log("Renaming gemset: #{ruby_string_with_gemset} to #{rbvm_dest.ruby_string_with_gemset}", "info")
        File.rename(gem_home, rbvm_dest.gem_home)
      else
        log("The new gemset name needs to have the same ruby interpreter, version, and patchlevel: #{ruby_string} differs from #{rbvm_dest.ruby_string}", "error")
        raise "New gemset rename requires the same ruby interpreter."
      end
    else
      log "No gemset specified: #{ruby_string}", "error"
      raise "No gemset specified: #{ruby_string}"
    end
    return
  end
  
  def copy_gemset(rbvm_dest)
    if installed_and_working?
      rbvm_dest = Rbvm.new(rbvm_dest) if String === rbvm_dest
      if !rbvm_dest.gemset
        log("Destination gemset not specified: #{rbvm_dest.ruby_string_with_gemset}", "error")
        raise "Gemset not copied!"
      end
      if !rbvm_dest.ruby_string == ruby_string
        log("The new gemset has a different ruby interpreter, version, or patchlevel: #{ruby_string} differs from #{rbvm_dest.ruby_string}. Some of the gems might not work.", "warn")
      end
      log("Renaming gemset: #{ruby_string_with_gemset} to #{rbvm_dest.ruby_string_with_gemset}", "info")
      FileUtils.cp_r(gem_home, rbvm_dest.gem_home, preserve: true)
      all_gems_str = with_env(GEM_HOME: rbvm_dest.gem_home, PATH: rbvm_dest.path, GEM_PATH: rbvm_dest.gem_home) do
        # TODO use Gem::Commands::PristineCommand.new.execute
        exec_cmd("gem", "pristine", "--all")
      end
    else
      log "No gemset specified: #{ruby_string}", "error"
      raise "No gemset specified: #{ruby_string}"
    end
    return
  end

  def list_gemsets
    self.class.list_gemsets(ruby_string, gemset)
    return
  end

  def export_gemset
    if !installed_and_working?
      log("No gemset folder exists at: #{gem_home}.", "error")
      raise "No gemset folder exists at: #{gem_home}."
    end
    all_gems_str = with_env(GEM_HOME: gem_home, PATH: path, GEM_PATH: gem_home) do
      exec_cmd("gem", "list")
      # TODO use Gem::Commands::ListCommand.new.execute and capute the IO. much faster.
    end
    $shellout.puts "# Exported gemset file. Note that any env variable settings will be missing. Append these after using a ';' field separator"
    all_gems_str.split("\n").each do |str|
      next if str.blank? || str =~ /^\*\*\* LOCAL GEMS \*\*\*/
      str =~ /^(.+?)\s\(([^,\)]+)(,|\))/
      $shellout.puts "#{$1} -v#{$2}"
    end
    return
  end

  #def parse_gem_name(str)
    ## parse str (name [--version=X.X.X | -vX.X] [--other] [--options])
    ## prefix: any required environment variables for the gem are listed after `;'
    #name, prefix = str.strip.split(";")
    #h = {name: name, prefix: prefix}

    ## check for gem file in cache or if gem is a gem file name
    #if name.blank?
      #log("No gem name given!", "error")
      #return
    #elsif name =~ /.gem$/ || File.exists?(name)
      #return h.merge({file_name: name})
    #elsif name =~ /^\S+/
      #h[:name] = $&
      #if "#{$`}#{$'}" =~ /(?:--version\=|-v\=?)\s*(\S+)/
        #h[:version] = $1
        #h[:file_name] = "#{name}-#{version}.gem"
      #else
        #h[:file_name] = "#{name}.gem"
      #end
      #postfix = "#{$`}#{$'}"
      #h[:postfix] = postfix if !postfix.blank?
      #return h
    #else
      #log("Invalid gem name: #{str}", "error")
      #return
    #end
  #end

  def gem_install(gem_string, global = false)
    raise "Invalid ruby" if !installed_and_working?
    # parse gem_string (name [--version=X.X.X | -vX.X] [--other] [--options])
    # gem_prefix: any required environment variables for the gem are listed after `;'
    gem, gem_prefix = gem_string.strip.split(";")

    local_gem_home = (global ? global_gem_home : gem_home)

    # check for gem file in cache or if gem is a gem file name
    if gem.blank?
      log("No gem name given!", "error")
      return
    elsif gem =~ /.gem$/ || File.exists?(gem)
      gem_file_name = gem
      gem_name = nil
      gem_version = nil
      gem_postfix = nil
    elsif gem =~ /^\S+/
      gem_name = $&
      if "#{$`}#{$'}" =~ /(?:--version\=|-v\=?)\s*(\S+)/
        gem_version = $1
        gem_file_name = "#{gem_name}-#{gem_version}.gem"
      else
        gem_version = nil
        gem_file_name = "#{gem_name}.gem"
      end
      gem_postfix = "#{$`}#{$'}"
      gem_postfix = nil if gem_postfix.blank?
    else
      log("Invalid gem name: #{gem_string}", "error")
      return
    end

    # check if the gem is already installed
    #if !options[:force] && File.exists?("#{gem_home}/specifications/#{gem_file_name}spec")
    if !global && !Dir["#{gem_home}/specifications/#{gem_name}-#{gem_version || '*'}.gemspec"].empty?
      if options[:force]
        log("#{gem_name} #{gem_version} exists in #{gem_home}, forcing re-install", "info")
      else
        log("#{gem_name} #{gem_version} exists in #{gem_home}, skipping (--force to re-install)", "info")
        return
      end
    elsif !Dir["#{global_gem_home}/specifications/#{gem_name}-#{gem_version || '*'}.gemspec"].empty?
      if options[:force]
        log("#{gem_name} #{gem_version} exists in #{global_gem_home}, forcing re-install", "info")
      else
        log("#{gem_name} #{gem_version} exists in #{global_gem_home}, skipping (--force to re-install)", "info")
        return
      end
    # check if there is a cached gem file somewhere
    elsif File.exists?(s = File.join(env.gems_cache_path, gem_file_name))
      cache_file = s
    elsif File.exists?(s = File.join(gem_home, "cache", gem_file_name))
      cache_file = s
    elsif File.exists?(s = File.join(global_gem_home, "cache", gem_file_name))
      cache_file = s
    elsif File.exists?(gem_file_name)
      cache_file = gem_file_name
    else # no cached file
      cache_file = nil
    end

    gem_prefix = gem_prefix + ' ' if !gem_prefix.blank?
    #command = ["#{gem_prefix}#{ruby_home}/bin/ruby", "#{ruby_home}/bin/gem", 'install']
    command = ["#{ruby_home}/bin/gem", 'install']
    if cache_file
      command << cache_file
    else
      command << gem_name
      command << "--version=#{gem_version}" if !gem_version.blank?
    end
    command << gem_postfix if !gem_postfix.blank?

    with_env(
      'GEM_HOME' => local_gem_home,
      'GEM_PATH' => '',
      'RUBYOPT' => ''
    ) do
      exec_cmd(*command)
    end
  end #def gem_install

  def gemset_import(file, global = false)
    raise "Invalid ruby" if !installed_and_working?
    log("Importing gemset: #{file}")

    local_gem_home = global ? global_gem_home : gem_home
    File.open(file) do |f|
      while (line = f.gets)
        gem_install(line, global)
      end
    end
  end # def gemset_import

  def install_default_gems()
    raise "Invalid ruby" if !installed?
    log("Importing initial gems for #{ruby_string}", "info")

    create_gemset
    create_gemset('global')

    # check for .gems files in gemset directories
    [env.gemsets_path, interpreter, version, patchlevel].inject('') do |path, str|
      path += str
      break path if !File.directory?(path)
      if File.exists?(file = "#{path}/global.gems")
        gemset_import(file, true)
      end
      if gemset && File.exists?(file = "#{path}/#{gemset}.gems")
        gemset_import(file)
      elsif File.exists?(file = "#{path}/default.gems")
        gemset_import(file)
      end
      path
    end
    return
  end #def gemset_initial
  
  def install_rubygems
    raise "Invalid ruby: #{ruby_home}" if !installed?

    if interpreter == "ruby" #&& version[0..2] == '1.8'
      rg_version = config_db('rubygems', 'version')
      rg_name = "rubygems-#{rg_version}"
      rg_url = config_db("rubygems", rg_version, "url")
      rg_url.concat('/') if rg_url[-1] != '/'
      rg_url.concat "#{rg_name}.tgz"
      setup_file = File.join(env.src_path, rg_name, "setup.rb")
      if File.exists?(setup_file)
        FileUtils.rm_rf(File.join(env.src_path, rg_name))
      end
      extract_archive(fetch_file(rg_url))
      catch_error("Failed to install rubygems.") do
        with_env('GEM_HOME' => gem_home, 'GEM_PATH' => gem_path, 'RUBYOPT' => '') do
          exec_cmd("#{ruby_home}/bin/ruby", setup_file, chdir: File.join(env.src_path, rg_name))
          exec_cmd("#{ruby_home}/bin/ruby", "#{ruby_home}/bin/gem", "update", "--system")
        end
      end
    end
    return
  end

  def inject_gem_env(file)
    raise "Invalid ruby" if !installed?
    #return false if !File.exists?(file)
    raise "`#{file}' does not exist." if !File.exists?(file)

    file_first_line, file_second_line, file_rest, string = nil
    File.open(file) do |f| 
      file_first_line = f.readline
      file_second_line = f.readline
      if file_first_line =~ /#!.*j?ruby/
        file_first_line = "#!#{File.join(ruby_home, 'bin', 'ruby')}\n" if file_first_line !~ /jruby/
        string = "ENV['GEM_HOME']||='#{gem_home}'\nENV['GEM_PATH']||='#{gem_path}'\nENV['BUNDLE_PATH']||='#{gem_home}'"
        return if string.start_with?(file_second_line)
        file_rest = f.read
      elsif file_first_line =~ /#!.*bash/
        string = "GEM_HOME=${GEM_HOME:-'#{gem_home}'}\nGEM_PATH=${GEM_PATH:-'#{gem_path}'}\nBUNDLE_PATH=${BUNDLE_PATH:-'#{gem_home}'}"
        return if string.start_with?(file_second_line)
        file_rest = f.read
      end
    end

    if string
      File.open(file, "w") do |f|
        f.write(file_first_line)
        f.puts(string)
        f.write(file_second_line)
        f.write(file_rest)
      end
    end
    return
  end

  def inject_scripts_gem_env
    raise "Invalid ruby" if !installed?

    case interpreter
    when "ruby", "jruby"
      %w(gem erb irb rake rdoc ri testrb).each do |binary|
        log("#{ruby_string} - adjusting #shebangs for #{binary}", "info")
        if !File.exists?("#{ruby_home}/bin/#{binary}")
          if File.exists?(temp = "#{src_path}/bin/#{binary}")
            FileUtils.cp(temp, "#{ruby_home}/bin/#{binary}")
          elsif File.exists?(temp = "#{env.gems_path}/#{ruby_string}/bin/#{binary}")
            FileUtils.cp(temp, "#{ruby_home}/bin/#{binary}")
          else
            next
          end
        end #if
        real_file = actual_file(File.join(ruby_home, 'bin', binary))
        inject_gem_env(real_file)
        exec_cmd("chmod", "+x", real_file)
      end #each do |binary|
    end
  end

  def fetch
    raise "Invalid ruby" if !valid?

    fetch_file(archive_url)
    return
  end

  # Download the file at url to $rbvm_path/archives/
  def fetch_file(url)
    url =~ %r{/([^/]*)\.(tar\.gz|tar\.bz2|tgz|zip|tbz)$}
    name = $1
    ext = $2
    filename = "#{name}.#{ext}"
    archive = File.join(env.path, "archives", filename)

    rbvm_md5 = config_md5[filename]

    if File.exists?(archive)
      archive_md5 = Digest::MD5.file(archive)
      if rbvm_md5
        if archive_md5.to_s == rbvm_md5
          log("Using existing archive for #{filename}.", "info")
          fetch = false
        else
          log("Existing archive has bad MD5, backup and download again.", "error")
          FileUtils.mv(archive, File.join(env.path, "archives", "#{filename}-#{Time.now.strftime("%Y%m%d%H%M%S")}.orig"))
          archive_md5 = nil
          fetch = true
        end
      else
        log("Unknown archive: #{archive}", "warn")
        fetch = false
      end
    else
      fetch = true
    end

    if fetch
      catch_error("Failed to fetch: #{url}") do
        log("#{name} - #fetching", 'info')
        exec_cmd("curl", "-s", "-S", "-L", "--create-dirs", "-C", "-", "-o", archive, url)
      end
    end

    return archive
  end

  def extract
    raise "Invalid ruby" if !valid?

    archive = File.join(env.path, 'archives', archive_name)
    extract_archive(archive, src_path)
  end

  def extract_archive(archive, src_dir = nil)
    filename = File.basename(archive)
    filename =~ /(.*)\.(tar\.gz|tar\.bz2|tgz|zip|tbz)$/
    name = $1
    ext = $2
    src_dir ||= File.join(env.src_path, name)

    if File.directory?(src_dir)
      if options[:force]
        log("--force specified. Removing existing src: #{src_dir}", 'warn')
        FileUtils.rm_rf(src_dir)
      else
        log("Src directory exists: #{src_dir}", "warn")
        log("Use --force to overwrite.", "warn")
        #raise "Src directory exists: #{src_dir}. Aborting."
        return
      end
    end

    # check md5
    if rbvm_md5 = config_md5[filename]
      archive_md5 = Digest::MD5.file(archive)
      if archive_md5 != rbvm_md5
        log("MD5 does not match for: #{archive}\n#{rbvm_md5} = config/md5 #{filename}\n#{archive_md5} = `md5 #{archive}'", "warn")
        #raise "MD5 does not match for: #{archive}. Aborting."
      end
    else
      log("No MD5 for: #{archive}", "warn")
    end

    while File.exists?(temp_dir = File.join(env.src_path, "#{ruby_string}_rbvm_fetch_tmp_#{Time.now.strftime("%Y%m%d%H%M%S")}#{rand(1000).to_s.rjust(3, "0")}"))
    end
    Dir.mkdir(temp_dir)

    catch_error("Failed to extract archive: #{archive}") do
      case ext
      when 'tar.gz', 'tgz'
        # --strip-components 1
        exec_cmd(["gunzip", "-c", archive], ["tar", "-x", "-f", "-", "-C", temp_dir], :pipeline => true)
      when 'tar.bz2'
        exec_cmd(["bunzip2", "-c", archive], ["tar", "-x", "-f", "-", "-C", temp_dir], :pipeline => true)
      when 'zip'
        exec_cmd("unzip", "-q", "-o", archive, "-d", temp_dir)
      else
        raise "Unknown file extension."
      end
    end
    
    if (new_temp_dir = Dir[File.join(temp_dir, '*')]).size == 1 && File.directory?(new_temp_dir[0])
      File.rename(new_temp_dir[0], src_dir)
      Dir.rmdir(temp_dir)
    elsif new_temp_dir.size > 1
      File.rename(temp_dir, src_dir)
    else
      log("No files extracted from: #{filename} - Check: #{temp_dir}", "error")
      raise "No files? Check: #{temp_dir}"
    end
    return
  end

  def configure
    raise "Invalid ruby" if !valid?

    log("#{ruby_string} - #configuring", 'info')

    if !File.directory?(src_path)
      log("Source directory is missing. Did the download or extraction fail? Halting the installation.", "error")
      raise "Source directory is missing. Did the download or extraction fail? Halting the installation."
    end

    if interpreter == 'jruby' && version !~ /^1\.[23]/
      catch_error("There was an error configuring nailgun.") do
        exec_cmd("./configure", "--prefix=#{ruby_home}", chdir: File.join(src_path, "tool", "nailgun"))
      end
    elsif interpreter == 'ruby' || interpreter == 'rbx'

      if self.class.options[:head] && !check_for_bison()
        log("You specified ruby-head. Bison is required to build it.", "error")
        raise "You specified ruby-head. Bison is required to build it."
      end

      #config_log = File.join(src_path, "config.log")

      #if File.exists?(config_log)
        #if !options[:force]
          #log("Source already ./configure'd.", "warn")
          #return
        #else
          #log("Source already ./configure'd. Proceeding with ./configure anyway...", "error")
          #prev_configure_options = File.open(config_log) do |f|
            #while line = f.readline
              #break $1.shellsplit if line.chomp =~ %r%^[\s$]*\./configure\s*(.*)$%
            #end #while
            #nil
          #end #File.open do
        #end
      #end

      # if no configure exists, use autoconf
      if !File.exists?(File.join(src_path, 'configure'))
        log("Running autoconf", 'info')
        catch_error("There was an error running autoconf. rbvm requires autoconf to install the selected ruby interpreter. Is autoconf installed?") do
          exec_cmd("autoconf", :chdir => src_path)
        end
      end

      # if a custom configure command is given, use it
      if env[:ruby_configure]
        cmd = [env.ruby_configure]
      else
        flags = [options[:configure], env.configure_flags,
          config_db(interpreter, version, 'configure_flags')
        ].inject([]) do |m, tmp_flags|
          m.concat(tmp_flags.split(',').collect{|flag| flag.strip}) if !tmp_flags.blank?
          m
        end

        # Add --with-baseruby for 1.9.2; path to compatible ruby 1.8
        flags << "--with-baseruby=#{env.path}/internal_ruby/bin/ruby" if ruby_string == "ruby-1.9.2-head"
        flags << "--disable-install-doc" if interpreter == "ruby"
        flags.select!{|flag| !flag.blank? }
        flags.uniq!

        cmd = ["./configure", "--prefix=#{ruby_home}", *flags]
      end # if

      catch_error("There was an error running configure. Halting the installation.") do
        exec_cmd(*cmd, chdir: src_path)
      end
    end
  end

  def build
    raise "Invalid ruby" if !valid?

    log("#{ruby_string} - #compiling", 'info')
    
    if interpreter == 'rbx'
      return
    elsif interpreter == 'jruby'
      if File.exists?(File.join(src_path, "build.xml"))
        catch_error("There was an error running ant to build jruby. Halting the installation.") do
          exec_cmd('ant', chdir: src_path)
        end
        catch_error("There was an error running ant to build jruby. Halting the installation.") do
          exec_cmd('ant', 'build-ng', chdir: src_path)
        end
      else
        catch_error("There was an error making nailgun. Halting the installation.") do
          cmd = ['make']
          cmd.concat(env.make_flags.shellsplit) if !env.make_flags.blank?
          exec_cmd(*cmd, chdir: File.join(src_path, 'tool', 'nailgun'))
        end
      end
    else
      cmd = env.ruby_make ? env.ruby_make.shellsplit : ['make']
      cmd << env.make_flags if !env.make_flags.blank?

      catch_error("There was an error running make. Halting the installation.") do
        exec_cmd(*cmd, :chdir => src_path)
      end
    end
  end

  def install
    raise "Invalid ruby" if !valid?

    log("#{ruby_string} - #installing", 'info')
    log("Installing #{ruby_string} to: #{ruby_home}", 'info')
    
    if options[:force] && File.directory?(ruby_home)
      log("--force specified; removing installed ruby: #{ruby_home}.", "warn")
      FileUtils.rm_rf(ruby_home) 
    end # if

    # apply_patches
    #catch_error("There was an error applying the specified patches. Halting the installation.") do
      #apply_patches()
    #end
    
    if interpreter == 'jruby'
      FileUtils.cp_r(src_path, ruby_home, :preserve => true)
      #Dir[File.join(ruby_home, 'bin', '*')].each do |file|
        #exec_cmd("chmod", "+x", file)
      #end
      Dir.chdir(File.join(ruby_home, 'bin')) do
        src = File.join(ruby_home, 'bin', "jruby")
        dest = File.join(ruby_home, 'bin', 'ruby')
        FileUtils.ln_s('jruby', 'ruby') if !File.exists?('ruby')
        %w(gem erb irb rake rdoc ri testrb).each do |file|
          FileUtils.mv(file, "j#{file}") if File.exists?(file)
          File.open(file, 'w') do |f|
            f.puts "#!/bin/sh\n#{ruby_home}/bin/jruby #{ruby_home}/bin/j#{file} $*"
          end
          FileUtils.chmod(0755, file)
        end
      end
    else
      FileUtils.rm_rf('.ext/rdoc') if Dir.exists?(".ext/rdoc")
    
      if interpreter == 'rbx'
        cmd = ["#{env.path}/internal_ruby/bin/rake", "install"]
      else
        cmd = env.ruby_make_install ? env.ruby_make_install.shellsplit : ['make', 'install']
      end

      catch_error("There was an error installing. Halting the installation.") do
        exec_cmd(*cmd, :chdir => src_path)
      end
    end

    log("Install of #{ruby_string} - #complete", 'info')

    return
  end

  def upgrade(dest)
  end

  def uninstall(src = false)
    raise "Invalid ruby" if !valid?

    FileUtils.rm_rf(ruby_home)

    # Remove all gems and gemsets for the specified ruby
    Dir["#{gem_base}*"].each do |dir|
      FileUtils.rm_rf(dir)
    end

    Dir[File.join(env.path, "wrappers", "#{ruby_string}*")].each do |dir|
      FileUtils.rm_rf(dir)
    end

    FileUtils.rm_rf(File.join(env.path, "environments", ruby_string))

    if src
      FileUtils.rm_rf File.join(src_path)
    end
  end

  def clean_path(path)
    self.class.clean_path(path)
  end

  def use
    if !installed_and_working?
      if !system_ruby
        log("No ruby installed with that specification: #{ruby_string}", "warn")
      end
      log("Resetting system ruby", "warn")
      self.env_output['rbvm_ruby_specification'] = ''
      self.env_output['GEM_HOME'] = ENV['rbvm_sys_gem_home']
      self.env_output['GEM_PATH'] = ENV['rbvm_sys_gem_path']
      self.env_output['PATH'] = clean_path(ENV['PATH'])
      print_env
    else
      self.env_output['rbvm_ruby_specification'] = ruby_string_with_gemset
      self.env_output['GEM_HOME'] = gem_home
      self.env_output['GEM_PATH'] = gem_path
      self.env_output['PATH'] = path
      print_env
    end
    log("Using: #{ruby_string_with_gemset}", "info")
    return
  end

  def print_env
    if options[:csh]
      env_output.each do |k,v|
        $envout.puts(v.blank? ? "unsetenv #{k};" : "setenv #{k} #{v.shellescape};")
      end
    else
      env_output.each do |k,v|
        $envout.puts(v.blank? ? "unset #{k};" : "export #{k}=#{v.shellescape};")
      end
    end
  end


  #######################
  # Check / validation methods
  #######################

  def check_for_clang()
    catch_error("You passed the --clang option and clang is not in your path. \nPlease try again or do not use --clang.") do
      exec_cmd(%[command -v clang])
    end
    return true
  end


  def check_for_bison()
    catch_error("bison is not available in your path. \nPlease ensure bison is installed before compiling from head.") do
      exec_cmd(%[command -v bison])
    end
    return true
  end


  # check if there is an existing ruby 1.8 to use for install
  #def ensure_has_18_compat_ruby()
    #return @ruby_18 if !@ruby_18.nil?
    
    #@ruby_18 = (Dir.foreach(File.join(env.path, "rubies")) do |file|
      #next if !file.directory?
      #i, v, p = parse_ruby_string(file)
      #if (i == "ruby" && v =~ /1.8.*/) || i == "rbx" || i == "ree"
        #break file.shellescape
      #else
        #log("Installing from head requires a working Ruby 1.8. Please install a compatible Ruby 1.8 first (ruby-1.8.*, rbx-*, or ree-*).", "error")
        #break false
      #end
    #end)
    #return @ruby_18
  #end


  def ensure_has_environment_files()

  end


  #########################
  # End check methods
  #########################


  #########################
  # Class Methods
  #########################

  class <<self
    #attr_reader :options

    $envout = STDOUT
    begin
      $shellout = IO.open(3, "w")
    rescue
      $shellout = STDERR
    end

    at_exit do
      $log.close if $log && !$log.closed?
      $shellout.close if $shellout && !$shellout.closed?
    end


    def read_db(*files)
      config = {}
      files.each do |conf|
        file = File.join(self.env.path, 'config', conf)
        if !File.exists?(file)
          log("Cannot read db: #{file} does not exist.")
          next 
        end
        File.open(file, 'r') do |f|
          while (str = f.gets)
            next if str =~ /^\s*(#|$)/
            k, v = str.chomp.split("=", 2)
            config[k] = v if !k.blank? && !v.blank?
          end #while
        end #File.open do
      end #each do
      return config
    end #read_db

    def config_db(*args)
      if !@config_db
        @config_db = {}
        %w(config user).each do |dir|
          file = File.join(self.env.path, dir, 'db.yml')
          yaml = YAML.load_file(file) if File.exists?(file)
          @config_db.merge!(yaml) if yaml
        end
      end

      setting = args.pop
      values = []
      values << @config_db[setting] if @config_db[setting]
      args.inject(@config_db) do |h, key|
        break if !h[key].is_a?(Hash)
        values << h[key][setting].to_s if h[key][setting]
        h[key]
      end

      return values.last
    end

    def config_alias
      return @config_alias ||= read_db('alias')
    end

    def config_md5
      return @config_md5 ||= read_db('md5')
    end

    def known_rubies
      if !@known_rubies
        @known_rubies = []
        File.open(File.join(self.env.path, 'config', 'known'), 'r') do |f|
          while (str = f.gets)
            next if str =~ /^\s*(#|$)/
            @known_rubies << str.chomp.gsub(/\[|\]|\s*#.*$/, '')
          end #while
        end
      end
      return @known_rubies
    end

    def remove_rbvm
      FileUtils.rm_rf(env.path)
      $shellout.puts "rbvm was fully removed. Note you may need to manually remove /etc/rbvmrc and ~/.rbvmrc if they exist still."
    end

    def installed_rubies(filter = nil)
      # ['ruby-1.9.2-p136', 'ruby-1.8.7-p330']
      return Dir[File.join(env.rubies_path, "#{filter}*")].collect{|path| File.basename(path)}
    end

    def installed_ruby_gemsets(filter = nil)
      # ['ruby-1.9.2-p136', 'ruby-1.9.2-p136@global', 'ruby-1.8.7-p330', 'ruby-1.8.7-p330@gemset', 'ruby-1.8.7-p330@global']
      return Dir[File.join(env.gems_path, "#{filter}*")].collect{|path| File.basename(path)}
    end

    def list_rubies(all, in_use = nil)
      all.each do |ruby_string|
        if Rbvm.new(ruby_string, true).gem_home == in_use
          prefix = "=> "
        else
          prefix = '   '
        end
        $shellout.puts "#{prefix}#{ruby_string}"
      end
      $shellout.puts "\n"
      return
    end      

    def list_gemsets(filter = nil, in_use = nil)
      dir = File.join(env.gems_path, "#{filter}*")
      gemsets = Dir[dir]
      if filter.nil?
        $shellout.puts "\nAll gemsets (found in #{dir[0...-2]})"
      else
        $shellout.puts "\ngemsets for #{File.basename(dir[0...-1])} (found in #{dir[0...-1]})"
      end
      gemsets.each do |gs|
        if filter.nil?
          tmp = File.basename(gs)
        else
          if File.basename(gs) =~ /@(.*)$/
            tmp = $1
          else
            next
          end
        end
        prefix = tmp == in_use ? "*  " : '   '
        $shellout.puts "#{prefix}#{tmp}"
      end
      $shellout.puts "\n"
      return
    end

    def print_usage
      File.open(File.join(env.path, "README")){|f| $shellout.puts f.read }
    end

    def get_version_line
      version = File.open(File.join(env.path, "VERSION")){|f| f.read.chomp }
      return "rbvm #{version}"
    end

    def print_debug
    end

    def remove_alias(name)
      if self.class.config_alias[name]
        aliases = self.class.config_alias.inject([]) do |m, (alias_name, value)|
          m << "#{alias_name}=#{value}" if alias_name != name
          m
        end
        File.open(File.join(env.path, 'config', 'alias'), 'w') do |f|
          f.print(aliases.join("\n"))
        end
      else
        log("There is no alias named: #{name}", "error")
      end
      return
    end

    def clean_default
      if config_alias['default'] && !File.directory(File.join(env.path, "rubies", config_alias['default']))
        remove_alias('default')
      end

      %w(environments rubies wrappers).each do |dir|
        file = File.join(env.path, dir, 'default')
        File.delete(file) if File.symlink?(file) && !File.exists?(file)
      end
      return
    end

    def clean_path(path)
      return path.split(':').reject { |p|
        p.start_with?(env.path)
      }.join(':')
    end

    def log(message, level = "debug")
      if options[:debug] || %w(info warn error).include?(level)
        $shellout.puts("#{message}")
      end
      $log.puts("#{level}: #{message}") if $log
    end #log()

    def open_log(file)
      $log.close if $log && !$log.closed?
      $log = File.open(File.join(env.path, 'log', Time.now.strftime("#{file}-%Y%m%d.%H%M%S%6N.log")), "w")
    end

    def options()
      return @options if @options
      @options = {}
      @opts = OptionParser.new() do |o|

      # Flags
        o.on("--head", "with update, updates rbvm to git head version.") do |head|
          @options[:head] = head
        end
        o.on("--rubygems", "with update, updates rubygems for selected ruby") do |rubygems|
          @options[:rubygems] = rubygems
        end
        o.on("--default", "with ruby select, sets a default ruby for new shells.") do |default|
          @options[:default] = default
        end
        o.on("--debug", "Toggle debug mode on for very verbose output.") do |debug|
          @options[:debug] = debug
        end
        o.on("--trace", "Toggle trace mode on to see EVERYTHING rbvm is doing.") do |trace|
          @options[:trace] = trace
        end
        o.on("--force", "Force install, removes old install & source before install.") do |force|
          @options[:force] = force
        end
        o.on("--summary", "Used with rubydo to print out a summary of the commands run.") do |summary|
          @options[:summary] = summary
        end
        o.on("--latest", "with gemset --dump skips version strings for latest gem.") do |latest|
          @options[:latest] = latest
        end
        o.on("--gems", "with uninstall/remove removes gems with the interpreter.") do |gems|
          @options[:gems] = gems
        end
        o.on("--docs", "with install, attempt to generate ri after installation.") do |docs|
          @options[:docs] = docs
        end
        o.on("--reconfigure", "Force ./configure on install even if Makefile already exists.") do |reconfigure|
          @options[:reconfigure] = reconfigure
        end
        o.on("--csh", "Force csh mode. The program will try to determine if csh is used otherwise.") do |csh|
          @options[:csh] = csh || (ENV['shell'] =~ /csh/ && ENV['version'] =~ /csh/)
        end

      # Options

        o.on("-q", "--quiet", "Quiet, don't output anything") do |quiet|
          @options[:quiet] = quiet
          $shellout = open("/dev/null", "w")
        end
        o.on("-v", "--version", "Emit rbvm version loaded for current shell") do
          $shellout.puts "version"
          exit
        end
        o.on("-l", "--level LEVEL", Integer, "patch level to use with rbvm use / install") do |level|
          @options[:level] = level
        end
        o.on("--prefix PATH", "path for all rbvm files (~/.rbvm/), with trailing slash!") do |prefix|
          @options[:prefix] = prefix
        end
        o.on("--bin PATH", "path for binaries to be placed (~/.rbvm/bin/)") do |bin|
          @options[:bin] = bin
        end
        o.on("-S SCRIPT", "Specify a script file to attempt to load and run (rubydo)") do |script|
          @options[:script] = script
        end
        o.on("-e", "Execute code from the command line.") do |e|
          @options[:e] = e
        end
        o.on("--gems", "Used to set the 'gems_flag', use with 'remove' to remove gems") do |gems|
          @options[:gems] = gems
        end
        o.on("--archive", "Used to set the 'archive_flag', use with 'remove' to remove archive") do |archive|
          @options[:archive] = archive
        end
        o.on("--patch PATH(s)", "With MRI Rubies you may specify one or more full paths to patches for multiple, specify comma separated: --patch /.../.../a.patch[%prefix],/.../.../.../b.patch 'prefix' is an optional argument, which will be bypassed to the '-p' argument of the 'patch' command. It is separated from patch file name with '%' symbol.") do |patch|
          @options[:patch] = patch.split(",")
        end
        o.on("-C", "--configure ARGS", "custom configure options. If you need to pass several configure options then append them comma separated: -C --...,--...,--...") do |configure|
          @options[:configure] = configure
        end
        o.on("--nice N", Integer, "process niceness (for slow computers, default 0)") do |nice|
          @options[:nice] = nice
        end
        o.on("--ree-options ARGS", "Options passed directly to ree's './installer' on the command line.") do |ree_options|
          @options[:ree_options] = ree_options
        end
        o.on("--with-rubies RUBIES", "Specifies a string for rbvm to attempt to expand for set operations.") do |with_rubies|
          @options[:with_rubies] = with_rubies
        end
        o.on_tail("-h", "--help", "Show this message") do
          $shellout.puts o
          exit
        end
      end
      # replace with options = @opts.getopts  ?
      @opts.parse!
      return @options
    end

    # environment variables
    def env()
      return @env if @env
      @env = {}
      @env[:path] = ENV['rbvm_path'] || File.join(ENV['HOME'], ".rbvm")
      @env[:src_path] = ENV['rbvm_src_path'] || File.join(self.env[:path], "src")
      @env[:rubies_path] = ENV['rbvm_rubies_path'] || File.join(self.env[:path], "rubies")
      @env[:gemsets_path] = ENV['rbvm_gemsets_path'] || File.join(self.env[:path], "gemsets")
      @env[:gems_path] = ENV['rbvm_gems_path'] || File.join(self.env[:path], "gems")
      @env[:gems_cache_path] = ENV['rbvm_gems_cache_path'] || File.join(self.env[:gems_path], "cache")

      # build flags and options
      @env[:configure_flags] = ENV['rbvm_configure_flags'] || ""
      @env[:make_flags] = ENV['rbvm_make_flags'] || ""
      @env[:ruby_make] = ENV['rbvm_ruby_make'] || "make"
      @env[:ruby_make_install] = ENV['rbvm_ruby_make_install'] || "make install"

      # gemsets
      @env[:gemset_separator] = ENV['rbvm_gemset_separator'] || "@"

      @env.keys.each do |sym|
        @env.singleton_class.send :define_method, sym do
          return self[sym]
        end
      end

      ENV['PATH'] = "#{env[:path]}/internal_ruby/bin:#{clean_path(ENV['PATH'])}"

      return @env
    end

    def reload!
      @env = nil
      @options = nil
      return
    end

    def parse_version_argument(args)
      if args.nil? || args.empty?
        []
      elsif String === args
        args.split(",")
      else args.size == 1
        args = args[0].split(',')
      end
    end

    #def current_rbvm
      #if ENV['rbvm_ruby_specification']
        #new(ENV['rbvm_ruby_specification'])
      #else
        #raise
      #end
    #end
    
    def get_rbvm(arg = nil, existing = nil)
      if arg.nil?
        rbvm = new(ENV['rbvm_ruby_specification'])
      else 
        rbvm = new(arg, existing)
        if !rbvm.valid?
          if ENV['rbvm_ruby_specification']
            ruby_str = ENV['rbvm_ruby_specification'].split(env.gemset_separator)[0]
          else
            ruby_str = new('default').ruby_string
          end
          rbvm = new("#{ruby_str}#{env.gemset_separator}#{arg}", existing)
        end
      end
      return rbvm
    end

    # action methods
    def use(version)
      rbvm = if version && version.start_with?('sys')
        Rbvm.new
      else
        Rbvm.new(version || 'default', true)
      end
      rbvm.create_alias("default") if options[:default]
      rbvm.use
    end

    def install(version_args)
      versions = parse_version_argument version_args
      rbvm = nil
      versions.each do |version|
        open_log("install-#{version}")
        rbvm = Rbvm.new(version)
        rbvm.fetch
        rbvm.extract
        rbvm.configure
        rbvm.build
        rbvm.install
        rbvm.install_rubygems
        rbvm.inject_scripts_gem_env
        rbvm.install_default_gems
        # import gemsets
        # irbrc
        # generate docs
        # create aliases
      end
      if versions.size == 1
        rbvm.create_alias("default") if options[:default]
        rbvm.use
      end
    end

    def uninstall(version_args, remove_sources = false)
      versions = parse_version_argument version_args
      reset_path = false
      versions << nil if versions.empty?
      versions.each do |arg|
        rbvm = get_rbvm(versions, true)
        rbvm.uninstall remove_sources
        if rbvm.ruby_string_with_gemset == ENV['rbvm_ruby_specification']
          reset_path = rbvm.ruby_string_with_gemset
        end
      end
      Rbvm.clean_default
      if reset_path
        log("The current ruby was deleted: #{reset_path}. Setting env to pre-rbvm state.", "warn")
        Rbvm.new.use
      end
    end

    def upgrade(existing, new=nil)
      rbvm_src = get_rbvm(existing, true)
      install new
      # copy gemsets
    end

    def batch(versions, args, cmd = nil)
      # run against all installed rubies if no args
      version = installed_rubies if version.empty?
      cmd ||= args.shift
      cmd = args.shift if cmd == "exec"
      versions.each do |version|
        rbvm = Rbvm.new(version, true)
        rbvm.exec_cmd_with_current_env(cmd, *args, {})
      end
    end

    def list(args)
      if args[0] =~ /gemset(s?)/
        versions = parse_version_argument(args[1])
        $shellout.puts "\nrbvm gemsets\n\n"
        list_rubies(installed_ruby_gemsets(versions.empty? ? nil : Rbvm.new(versions[0]).ruby_string), get_rbvm(nil, true).gem_home)
      elsif args[0] == "known"
        # TODO use pager? pipe file to output?
        $shellout.puts "\nrbvm known rubies\n\n"
        $shellout.puts known_rubies.join("\n")
      else
        versions = parse_version_argument(args[1])
        $shellout.puts "\nrbvm rubies\n\n"
        list_rubies(installed_rubies(versions.empty? ? nil : Rbvm.new(versions[0]).ruby_string), get_rbvm(nil, true).gem_home)
      end
    end

    def gemset_import(version=nil)
      rbvm = get_rbvm version
      if version
        if File.exists?(File.join(Dir.pwd, "#{version}.gems"))
          import_file = version
        else
          log("No gemset file named: #{version}.gems", "error")
          raise
        end
      else
        import_file = ['default.gems', 'system.gems', '.gems'].inject do |m, f|
          break f if File.exists?(File.join(Dir.pwd, f))
        end
      end
      if import_file
        rbvm.gemset_import(import_file)
      else
        log("No gemset file found!.", "error")
        raise
      end
    end

    def gemset_create(versions)
      if versions.empty?
        log("No target name supplied: #{@original_argv}", "error")
        raise
      else
        versions.each do |version|
          rbvm = get_rbvm(version)
          rbvm.create_gemset
        end
      end
    end

    def gemset_copy(new, old=nil)
      if old.nil?
        if ENV['rbvm_ruby_specification'].blank?
          log("No current rbvm_ruby_specification: #{ARGV.join(' ')}", "error")
          raise
        else
          old = ENV['rbvm_ruby_specification']
        end
      end
      if new.nil?
        log("No target name supplied: #{ARGV.join(' ')}", "error")
        raise
      else
        rbvm_src = get_rbvm(old, true)
        rbvm_dest = get_rbvm(new)
        rbvm_src.copy_gemset(rbvm_dest)
      end
    end

    def gemset_rename(new, old=nil)
      if old.nil?
        if ENV['rbvm_ruby_specification'].blank?
          log("No current rbvm_ruby_specification: #{ARGV.join(' ')}", "error")
          raise
        else
          old = ENV['rbvm_ruby_specification']
        end
      end
      if new.nil?
        log("No target name supplied: #{ARGV.join(' ')}", "error")
        raise
      else old
        rbvm_src = get_rbvm(old, true)
        rbvm_dest = get_rbvm new
        rbvm_src.rename_gemset(rbvm_dest)
      end
      rbvm_dest.use if rbvm_src.ruby_string_with_gemset == ENV['rbvm_ruby_specification']
    end
    
    def gemset_empty(version_args)
      versions = parse_version_argument version_args
      #args << nil if args.empty?
      # TODO should it empty the current gemset if none specified?
      versions.each do |version|
        rbvm = get_rbvm(version, true)
        rbvm.delete_gemset
        rbvm.create_gemset
      end
    end

    def gemset_remove(version_args)
      reset_path = false
      versions = parse_version_argument(version_args)
      # TODO should it delete the current gemset if none specified?
      args.each do |arg|
        rbvm = get_rbvm(arg, true)
        rbvm.delete_gemset
        if rbvm.ruby_string_with_gemset == ENV['rbvm_ruby_specification']
          reset_path = rbvm.ruby_string_with_gemset
        end
      end
      if reset_path
        log("The current gemset was deleted: #{reset_path}. Setting env to pre-rbvm state.", "warn")
        Rbvm.new.use
      end
    end

    def gemset_name(version_args)
      versions ||= parse_version_argument(version_args)
      versions << nil if versions.empty?
      versions.each do |version|
        $shellout.puts get_rbvm(version, true).gem_home
      end
    end

    # parse actions
    def run(args, versions = [])
      #parse options
      options

      case args[0]
        # show this usage information
        when "usage"
          print_usage

        # show the rbvm version installed in rbvm_path
        when "version", 'v'
          $shellout.puts get_version_line

        # setup current shell to use a specific ruby version
        when "use", 'u'
          use args[1]

        # reload rbvm source itself (useful after changing rbvm source)
        #when "reload"
          # handled by rbvm_init.sh

        # (seppuku) removes the rbvm installation completely. This means everything in $rbvm_path (~/.rbvm). This does not touch your profiles, which is why there is an if around the sourcing lib/rbvm.
        when "implode"
          $shellout.puts "Are you SURE you wish for rbvm to implode?\nThis will recursively remove #{env.path} and other rbvm traces?\n(type 'yes' or 'no')>"
          response = $stdin.gets.chomp
          if response == "yes"
            Rbvm.remove_rbvm
          else
            $shellout.puts "Psycologist intervened, cancelling implosion, crisis avoided :)"
          end

        # upgrades rbvm to the latest version. (If you experience bugs try this first with --head)
        when "update"
          $shellout.puts "not implented!"

        # remove current and stored default & system settings.
        when "reset"
          clean_default
          Rbvm.new.use

        # show the *current* environment information for current ruby
        when "info", 'i'
          get_rbvm.print_info(*args[1..-1])

        # show info plus additional information for common issues
        when "debug"
          get_rbvm.print_info
          #args ||= parse_version_argument(args[1])
          #get_existing_rbvm(args[0]).print_info
          # TODO add debug info.

        # install one or many ruby versions See also: http://rbvm.beginrescueend.com/rubies/installing/
        when "install", 'i'
          install args[1]

        # uninstall one or many ruby versions, leaves their sources
        when "uninstall"
          uninstall args[1]

        # uninstall one or many ruby versions and remove their sources
        when "remove"
          uninstall args[1], true

        # Lets you migrate all gemsets from one ruby to another.
        when "migrate"
          $shellout.puts "not implented!"

        # Lets you upgrade from one version of a ruby to another, including migrating your gemsets semi-automatically.
        when "upgrade"
          upgrade args[1], args[2]

        # generates a set of wrapper executables for a given ruby with the specified ruby and gemset combination. Used under the hood for passenger support and the like.
        when "wrapper"
          $shellout.puts "not implented!"

        # Lets you remove stale source folders / archives and other miscellaneous data associated with rbvm.
        when "cleanup"
          $shellout.puts "not implented!"

        #Lets you repair parts of your environment e.g. wrappers, env files and and similar files (e.g. general maintenance).
        when "repair"
          $shellout.puts "not implented!"

        #Lets your backup / restore an rbvm installation in a lightweight manner.
        when "snapshot"
          $shellout.puts "not implented!"

        #Tells you how much disk space rbvm install is using.
        when "disk-usage"
          $shellout.puts "not implented!"

        #Provides general information about the ruby environment, primarily useful when scripting rbvm.
        when "tools"
          $shellout.puts "not implented!"

        #Tools to make installing ri and rdoc documentation easier.
        when "docs"
          $shellout.puts "not implented!"

        #Tools related to managing rbvmrc trust and loading.
        when "rbvmrc"
          $shellout.puts "not implented!"

        #runs a named ruby file against specified and/or all rubies
        #runs a gem command using selected ruby's 'gem'
        #runs a rake task against specified and/or all ruby gemsets
        #runs an arbitrary command as a set operation.
        # TODO should this run against all rubies or all ruby gemsets?
        when "ruby", "gem", "rake", "exec"
          batch(versions, args)

        #runs 'rake test' across selected ruby versions
        #runs 'rake spec' across selected ruby versions
        when "tests", "specs"
          batch(versions, args, 'rake')

        #Monitor cwd for testing, run `rake {spec,test}` on changes.
        when "monitor"
          $shellout.puts "not implented!"

        #gemsets: http://rbvm.beginrescueend.com/gemsets/
        when "gemset", 'gs'
          case args[1]

          when "import"
            gemset_import args[2]

          when "export"
            rbvm = get_rbvm(args[2], true)
            rbvm.export_gemset

          when "create", 'c'
            gemset_create args[2..-1]

          when "copy"
            gemset_copy args[2], args[3]

          when "rename"
            gemset_rename args[2], args[3]

          when "empty"
            gemset_empty args[2..-1]

          when "delete", "remove"
            gemset_remove args[2..-1]

          when "name", "dir", "gemdir"
            gemset_name args[2..-1]

          when "list"
            args ||= parse_version_argument(args[2..-1])
            args << nil if args.empty?
            get_rbvm(args[0], true).list_gemsets

          when "list_all"
            Rbvm.list_gemsets

          when "install"
          when "pristine"
          when "clear"
          when "use"
            args ||= parse_version_argument(args[2])
            get_rbvm(args[0], true).use

          when "update"
          when "unpack"
          when "globalcache"
          else
            log("Invalid gemset action: #{args[1]}", "error")
            return
          end # case gemsets

          #Lets you switch the installed version of rubygems for a given 1.8-compatible ruby.
        when "rubygems"
          $shellout.puts "not implented!"

        #display the path to the current gem directory (GEM_HOME).
        when "gemdir"
          args ||= parse_version_argument(args[1])
          $shellout.puts get_rbvm(args[0], true).gem_home

        #display the path to rbvm source directory (may be yanked)
        when "srcdir"
          $shellout.puts env.src_path

        #Performs an archive / src fetch only of the selected ruby.
        when "fetch"
          args ||= parse_version_argument(args[2..-1])
          args.each do |arg|
            open_log("fetch-#{arg}")
            rbvm = Rbvm.new(arg)
            rbvm.fetch
          end

        #show currently installed rubies, interactive output.  http://rbvm.beginrescueend.com/rubies/list/
        when "list", 'l'
          list args[1..2]

        #Install a dependency package {readline,iconv,zlib,openssl} http://rbvm.beginrescueend.com/packages/
        when "package"
          $shellout.puts "not implented!"

        #Display notes, with operating system specifics.
        when "notes"
          $shellout.puts Dir.pwd

        else
          if @action_failed.nil? && args[0]
            @action_failed = true
            if args.size == 1
              use args[0]
            elsif !args.empty?
              run parse_version_argument(args.shift), args
            else
              log "Invalid action: #{ARGV.join(' ')}", "error"
            end
          else
            log "Invalid action: #{ARGV.join(' ')}", "error"
          end

      end #case ARGV[0]
    end #run
  end #class methods
end #class


if __FILE__ == $0
  Rbvm.run ARGV.dup
end
