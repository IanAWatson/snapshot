#!/usr/bin/env ruby

# frozen_string_literal: true

# Emulate the .shapshot capability of Citc

require 'fileutils'
require 'find'
require 'tempfile'

require_relative('ruby/iwcmdline')
require_relative('snapshot_lib')

# Description of one of the individual tarfiles stores in the save tree.
class SnapshotFile
  attr_accessor :fname, :unts, :must_wait

  def initialize(fname, units)
    # The name of the tar file.
    @fname = fname
    # The time units that this slot uses. Must be consistent with @fname
    # Note that this is only used during initialization. While running,
    # the time units of each file is discerned from the current name.
    # So as an individual file moves from minutes->hours->days, it will
    # be perceived as having different units. This variable is NOT updated.
    @units = units
    # Some snapshots are special. They can only move if the next slot is
    # empty. Think about the hours_ago/1 slot. It will get populated
    # every 5 minutes from the 55 minutes ago slot. But it cannot
    # overwrite the hours_ago/2 slot unless it has timed out.
    @must_wait = false
  end
end

# Create a series of snapshots of code.
class Snapshot # rubocop:disable Metrics/ClassLength
  attr_accessor :verbose

  def initialize(from, to) # rubocop:disable Metrics/MethodLength
    # The directory from which we copy files
    @from_dir = from
    # The top level directiry in which copies are placed.
    @to_dir = to
    # How often do we wake up and do another snapshot.
    @delta = 300 # five minutes
    # The largest file size we process.
    @max_size_bytes = 500_000
    # Within each directory within @to_dir, we store a tar file.
    @tarfile = 'snapshot.tar.gz'

    # The time intervals at which we take/keep snapshots
    @intervals = { 'minute' => (5..55).step(5).to_a,
                   'hour' => (1..23).to_a,
                   'day' => (1..30).to_a }
    # Each of the include and exclude Regexp's are arrays to avoid
    # generating unreadable Regexp. If any item matches, then it is
    # considered a match.
    # One important difference is that rx_include matches on File.basename
    # whereas rx_skip matches the entire path name. That way excluding
    # all the bazel-* tree becomes easy.
    # Maybe I need to do my own custom directory recursion.
    @rx_skip = []
    @rx_include = []
    default_rx

    @my_files = initialize_directory_structure
    mark_each_first_file_new_units

    # The longest time that this invocation knows about. Is actually set
    # with a proper value in update_horizon
    @horizon = Time.now
    update_horizon

    # On the first call to cycle_existing_snapshot_dirs, we must regenerate
    # the tar file in order to get things started
    @first_call = true

    # If set, emit debugging messages.
    @verbose = false
  end

  # Initialize the default regexps for files to save and ignore.
  def default_rx # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
    @rx_include << Regexp.new('\.(c|cc|rb|jl|sh|proto|py|go|f|h|md|ipynb)$')
    @rx_include << Regexp.new('^BUILD')
    @rx_include << Regexp.new('^WORKSPACE')
    @rx_include << Regexp.new('^Makefile')
    @rx_include << Regexp.new('^Dockerfile')
    @rx_include << Regexp.new('^\.gitignore')
    @rx_include << Regexp.new('^\.bazelrc')
    @rx_include << Regexp.new('^\.dockerignore')
    @rx_include << Regexp.new('^CMakeLists.txt')

    @rx_skip << Regexp.new('\/core')
    @rx_skip << Regexp.new('\/__pycache__')
    @rx_skip << Regexp.new('\.(o)$')
    @rx_skip << Regexp.new('\.(a)$')
    @rx_skip << Regexp.new('\/bazel-')
    @rx_skip << Regexp.new('gmon.out')
  end

  # Return an array of SnapshotFile's, one per directory.
  # As each directory name is formed, that directory is created.
  # If the directory already exists, no error is recorded.
  def initialize_directory_structure # rubocop:disable Metrics/MethodLength
    result = []

    %w[day hour minute].each do |unit|
      @intervals[unit].reverse.each do |i|
        dir = File.join(@to_dir, "#{unit}s_ago", i.to_s)
        FileUtils.mkdir_p(dir)
        fname = File.join(dir, @tarfile)
        $stderr << fname << "\n"
        result << SnapshotFile.new(fname, unit)
      end
    end

    result
  end

  # For each file that is the first of a new unit of time, mark it
  # as needing to wait till its next slot is free.
  def mark_each_first_file_new_units
    to_mark = Regexp.new(%r{(hours|days)_ago/1/})
    @my_files.each do |f|
      if to_mark.match(f.fname)
        f.must_wait = true
      end
    end
  end

  def update_horizon
    # The longest time considered for inclusion in the tar file
    # seconds_per_day = 60 * 60 * 24
    # Could not get this to work, --newer-mtime=@#{horizon}
    # @horizon = Time.now - @intervals['day'].last * seconds_per_day
    day_horizon = @intervals['day'].last
    @horizon = "#{day_horizon} days ago"
  end

  # Return a list of the snapshot files used here.
  def files
    result = []
    @my_files.each do |f|
      result << f.fname if FileTest.file?(f.fname)
    end
    result
  end

  # Called every now and then to shuffle the data back - if anything
  # has aged out.
  # If a snapshot file has aged out, it moves to the next slot.
  def cycle_existing_snapshot_dirs # rubocop:disable Metrics/MethodLength, Metrics/PerceivedComplexity, Metrics/AbcSize, Metrics/CyclomaticComplexity
    if @first_call
      regenerate_tar_file
      @first_call = false
      return
    end
    check_aged_out = CheckAgedOut.new
    @my_files.each_with_index do |f, i|
      fname = f.fname
      next unless FileTest.file?(fname)

      $stderr << "status of #{fname} " << check_aged_out.aged_out(fname) << "\n" if @verbose
      next unless check_aged_out.aged_out(fname)

      # If we are the oldest file and we have aged out, remove it.
      if i.zero?
        File.delete(fname)
        next
      end

      # File `i` has as aged out, move it unless we are one of the slots
      # that must wait.
      newfile = @my_files[i - 1].fname # The next oldest slot.
      next if f.must_wait && File.exist?(newfile)

      FileUtils.mv(fname, newfile)

      # If we are the most recent file, and we have just moved our tarfile, regnerate.
      regenerate_tar_file if fname == name_of_first_tar_file
    end
  end

  # The name of the tar file that gets created. Since @my_files is ordered
  # from oldest to youngest, the result will always be based on the last
  # element in that array.
  def name_of_first_tar_file
    @my_files.last.fname
  end

  def include_file(fname)
    return false if File.zero?(fname)
    return false if File.size?(fname) > @max_size_bytes

    bname = File.basename(fname)
    @rx_include.any? { |rx| rx.match(bname) }
  end

  def exclude_file(fname)
    @rx_skip.any? { |rx| rx.match(fname) }
  end

  # Only files modified within our @horizon are stored.
  # Note that File.size? will raise an exception if `tarfile` is not present. That is fine.
  def regenerate_tar_file # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
    files_from = Tempfile.new('files_from')
    Find.find(@from_dir) do |path|
      if FileTest.directory?(path)
        Find.prune if exclude_file(path)
        next # Directories are never included.
      end
      next if exclude_file(path)

      files_from.write("#{path}\n") if include_file(path)
    end
    files_from.close
    raise 'No files' unless File.size?(files_from.path) > 0 # rubocop:disable Style/NumericPredicate

    create_tar_file(files_from.path)
    files_from.unlink
    update_horizon
  end

  def create_tar_file(files_from)
    tarfile = name_of_first_tar_file
    cmd = "tar --files-from=#{files_from} --newer-mtime='#{@horizon}' --create --gzip --file=#{tarfile} #{@from_dir}"
    $stderr << "Executing '#{cmd}'\n"
    system(cmd)
    raise "Did not create tarfile #{cmd}" unless File.size?(tarfile) > 0 # rubocop:disable Style/NumericPredicate

    FileUtils.chmod '-w', tarfile # Make it harder to break this system.
    true
  end
end

def snapshot # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
  cl = IWCmdline.new('-v--from=dir=dir-snapshot=dir-interval=ipos')
  verbose = cl.option_count('v')
  snapshot_dir = '../.snapshot'
  snapshot_dir = cl.value('snapshot') if cl.option_present('snapshot')
  from_dir = '.'
  from_dir = cl.value('from_dir') if cl.option_present('fromdir')
  $stderr << "Backing up #{from_dir} to #{snapshot_dir}\n" if verbose
  snapshot = Snapshot.new(from_dir, snapshot_dir)
  snapshot.verbose = verbose
  $stderr << snapshot.files << "\n" if verbose
  interval = 300
  interval = cl.value('interval') if cl.option_present('interval')
  loop do
    sleep(interval)
    $stderr << "Awake, checking\n"
    snapshot.cycle_existing_snapshot_dirs
  end
end

snapshot
