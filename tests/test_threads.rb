# frozen_string_literal: true
require 'minitest/autorun'
ENV['GTS_MIGRATOR_LIBRARY_ONLY'] = '1'
require_relative '../import'

class SplitTest < Minitest::Test
  def split(text, budget = 40, ranges = [])
    fits = ->(value) { value.scan(/\X/).length <= budget }
    GtsMigrator.split_text(text, fits: fits, protected_ranges: ranges)
  end

  def test_words_paragraphs_and_punctuation_are_not_lost
    text = "A complete first paragraph.\n\nA second paragraph follows, including punctuation: àéø! " * 8
    parts = split(text)
    assert_operator parts.length, :>, 1
    assert_equal text, parts.join
    assert parts.all? { |part| part.scan(/\X/).length <= 40 }
  end

  def test_short_and_exact_limit_text_stay_single
    assert_equal ['Short'], split('Short')
    assert_equal ['x' * 40], split('x' * 40)
  end

  def test_long_word_is_split_without_losing_characters
    text = 'A' * 231
    assert_equal text, split(text).join
    assert_equal 6, split(text).length
  end

  def test_combining_marks_and_family_emoji_remain_intact
    grapheme = "👨‍👩‍👧‍👦"
    text = (grapheme + "e\u0301") * 31
    parts = split(text, 9)
    assert_equal text, parts.join
    assert parts.all? { |part| part.scan(/\X/).all? { |value| [grapheme, "e\u0301"].include?(value) } }
  end

  def test_url_is_counted_as_one_entity_and_not_cut
    url = 'https://example.invalid/' + 'a' * 250
    text = 'Introduction ' * 8 + url + ' Conclusion ' * 8
    start = text.index(url)
    fits = ->(value) { value.gsub(url, 'x' * 23).scan(/\X/).length <= 40 }
    parts = GtsMigrator.split_text(text, fits: fits, protected_ranges: [[start, start + url.length]])
    assert_equal text, parts.join
    assert_equal 1, parts.count { |part| part.include?(url) }
    assert parts.all? { |part| fits.call(part) }
  end

  def test_content_warning_budget_applies_to_every_part
    warning = 'Content warning: '
    fits = ->(value) { (warning + value).scan(/\X/).length <= 50 }
    text = 'A longer text with all of its content. ' * 8
    parts = GtsMigrator.split_text(text, fits: fits)
    assert_equal text, parts.join
    assert parts.all? { |part| fits.call(part) }
  end

  def test_warning_over_limit_and_indivisible_entity_are_reported
    assert_raises(GtsMigrator::Error) { GtsMigrator.split_text('Text', fits: ->(_text) { false }) }
    assert_raises(GtsMigrator::Error) { split('123456789', 5, [[0, 9]]) }
  end

  def test_invalid_entity_positions_are_rejected
    assert_raises(GtsMigrator::Error) { split('123456789', 5, [[0, 3], [2, 6]]) }
  end

  def test_part_mapping_preserves_root_key_and_has_distinct_followups
    key = 'https://example.invalid/@user#SOURCE'
    assert_equal key, GtsMigrator.part_key(key, 0)
    assert_equal 3, 3.times.map { |i| GtsMigrator.part_key(key, i) }.uniq.length
  end

  def test_split_and_exclude_replies_flags_never_enable_apply
    options = GtsMigrator.options(['--archive', '/archive', '--target-user', 'user', '--exclude-replies', '--split-long-posts'])
    assert options[:split_long_posts]
    assert options[:exclude_replies]
    refute options[:apply]
    refute options[:skip]
  end
end

# Unit-level storage doubles verify the thread writer's transaction boundary and
# linkage. They do not stand in for PostgreSQL, Rails callbacks or media processing.
class ThreadWriterTest < Minitest::Test
  class Connection
    attr_reader :statuses, :mappings, :transactions
    attr_accessor :fail_id
    def initialize
      @statuses, @mappings, @transactions = [], [], 0
    end
    def transaction
      @transactions += 1
      snapshot = [@statuses.dup, @mappings.dup]
      yield
    rescue StandardError
      @statuses, @mappings = snapshot
      raise
    end
  end

  class Draft
    attr_accessor :id, :thread, :media_attachments, :ordered_media_attachment_ids, :override_timestamps
    attr_reader :attrs
    def initialize(connection, attrs)
      @connection, @attrs = connection, attrs
    end
    def save!
      raise 'Simulated part failure' if id == @connection.fail_id
      @connection.statuses << self
    end
  end

  def setup
    @connection = Connection.new
    collection = Object.new
    connection = @connection
    collection.define_singleton_method(:new) { |attrs| Draft.new(connection, attrs) }
    account = Struct.new(:id, :statuses).new(7, collection)
    mapping = Object.new
    mapping.define_singleton_method(:create!) { |attrs| connection.mappings << attrs }
    @importer = GtsMigrator::Importer.allocate
    @importer.instance_variable_set(:@account, account)
    @importer.instance_variable_set(:@connection, @connection)
    @importer.instance_variable_set(:@mapping, mapping)
    @importer.define_singleton_method(:allocate_thread_ids) do |timestamp, count|
      Array.new(count) { |index| GtsMigrator.historical_id(timestamp, 100 + index) }
    end
    @item = { id: 'source', source_key: 'source-key', sha256: 'thread-hash',
              payload: { created_at: '2020-01-01T12:00:00.123Z', spoiler_text: 'CW',
                         visibility: 'public', sensitive: true, language: 'de' },
              parts: ['Beginning', 'Middle', 'End'], record: { 'media' => [] } }
    Object.const_set(:ProcessHashtagsService, Class.new { def call(_status); end })
  end

  def teardown
    Object.send(:remove_const, :ProcessHashtagsService)
  end

  def test_all_parts_are_linked_dated_and_mapped_in_one_transaction
    @importer.import_one(@item)
    statuses = @connection.statuses
    assert_equal 1, @connection.transactions
    assert_equal 3, statuses.length
    assert_equal @item[:parts], statuses.map { |s| s.attrs[:text] }
    assert_nil statuses.first.thread
    assert_same statuses[0], statuses[1].thread
    assert_same statuses[1], statuses[2].thread
    assert_equal [Time.iso8601(@item[:payload][:created_at])], statuses.map { |s| s.attrs[:created_at] }.uniq
    assert_equal statuses.map(&:id).sort, statuses.map(&:id)
    assert_equal 1, statuses.map { |s| s.id >> 16 }.uniq.length
    assert_equal %w(source-key source-key/gts-migrator-part/2 source-key/gts-migrator-part/3), @connection.mappings.map { |m| m[:source_key] }
    assert_equal statuses.map(&:id), @item[:target_ids]
    assert_equal statuses.first.id, @item[:target_id]
    assert statuses.all? { |s| s.attrs[:spoiler_text] == 'CW' && s.attrs[:visibility] == 'public' && s.override_timestamps }
  end

  def test_failure_rolls_back_all_parts_and_mappings
    @connection.fail_id = GtsMigrator.historical_id(Time.iso8601(@item[:payload][:created_at]), 101)
    assert_raises(RuntimeError) { @importer.import_one(@item) }
    assert_empty @connection.statuses
    assert_empty @connection.mappings
    refute @item.key?(:target_ids)
  end
end

class ThreadResumeTest < Minitest::Test
  Entry = Struct.new(:status_id, :payload_sha256)
  StoredStatus = Struct.new(:account_id, :deleted_at, :in_reply_to_id) do
    def local?; true; end
  end

  def setup
    @entries = [Entry.new(1, 'same'), Entry.new(2, 'same')]
    @statuses = { 1 => StoredStatus.new(7, nil, nil), 2 => StoredStatus.new(7, nil, 1) }
  end

  def errors
    GtsMigrator.existing_import_errors(@entries, hash: 'same', target_account_id: 7, lookup: ->(id) { @statuses[id] })
  end

  def test_complete_thread_is_recognized_as_already_imported
    assert_empty errors
    assert_empty GtsMigrator.existing_import_errors([nil, nil], hash: 'same', target_account_id: 7, lookup: ->(_id) { raise 'Unexpected lookup' })
  end

  def test_partial_mapping_or_deleted_part_blocks_reimport
    @entries[1] = nil
    assert_includes errors, 'previous_import_incomplete'
    @entries[1] = Entry.new(2, 'same')
    @statuses[2].deleted_at = Time.now
    assert_includes errors, 'previous_import_missing_or_deleted'
  end

  def test_changed_payload_blocks_reimport
    @entries[0].payload_sha256 = 'changed'
    assert_includes errors, 'previous_import_changed'
  end

  def test_changed_reply_link_blocks_reimport
    @statuses[2].in_reply_to_id = nil
    assert_includes errors, 'previous_import_thread_changed'
  end
end
