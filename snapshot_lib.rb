# supporting tools for snapshot.rb


# Checks modification times of specifically named files and determines
# if their modification time is beyone certain thresholds.
class CheckAgedOut
  def initialize
    @minutes = 60
    @hours = @minutes * 60
    @days = 24 * @hours
    @time_units = { 'minutes' => @minutes, 'hours' => @hours, 'days' => @days }
    @rx = Regexp.new('..*\/(minutes|hours|days)_ago\/(\d+)')
  end

  def aged_out(fname) # rubocop:ignore Metrics/MethodLength
    m = @rx.match(fname)
    unless m
      $stderr << "No regexp match '#{fname}'\n"
      return false
    end

    mtime = File.mtime(fname)

    unit = m[1]
    delta_units = m[2].to_i
    delta_time = @time_units[unit] * delta_units
    rc = Time.now - mtime > delta_time
    $stderr << "#{fname} unit #{unit} #{delta_units} now #{Time.now} #{mtime} rc #{rc}\n"

    Time.now - mtime > delta_time
  end
end
