# See MiniTest::Unit#process_args rdoc
# rake test TESTOPTS="-h"

require 'rubygems'
require 'bundler'

begin
  Bundler.setup(:default, :development)
rescue Bundler::BundlerError => e
  $stderr.puts e.message
  $stderr.puts "Run `bundle install` to install missing gems"
  exit e.status_code
end
require 'minitest/unit'
#require 'minitest/pride'

require 'fileutils'
require 'open3'

$LOAD_PATH.unshift '/Users/andrew/dev/command_test/lib'
require 'command_test'

$LOAD_PATH.unshift '/Users/andrew/dev/fakefs/lib'
require 'fakefs/safe'

$LOAD_PATH.unshift(File.dirname(__FILE__))
$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), '..', 'scripts'))
require 'rbvm'

# Silence log
$shellout = File.open("/dev/null", "w")

class MiniTest::Unit::TestCase

  TEST_RUBIES = %w(ruby-1.8.7-p330 ruby-1.9.2-p136 rbx-1.2.4-20110705 jruby-1.6.0)
  #TEST_RUBIES = %w(rbx-1.2.4-20110705)

  SRC_DIR = File.dirname(File.expand_path(File.dirname(__FILE__)))
  TEST_DIR = SRC_DIR

  ENV.delete_if do |key, value|
    key.start_with?("rbvm_")
  end
  %w(RUBYOPT BUNDLE_GEMFILE BUNDLE_BIN_PATH GEM_HOME GEM_PATH MY_RUBY_HOME RUBY_VERSION IRBRC).each do |var|
    ENV.delete(var)
  end
  ENV['rbvm_path'] = TEST_DIR
  ENV['rbvm_gemset_separator'] = '@'

  FakeFS.activate!

  attr_accessor :rbvm

  def setup
    %w(db.yml alias md5 known).each do |file|
      FakeFS::FileSystem.clone(File.join TEST_DIR, 'config', file)
    end
    FakeFS::FileSystem.clone(File.join TEST_DIR, 'gemsets', 'default.gems')

    %w(archives bin config contrib environments examples gems help internal_ruby lib log man patches rubies scripts src tmp user wrappers).each do |dir|
      FileUtils.mkdir_p File.join(TEST_DIR, dir)
    end

    %w(jruby-bin-1.6.0.tar.gz jruby-src-1.6.0.tar.gz rubinius-1.2.2-20110222.tar.gz rubinius-1.2.4-20110705.tar.gz ruby-1.8.7-p330.tar.bz2 ruby-1.9.2-p136.tar.bz2 ruby-1.9.2-p290.tar.bz2 rubygems-1.6.2.tgz rubygems-1.8.10.tgz).each do |file|
      FileUtils.touch File.join(TEST_DIR, 'archives', file)
    end

    %w(jruby-1.6.0 rbx-1.2.2-20110222 rbx-1.2.4-20110705 ruby-1.8.7-p330 ruby-1.9.2-p136 ruby-1.9.2-p290).each do |dir|
      FileUtils.mkdir_p File.join(TEST_DIR, 'src', dir)
      FileUtils.mkdir_p File.join(TEST_DIR, 'rubies', dir)
      FileUtils.mkdir_p File.join(TEST_DIR, 'gems', dir)
    end 
    FileUtils.mkdir_p File.join(TEST_DIR, 'src', 'rubygems-1.8.10')

    %w(LICENCE VERSION).each do |file|
      FileUtils.touch File.join(TEST_DIR, file)
    end

    Rbvm.reload!

    @interpreter = "ruby"
    @version = "1.9.2"
    @patchlevel = "136"
    @rbvm = Rbvm.new("#{@interpreter}-#{@version}-p#{@patchlevel}")
    return
  end

  def teardown
    FakeFS::FileSystem.clear
  end

  def capture_3io
    require 'stringio'

    orig_shellout, orig_stderr, orig_envout         = $shellout, $stderr, $envout
    captured_shellout, captured_stderr, captured_envout = StringIO.new, StringIO.new, StringIO.new
    $shellout, $stderr, $envout                 = captured_shellout, captured_stderr, captured_envout

    yield

    return captured_shellout.string, captured_stderr.string, captured_envout.string
  ensure
    $shellout = orig_shellout
    $stderr = orig_stderr
    $envout = orig_envout
  end

  def archive
    return File.join(TEST_DIR, "archives", @rbvm.archive_name)
  end
end

MiniTest::Unit.autorun
