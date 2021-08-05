# Tester for snapshot_lib

require 'fileutils'
require 'tempfile'
require "test/unit"
require 'tmpdir'

require_relative 'snapshot_lib'

class TestAgedOutAll < Test::Unit::TestCase
  [
    ["minutes", 5, 4 * 60, false],
    ["minutes", 5, 6 * 60, true],
    ["minutes", 10, 1 * 60, false],
    ["minutes", 10, 9 * 60, false],
    ["minutes", 10, 12 * 60, true],
    ["hours", 1, 12 * 60, false],
    ["hours", 1, 2 * 3600, true],
    ["days", 1, 2 * 60 * 60 * 24, true],
    ["days", 1, 6 * 60 * 60 * 24, true],
  ].each do |units, delta, mtime_delta, expected|
    test_name = "test_#{units}.#{delta}.#{mtime_delta}.#{expected}"
    define_method(test_name) {
      mydir = Dir.mktmpdir()
      mypath = "#{mydir}/#{units}_ago/#{delta}"
      tnow = Time.now
      FileUtils.mkdir_p(mypath)
      file = Tempfile.new('foo', mypath)
      fname = file.path
      FileUtils.touch fname, :mtime => tnow - mtime_delta
      check_aged_out = CheckAgedOut.new
      assert_equal(check_aged_out.aged_out(fname), expected)
    }
  end
end
