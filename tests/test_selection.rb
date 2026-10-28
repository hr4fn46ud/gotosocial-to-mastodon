# frozen_string_literal: true
require 'minitest/autorun'
ENV['GTS_MIGRATOR_LIBRARY_ONLY'] = '1'
require_relative '../import'

class SelectionTest < Minitest::Test
  def records
    [
      { 'status' => { 'id' => 'original', 'in_reply_to_id' => nil, 'in_reply_to_account_id' => nil }, 'media' => [{ 'id' => 'image' }] },
      { 'status' => { 'id' => 'self_reply', 'in_reply_to_id' => 'original', 'in_reply_to_account_id' => 'own' } },
      { 'status' => { 'id' => 'external_reply', 'in_reply_to_id' => 'external', 'in_reply_to_account_id' => 'other' } },
      { 'status' => { 'id' => 'missing_parent_reply', 'in_reply_to_id' => nil, 'in_reply_to_account_id' => 'other' } }
    ]
  end

  def test_excludes_all_replies_and_retains_media_original
    selected, ignored = GtsMigrator.partition_records(records, exclude_replies: true)
    assert_equal ['original'], selected.map { |r| r['status']['id'] }
    assert_equal 1, selected.first['media'].size
    assert_equal %w(self_reply external_reply missing_parent_reply), ignored.map { |r| r['status']['id'] }
  end

  def test_default_keeps_previous_selection
    selected, ignored = GtsMigrator.partition_records(records, exclude_replies: false)
    assert_equal 4, selected.size
    assert_empty ignored
  end

  def test_flag_does_not_enable_writing_or_skipping_other_errors
    options = GtsMigrator.options(['--archive', '/archive', '--target-user', 'anyuser', '--exclude-replies'])
    assert options[:exclude_replies]
    refute options[:apply]
    refute options[:skip]
    refute options[:followers]
  end

  def test_dry_run_never_plans_excluded_replies_and_reports_them_separately
    data = records
    archive = Struct.new(:records, :manifest).new(data, { 'source' => { 'account_id' => 'own' } })
    importer = GtsMigrator::Importer.allocate
    importer.instance_variable_set(:@archive, archive)
    importer.instance_variable_set(:@opts, { exclude_replies: true, apply: false, skip: false })
    importer.instance_variable_set(:@version, '4.7.3')
    importer.instance_variable_set(:@account, Struct.new(:id, :username).new(1, 'test'))
    importer.instance_variable_set(:@plans, {})
    importer.instance_variable_set(:@source_ids, data.to_h { |r| [r['status']['id'], r] })
    importer.define_singleton_method(:plan) do |record|
      raise 'Reply reached the planner' unless record['status']['id'] == 'original'
      item = { id: 'original', record: record, reasons: [], action: 'import' }
      @plans['original'] = item
    end
    importer.define_singleton_method(:ensure_table!) { raise 'Dry run attempted to change schema' }
    importer.define_singleton_method(:import_one) { |_item| raise 'Dry run attempted to write a post' }
    stdout, stderr = capture_io { importer.run }
    report = JSON.parse(stdout)
    assert_empty stderr
    assert_equal 1, report['importable']
    assert_equal 0, report['unsupported']
    assert_equal 3, report['ignored_replies']
    assert_equal 4, report['posts'].size
    assert_equal 3, report['posts'].count { |p| p['action'] == 'ignore' && p['reasons'] == ['reply_excluded'] }
  end
end
