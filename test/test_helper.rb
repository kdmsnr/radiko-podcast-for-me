require 'coverage'
Coverage.start

test_dir = File.expand_path(__dir__)
$LOAD_PATH.unshift(test_dir) unless $LOAD_PATH.include?(test_dir)

PROJECT_ROOT = File.expand_path('..', __dir__)
TEST_DIR_PREFIX = File.join(PROJECT_ROOT, 'test') + File::SEPARATOR

def compute_nocov_lines(file)
  nocov_lines = []
  skipping = false
  begin
    File.foreach(file).with_index(1) do |line, idx|
      if line.include?('# :nocov:')
        skipping = !skipping
        next
      end
      nocov_lines << idx if skipping
    end
  rescue Errno::ENOENT
    # ignore files removed during run
  end
  nocov_lines
end

at_exit do
  coverage = Coverage.result
  relevant = coverage.select do |file, _|
    file.start_with?(PROJECT_ROOT) && !file.start_with?(TEST_DIR_PREFIX)
  end

  if relevant.empty?
    puts "No coverage data collected."
    next
  end

  total_lines = 0
  covered_lines = 0

  relevant.each do |file, counts|
    file_lines = 0
    file_covered = 0
    nocov_lines = compute_nocov_lines(file)

    counts.each_with_index do |hits, index|
      line_number = index + 1
      next if hits.nil?
      next if nocov_lines.include?(line_number)
      file_lines += 1
      file_covered += 1 if hits > 0
    end

    total_lines += file_lines
    covered_lines += file_covered

    next if file_lines.zero?
    percentage = (file_covered.to_f / file_lines * 100).round(2)
    puts format("Coverage %5.2f%% %s", percentage, file.sub(PROJECT_ROOT + '/', ''))
  end

  if total_lines.zero?
    puts "No executable lines tracked."
  else
    overall = (covered_lines.to_f / total_lines * 100).round(2)
    puts format("Overall coverage %5.2f%% (%d/%d lines)", overall, covered_lines, total_lines)
  end
end

require 'minitest/autorun'
require 'mini_exiftool'
