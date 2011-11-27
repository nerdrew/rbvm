require 'helper'

class TestRbvm < MiniTest::Unit::TestCase

  #######################
  # General
  #######################
  
  def test_parse_version_string
    assert_equal "ruby-#{@version}-p#{@patchlevel}", Rbvm.new("#{@version}-p#{@patchlevel}").ruby_string
    assert_equal "ruby-1.9.2-p180", Rbvm.new("1.9.2-p180").ruby_string
    assert_equal "ruby-1.9.2-p#{Rbvm.config_db('ruby', '1.9.2', 'patchlevel')}", Rbvm.new("1.9.2").ruby_string
    assert_equal "ruby-#{v = Rbvm.config_db('ruby', 'version')}-p#{Rbvm.config_db("ruby", v, "patchlevel")}", Rbvm.new("ruby").ruby_string
    assert_equal "jruby-1.5.2", Rbvm.new("1.5.2").ruby_string
    assert_equal "rbx-1.2.1-20110215", Rbvm.new("1.2.1").ruby_string
    assert_equal "macruby-0.8", Rbvm.new("0.8").ruby_string
    self.rbvm = Rbvm.new("ruby-1.9.2-p136@gemset")
    assert_equal "136", rbvm.patchlevel
    assert_equal "gemset", rbvm.gemset
    assert_equal "ruby-1.9.2-p136", rbvm.ruby_string
    assert_equal "ruby-1.9.2-p136@gemset", rbvm.ruby_string_with_gemset
    # TODO tests for existing rubies
  end

  def test_ruby_configure_option
    ARGV << "-C--with-readline-dir=/opt/local"
    Rbvm.reload!
    assert_equal '--with-readline-dir=/opt/local', Rbvm.options[:configure]
  ensure
    ARGV.delete("-C--with-readline-dir=/opt/local")
  end

  def test_use
    output, err, env = capture_3io do
      rbvm.use
    end
    assert_match %r[GEM_HOME\=#{TEST_DIR}/gems/#{rbvm.ruby_string}], env
    assert_match %r[GEM_PATH\=#{TEST_DIR}/gems/#{rbvm.ruby_string}:#{TEST_DIR}/gems/#{rbvm.ruby_string}@global], env
    assert_match %r[PATH=#{TEST_DIR}/gems/#{rbvm.ruby_string}/bin:#{TEST_DIR}/gems/#{rbvm.ruby_string}@global/bin:#{TEST_DIR}/rubies/#{rbvm.ruby_string}/bin:#{Rbvm.clean_path(ENV['PATH'])}], env
  end

  def test_clean_path
    assert '' != Rbvm.clean_path(ENV['PATH'])
    assert_equal Rbvm.clean_path(ENV['PATH']), Rbvm.clean_path("#{TEST_DIR}/rubies/#{rbvm.ruby_string}/bin:#{TEST_DIR}/rubies/#{rbvm.ruby_string}#{Rbvm.env.gemset_separator}global/bin:#{ENV['PATH']}")
    assert_equal Rbvm.clean_path(ENV['PATH']), Rbvm.clean_path(rbvm.path)
  end

  def test_clean_default
  end

  def test_create_alias
  end

  def test_remove_alias
  end

  def test_list_rubies
  end

  def test_reset
  end

  def test_info
    out, err, env = capture_3io do
      rbvm.print_info "ruby_string"
    end
    assert_equal rbvm.ruby_string, out.chomp
    out, err, env = capture_3io do
      rbvm.print_info "ruby.interpreter"
    end
    assert_equal rbvm.interpreter, out.chomp
  end

  def test_uninstall_ruby
  end

  def test_remove_ruby
  end

  def test_usage
  end


  #######################
  # Fetch
  #######################

  def test_fetch_from_mock_internet
    assert_catches_command "curl", '-s', '-S', "-L", "--create-dirs", "-C", "-", "-o", archive, rbvm.archive_url, :* do
      rbvm.fetch
    end
  end

  #######################
  # Extract
  #######################

  def test_extract_compressed_file
    FileUtils.rm_r rbvm.src_path
    success = Proc.new do
      tmp_dir = Dir["#{rbvm.src_path}/../#{rbvm.ruby_string}_rbvm_fetch_tmp_*"].first
      FileUtils.mkdir_p tmp_dir
      (1..5).each {|x| FileUtils.touch File.join(tmp_dir, x.to_s)}
    end
    assert_catches_command ["bunzip2", "-c", archive, :*, success], ["tar", "-x", "-f", "-", "-C", :*] do
      rbvm.extract
    end
  end


  #######################
  # Configure
  #######################

  def test_configure_ruby
    assert_catches_command ["autoconf", :*], ["./configure", "--prefix=#{rbvm.ruby_home}", Rbvm.config_db(@interpreter, "configure_flags").split(","), :*].flatten do
      rbvm.configure
    end
  end


  #######################
  # Build
  #######################

  def test_build_ruby
    assert_catches_command 'make', :* do
      rbvm.build
    end
  end

  def test_build_rbx
    @interpreter = "rbx"
    @version = "1.2.4"
    @patchlevel = "20110705"
    self.rbvm = Rbvm.new("#{@interpreter}-#{@version}-#{@patchlevel}")
    cmds = CommandTest.record(false) do
      rbvm.build
    end
    assert_equal [], cmds, "No commands should run for build rbx."
  end


  #######################
  # Install
  #######################

  def test_install_rbx
    @interpreter = "rbx"
    @version = "1.2.4"
    @patchlevel = "20110705"
    self.rbvm = Rbvm.new("#{@interpreter}-#{@version}-#{@patchlevel}")

    assert_catches_command "#{TEST_DIR}/internal_ruby/bin/rake", 'install', :* do
      rbvm.install
    end
  end


  #######################
  # Post Install
  #######################

  def test_post_install_gem_setup
    assert_catches_command ["curl", "-s", "-S", "-L", "--create-dirs", "-C", "-", "-o", :*], ["#{rbvm.ruby_home}/bin/ruby", /setup\.rb/, :*], ["#{rbvm.ruby_home}/bin/ruby", "#{rbvm.ruby_home}/bin/gem", "update", "--system", :*] do
      rbvm.install_rubygems
    end
  end

  def test_bin_env_injection
    gem_file = File.join(rbvm.ruby_home, 'bin', 'gem')
    FileUtils.mkdir_p File.join(rbvm.ruby_home, 'bin')
    File.open(gem_file, 'w') do |f|
      f.print <<-EOF
#!/usr/bin/env ruby
#--
# Copyright 2006 by Chad Fowler, Rich Kilmer, Jim Weirich and others.
# All rights reserved.
# See LICENSE.txt for permissions.
#++

require 'rubygems'
require 'rubygems/gem_runner'
require 'rubygems/exceptions'
EOF
end

    assert_catches_command "chmod", "+x", gem_file, :* do
      rbvm.inject_scripts_gem_env
    end
    gem_file_line_two = File.open(gem_file) {|f| f.readline; f.readline }
    assert_equal "ENV['GEM_HOME']||='#{TEST_DIR}/gems/#{rbvm.ruby_string}'\n", gem_file_line_two
  end
  
  def test_gem_install_skips_installed_gems
  end


  #######################
  # Gemset Tests
  #######################

  def test_create_gemset
    self.rbvm = Rbvm.new("#{rbvm.ruby_string}@test_gemset")
    rbvm.create_gemset
    assert File.directory?(rbvm.gem_home), "Gemset directory not created: #{rbvm.gem_home}"
  end

  def test_rename_gemset
    self.rbvm = Rbvm.new("#{rbvm.ruby_string}@test_gemset")
    new_gemset_home = rbvm.gem_home.sub(/test_gemset$/, 'new_test_gemset')
    Dir.mkdir(rbvm.gem_home) if !File.directory?(rbvm.gem_home)
    rbvm.rename_gemset(rbvm.ruby_string_with_gemset.sub(/test_gemset$/, 'new_test_gemset'))
    assert File.directory?(new_gemset_home), "Gemset directory not created: #{new_gemset_home}"
  end

  def test_remove_gemset
    self.rbvm = Rbvm.new(rbvm.ruby_string+"@test_gemset")
    gemset_dir = File.join(TEST_DIR, "gems", rbvm.ruby_string_with_gemset)
    Dir.mkdir(gemset_dir) if !File.directory?(gemset_dir)
    assert File.directory?(gemset_dir), "Setup failed"
    rbvm.delete_gemset
    assert !File.directory?(gemset_dir)
  end

  def test_gemset_use
    self.rbvm = Rbvm.new(rbvm.ruby_string+"@test_gemset")
    gemset_dir = File.join(TEST_DIR, "gems", rbvm.ruby_string_with_gemset)
    Dir.mkdir(gemset_dir) if !File.directory?(gemset_dir)
    out, err, env = capture_3io do
      rbvm.use
    end
    assert_match %r[GEM_HOME\=#{rbvm.gem_home}], env
  end

  def test_gemset_import
    Rbvm.options[:force] = true
    dir = File.join(rbvm.gem_home, "gems", "rake-0.9.2") 
    assert_catches_command "#{rbvm.ruby_home}/bin/gem", "install", :* do
      rbvm.gemset_import(File.join(TEST_DIR, "gemsets", "default.gems"))
    end
  ensure
    Rbvm.options.delete(:force)
  end
end
