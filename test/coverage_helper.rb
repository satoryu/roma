require 'json'
require 'simplecov'
require 'simplecov-cobertura'

# Measures the coverage of lib, both in the test process and in every romad
# the end-to-end tests start. Each process writes its own result under
# coverage/results, and `rake coverage` merges them into coverage/index.html,
# and into coverage/coverage.xml (Cobertura) for Codecov.
module CoverageHelper
  RESULTS_DIR = 'coverage/results'

  # Tools that are themselves tests, benchmarks or samples. Testing them
  # would mean testing test code, so they are left out of the report.
  SCRIPTS = %w(
    safecopy_integration_test safecopy_test test-scenario
  ).map { |name| "lib/roma/tools/#{name}.rb" }

  # The default message lists every process.
  class CoberturaFormatter < SimpleCov::Formatter::CoberturaFormatter
    def output_message(_result, result_path)
      "Cobertura report for Codecov: #{Pathname(result_path).relative_path_from(SimpleCov.root)}"
    end
  end

  module_function

  def configure
    SimpleCov.root(File.expand_path('..', __dir__))
    SimpleCov.cover 'lib/**/*.rb'
    SCRIPTS.each { |path| SimpleCov.skip(path) }
    SimpleCov.enable_coverage :branch
  end

  # Starts measuring this process. +name+ tells the processes apart.
  def start(name)
    configure
    SimpleCov.command_name "#{name} #{Process.pid}"
    SimpleCov.coverage_dir "#{RESULTS_DIR}/#{name}-#{Process.pid}"
    # The report is made once, from all the results. When tests fail,
    # SimpleCov says it skips the report of this process; it still saves the
    # result, which is all that's needed.
    SimpleCov.formatter SimpleCov::Formatter::MultiFormatter.new([])
    SimpleCov.print_errors false
    SimpleCov.start
  end

  # Merges the results of all the processes into one report, and prints the
  # totals. (The formatter's own message lists every process.)
  def report
    results = Dir["#{RESULTS_DIR}/*/.resultset.json"]
    SimpleCov.collate(results) do
      CoverageHelper.configure
      coverage_dir 'coverage'
      formatter SimpleCov::Formatter::MultiFormatter.new([
        SimpleCov::Formatter::HTMLFormatter.new(silent: true),
        CoverageHelper::CoberturaFormatter
      ])
    end

    total = JSON.parse(File.read('coverage/coverage.json'))['total']
    lines = { 'Line' => total['lines'], 'Branch' => total['branches'] }.map do |criterion, stat|
      format('%s coverage: %d / %d (%.2f%%)', criterion, stat['covered'], stat['total'], stat['percent'])
    end
    puts "Coverage report for #{results.size} processes: coverage/index.html", lines

    # On GitHub Actions, show the totals on the run's summary page too.
    if ENV['GITHUB_STEP_SUMMARY']
      File.write(ENV['GITHUB_STEP_SUMMARY'], "## Coverage\n\n#{lines.map { |l| "- #{l}\n" }.join}", mode: 'a')
    end
  end
end
