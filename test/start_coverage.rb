# Required first, with COVERAGE set, by the tests and by the servers.
require_relative 'coverage_helper'

CoverageHelper.start(File.basename($PROGRAM_NAME))
