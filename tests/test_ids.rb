# frozen_string_literal: true
require 'minitest/autorun'
ENV['GTS_MIGRATOR_LIBRARY_ONLY'] = '1'
require_relative '../import'

class IdTest < Minitest::Test
  def test_historical_milliseconds_survive
    date = Time.iso8601('2020-02-02T12:00:00.123Z')
    id = GtsMigrator.historical_id(date, 17)
    assert_equal 1_580_644_800_123, id >> 16
    assert_equal 17, id & 65_535
  end

  def test_sorting_tracks_date_even_with_different_sequence
    old = Time.iso8601('2010-01-01T00:00:00Z')
    newer = Time.iso8601('2020-01-01T00:00:00Z')
    assert_operator GtsMigrator.historical_id(old, 65_535), :<, GtsMigrator.historical_id(newer, 0)
  end

  def test_import_is_opt_in
    options = GtsMigrator.options(['--archive', '/archive', '--target-user', 'anyuser'])
    refute options[:apply]
    refute options[:followers]
    refute options[:skip]
  end
end
