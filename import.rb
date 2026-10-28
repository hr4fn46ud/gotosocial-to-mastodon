#!/usr/bin/env ruby
# frozen_string_literal: true
# Run via Mastodon's Rails runner. --check-archive also works without Rails.
require 'json'
require 'digest'
require 'pathname'
require 'time'
require 'optparse'
require 'securerandom'
require 'uri'

module GtsMigrator
  VERSION = '0.2.0'
  FORMAT = 'gts-mastodon-migrator/1'
  TABLE = 'gts_migrator_imports'
  class Error < StandardError; end

  def self.historical_id(timestamp, entropy = SecureRandom.random_number(65_536))
    ((timestamp.to_r * 1000).floor << 16) | entropy
  end

  def self.preflight_errors(draft, has_archived_media:)
    # No placeholder attachments: ActiveRecord validates their missing files and
    # would reject every media post. Validate the status alone during a dry run.
    # Its text-presence error is expected for media-only posts whose files have
    # already passed archive checks. Real media are fully validated on import.
    draft.valid?
    draft.errors.reject do |error|
      has_archived_media && error.attribute == :text && error.type == :blank
    end.map(&:full_message)
  end

  def self.partition_records(records, exclude_replies:)
    records.partition do |record|
      status = record.fetch('status')
      !(exclude_replies && (status['in_reply_to_id'] || status['in_reply_to_account_id']))
    end
  end

  def self.part_key(source_key, index)
    index.zero? ? source_key : "#{source_key}/gts-migrator-part/#{index + 1}"
  end

  def self.existing_import_errors(entries, hash:, target_account_id:, lookup:)
    return [] if entries.compact.empty?
    reasons = []
    reasons << 'previous_import_incomplete' if entries.any?(&:nil?)
    entries.each_with_index do |entry, index|
      next unless entry
      reasons << 'previous_import_changed' if entry.payload_sha256 != hash
      status = lookup.call(entry.status_id)
      unless status && status.account_id == target_account_id && status.local? && status.deleted_at.nil?
        reasons << 'previous_import_missing_or_deleted'
        next
      end
      if index > 0 && entries[index - 1] && status.in_reply_to_id != entries[index - 1].status_id
        reasons << 'previous_import_thread_changed'
      end
    end
    reasons.uniq
  end

  # `fits` is supplied by Mastodon's own validator, including its URL, mention,
  # grapheme and content-warning rules. Do not cut inside protected entities.
  def self.split_text(text, fits:, protected_ranges: [])
    return [text] if fits.call(text)
    raise Error, 'Content warning already exceeds the character limit' unless fits.call('')
    units = []
    cursor = 0
    protected_ranges.sort_by(&:first).each do |start, finish|
      raise Error, 'Invalid URL or mention text offsets' unless start >= cursor && finish > start && finish <= text.length
      text[cursor...start].scan(/\s+|\S+/).each { |value| units << [value, false] }
      units << [text[start...finish], true]
      cursor = finish
    end
    text[cursor..-1].scan(/\s+|\S+/).each { |value| units << [value, false] }
    parts = []
    current = +''
    units.each do |value, protected|
      if fits.call(current + value)
        current += value
      elsif fits.call(value)
        parts << current unless current.empty?
        current = value.dup
      else
        raise Error, 'A URL or mention cannot fit alongside the content warning' if protected
        value.scan(/\X/).each do |grapheme|
          if fits.call(current + grapheme)
            current += grapheme
          else
            raise Error, 'A grapheme cannot fit alongside the content warning' unless fits.call(grapheme)
            parts << current unless current.empty?
            current = grapheme.dup
          end
        end
      end
    end
    parts << current unless current.empty?
    raise Error, 'Could not split the text without losing content' unless parts.join == text && parts.all? { |part| fits.call(part) }
    parts
  end

  class Archive
    attr_reader :root, :manifest, :records

    def initialize(directory)
      @root = Pathname.new(directory).realpath
      @manifest = JSON.parse(path('manifest.json').read)
      raise Error, 'Incomplete archive or unsupported archive format' unless @manifest['format'] == FORMAT && @manifest['complete'] == true
      raise Error, 'Invalid file manifest' unless @manifest['files'].is_a?(Hash) && @manifest['posts'].is_a?(Array)
      @manifest['files'].each do |name, meta|
        file = path(name)
        raise Error, "File size mismatch: #{name}" unless file.size == meta.fetch('size')
        raise Error, "Checksum mismatch: #{name}" unless Digest::SHA256.file(file).hexdigest == meta.fetch('sha256')
      end
      identity = read('identity.json')
      raise Error, 'Source identity mismatch' unless identity == @manifest['source']
      raise Error, 'Source account is missing' unless identity['account_url'].is_a?(String) && !identity['account_url'].empty?
      account = read('account.json')
      raise Error, 'Account metadata mismatch' unless account['id'].to_s == identity['account_id'] && account['url'] == identity['account_url']
      seen = {}
      @records = @manifest['posts'].map do |name|
        record = read(name)
        status = record.fetch('status')
        raise Error, 'Unexpected author in archive' unless status.fetch('account').fetch('id').to_s == identity['account_id']
        id = status.fetch('id')
        raise Error, 'Invalid or duplicate status ID' unless id.is_a?(String) && id.match?(/\A[A-Za-z0-9_-]{1,128}\z/) && !seen[id]
        seen[id] = true
        created = Time.iso8601(status.fetch('created_at'))
        raise Error, "Invalid timestamp: #{id}" unless created > Time.at(0) && created < Time.now
        raise Error, 'Invalid media list' unless record['media'].is_a?(Array)
        source_media = status.fetch('media_attachments', [])
        unless record['media'].map { |m| m.fetch('id') } == source_media.map { |m| m.fetch('id') }
          raise Error, 'Original media missing or media order does not match'
        end
        record['media'].each do |media|
          file = path(media.fetch('path'))
          meta = @manifest['files'].fetch(media['path'])
          unless file.size == media.fetch('size') && meta['sha256'] == media.fetch('sha256') && meta['size'] == media['size']
            raise Error, 'Media metadata mismatch'
          end
        end
        record
      end
    end

    def path(name)
      raise Error, 'Invalid archive path' unless name.is_a?(String) && !Pathname.new(name).absolute? && !name.split('/').include?('..')
      candidate = @root.join(name).realpath
      raise Error, 'Archive path escapes the archive directory' unless candidate.to_s.start_with?(@root.to_s + File::SEPARATOR) && candidate.file?
      candidate
    end

    def read(name)
      raise Error, "File has no manifest checksum: #{name}" unless @manifest['files'].key?(name)
      JSON.parse(path(name).read)
    end

    def source_key(record)
      # Account URL and ID are stable across exports and don't depend on tokens.
      @manifest.fetch('source').fetch('account_url') + '#' + record.fetch('status').fetch('id')
    end
  end

  # Archive validation remains available with the system Ruby, without a Mastodon installation.
  def self.options(argv)
    opts = { apply: false, skip: false, followers: false, exclude_replies: false, split_long_posts: false }
    parser = OptionParser.new do |o|
      o.banner = 'import.rb --archive DIR --target-user NAME [--apply]'
      o.on('--version', 'Print the tool version') { puts "gotosocial-to-mastodon #{VERSION}"; exit }
      o.on('--archive DIR', 'Local archive directory') { |v| opts[:archive] = v }
      o.on('--target-user NAME', 'Existing local Mastodon username') { |v| opts[:target] = v }
      o.on('--apply', 'Write posts after a successful preflight') { opts[:apply] = true }
      o.on('--check-archive', 'Check archive integrity only; no Rails installation required') { opts[:check] = true }
      o.on('--skip-unsupported', 'Skip posts marked unsupported in the report') { opts[:skip] = true }
      o.on('--exclude-replies', 'Exclude all archived replies, including self-replies') { opts[:exclude_replies] = true }
      o.on('--split-long-posts', 'Split long posts into complete, linked threads') { opts[:split_long_posts] = true }
      o.on('--include-followers-only', 'Include followers-only posts for the TARGET account followers') { opts[:followers] = true }
      o.on('--report FILE', 'Save the preflight report as JSON') { |v| opts[:report] = v }
      o.on('-h', '--help') { puts o; exit }
    end
    parser.parse!(argv)
    raise Error, 'Unknown arguments' unless argv.empty?
    raise Error, '--archive is required' unless opts[:archive]
    raise Error, '--target-user is required' unless opts[:target] || opts[:check]
    opts
  end

  class Importer
    def initialize(archive, opts)
      @archive, @opts = archive, opts
      @connection = ApplicationRecord.connection
      @version = Mastodon::Version.to_s
      # Inspected upstream internals; extending this range needs a compatibility review.
      raise Error, "Unsupported Mastodon version: #{@version}; supported: 4.7.3" unless @version == '4.7.3'
      raise Error, 'Target must be a local username without @ or a domain' unless opts[:target].match?(/\A[A-Za-z0-9_]+\z/)
      @account = Account.local.find_by!(username: opts[:target])
      raise Error, 'Target account is not active' unless @account.user && !@account.suspended? && @account.moved_to_account_id.nil?
      source_host = URI.parse(@archive.manifest.fetch('source').fetch('server')).host
      local_host = Rails.configuration.x.local_domain.to_s.split(':').first
      raise Error, 'Same-domain conversion requires an identity migration and is not supported' if source_host.to_s.downcase == local_host.downcase
      @mapping = Class.new(ApplicationRecord) do
        self.table_name = TABLE
      end
      @source_ids = archive.records.to_h { |r| [r['status']['id'], r] }
      @plans = {}
    end

    def text_for(record)
      source = record.fetch('source')
      return source.fetch('text') if source['content_type'] == 'text/plain'
      # GTS commonly stores Markdown; importing that verbatim would expose its syntax.
      fragment = Nokogiri::HTML.fragment(record.fetch('status').fetch('content', ''))
      fragment.css('script,style').remove
      fragment.css('br').each { |node| node.replace(Nokogiri::XML::Text.new("\n", fragment.document)) }
      fragment.css('a').each do |node|
        href = node['href'].to_s
        label = node.text
        value = if node['class'].to_s.match?(/mention|hashtag/) || label == href || !href.match?(%r{\Ahttps?://})
                  label
                else
                  "#{label} (#{href})"
                end
        node.replace(Nokogiri::XML::Text.new(value, fragment.document))
      end
      fragment.css('p,div,li,blockquote,pre,h1,h2,h3,h4,h5,h6').each { |node| node.add_next_sibling(Nokogiri::XML::Text.new("\n\n", fragment.document)) }
      fragment.text.gsub(/\n{3,}/, "\n\n").strip
    end

    def plan(record, visiting = {})
      s = record.fetch('status')
      sid = s.fetch('id')
      return @plans[sid] if @plans.key?(sid)
      raise Error, 'Cyclic reply chain' if visiting[sid]
      visiting = visiting.merge(sid => true)
      reasons = []
      reasons << 'boost' if s['reblog']
      reasons << 'poll' if s['poll']
      reasons << 'quote' if s['quote'] || s['quote_id'] || s['quoted_status_id']
      visibility = { 'public' => 'public', 'unlisted' => 'unlisted', 'unlocked' => 'unlisted', 'private' => 'private' }[s['visibility']]
      reasons << 'visibility' unless visibility
      reasons << 'followers_only_requires_option' if visibility == 'private' && !@opts[:followers]
      reasons << 'media_limit' if record['media'].size > Status::MEDIA_ATTACHMENTS_LIMIT
      reasons << 'media_type' if record['media'].any? { |m| !%w(image gifv video audio).include?(m['type']) }
      if record['media'].size > 1 && record['media'].any? { |m| %w(video audio gifv).include?(m['type']) }
        reasons << 'mixed_media'
      end
      text = text_for(record)
      parent = s['in_reply_to_id']
      if parent
        if s['in_reply_to_account_id'].to_s != @archive.manifest['source']['account_id'] || !@source_ids[parent]
          reasons << 'external_or_missing_reply_parent'
        else
          parent_plan = plan(@source_ids[parent], visiting)
          reasons << 'unsupported_reply_parent' unless parent_plan[:reasons].empty?
        end
      end
      payload = { text: text, spoiler_text: record['source']['spoiler_text'] || s['spoiler_text'] || '',
                  created_at: s.fetch('created_at'), edited_at: s['edited_at'], visibility: visibility,
                  sensitive: s['sensitive'] == true, language: s['language'], parent: parent,
                  media: record['media'].map { |m| m.slice('sha256', 'type', 'description', 'focus') } }
      parts = [text]
      if @opts[:split_long_posts] && visibility
        validator = StatusLengthValidator.new
        candidate = Struct.new(:text, :spoiler_text).new(nil, payload[:spoiler_text])
        fits = lambda do |value|
          candidate.text = value
          !validator.send(:too_long?, candidate)
        end
        entities = Extractor.remove_overlapping_entities(
          Extractor.extract_urls_with_indices(text, extract_url_without_protocol: false) +
          Extractor.extract_mentions_or_lists_with_indices(text)
        )
        begin
          parts = GtsMigrator.split_text(text, fits: fits, protected_ranges: entities.map { |e| e.fetch(:indices) })
        rescue GtsMigrator::Error => e
          reasons << "cannot_split: #{e.message}"
        end
      end
      payload[:thread_parts] = parts if parts.length > 1
      hash = Digest::SHA256.hexdigest(JSON.generate(payload))
      entries = parts.each_index.map do |index|
        if @connection.data_source_exists?(TABLE)
          @mapping.find_by(target_account_id: @account.id, source_key: GtsMigrator.part_key(@archive.source_key(record), index))
        end
      end
      existing = entries.compact.first
      reasons.concat(GtsMigrator.existing_import_errors(entries, hash: hash, target_account_id: @account.id,
                                                       lookup: ->(id) { Status.unscoped.find_by(id: id) }))
      parts.each_with_index do |part, index|
        draft = @account.statuses.new(text: part, spoiler_text: payload[:spoiler_text],
                                      visibility: visibility || 'direct', sensitive: payload[:sensitive], language: payload[:language])
        reasons.concat(GtsMigrator.preflight_errors(draft, has_archived_media: index.zero? && !record['media'].empty?))
      end
      record['media'].each do |m|
        if m['description'].to_s.length > MediaAttachment::MAX_DESCRIPTION_LENGTH
          reasons << 'media_description_too_long'
        end
        limit = %w(video audio gifv).include?(m['type']) ? MediaAttachment::VIDEO_LIMIT : MediaAttachment::IMAGE_LIMIT
        reasons << 'media_file_too_large' if m.fetch('size') >= limit
      end
      result = { id: sid, source_key: @archive.source_key(record), payload: payload, sha256: hash,
                 reasons: reasons.uniq, existing: existing, entries: entries, parts: parts, record: record, parent: parent,
                 action: existing ? 'already_imported' : 'import' }
      @plans[sid] = result
    end

    def report(plans, ignored: [])
      { tool_version: VERSION, mastodon_version: @version, target_user: @account.username, apply: @opts[:apply],
        exclude_replies: @opts[:exclude_replies], ignored_replies: ignored.length,
        split_long_posts: @opts[:split_long_posts],
        split_threads: plans.count { |p| p[:reasons].empty? && (p[:parts] || []).length > 1 },
        statuses_to_create: plans.select { |p| p[:reasons].empty? && !p[:existing] }.sum { |p| (p[:parts] || ['']).length },
        importable: plans.count { |p| p[:reasons].empty? && !p[:existing] },
        already_imported: plans.count { |p| p[:reasons].empty? && p[:existing] },
        unsupported: plans.count { |p| !p[:reasons].empty? },
        posts: plans.map do |p|
          status = p[:record].fetch('status')
          reply_kind = if !status['in_reply_to_id']
                         'none'
                       elsif status['in_reply_to_account_id'].to_s != @archive.manifest['source']['account_id']
                         'other_account'
                       elsif !@source_ids[status['in_reply_to_id']]
                         'own_parent_missing'
                       else
                         'own_parent_in_archive'
                       end
          { id: p[:id], action: p[:reasons].empty? ? p[:action] : 'skip', reasons: p[:reasons],
            parts: (p[:parts] || ['']).length,
            source_visibility: status['visibility'], reply_kind: reply_kind }
        end + ignored.map do |record|
          status = record.fetch('status')
          { id: status.fetch('id'), action: 'ignore', reasons: ['reply_excluded'],
            source_visibility: status['visibility'] }
        end }
    end

    def run
      # A session advisory lock prevents two importers from preflighting/writing the same target concurrently.
      lock_id = Digest::SHA256.hexdigest("gts-migrator:#{@account.id}")[0, 15].to_i(16)
      locked = false
      if @opts[:apply]
        locked = @connection.select_value("SELECT pg_try_advisory_lock(#{lock_id})")
        raise Error, 'An import is already running for this target account' unless locked
      end
      selected, ignored = GtsMigrator.partition_records(@archive.records, exclude_replies: @opts[:exclude_replies])
      plans = selected.map { |r| plan(r) }
      # Hash insertion order is topological because parents are planned recursively first.
      ordered = @plans.values
      output = report(plans, ignored: ignored)
      puts JSON.pretty_generate(output)
      File.write(@opts[:report], JSON.pretty_generate(output) + "\n", mode: 'w', perm: 0o600) if @opts[:report]
      if output[:unsupported] > 0 && !@opts[:skip]
        raise Error, 'Unsupported posts found; review the report. Use --skip-unsupported to explicitly omit them.'
      end
      return unless @opts[:apply]
      ensure_table!
      ordered.each do |item|
        next unless item[:reasons].empty?
        if item[:existing]
          item[:target_id] = item[:existing].status_id
          item[:target_ids] = item[:entries].map(&:status_id)
          next
        end
        import_one(item)
        puts "Imported: #{item[:id]} -> #{item[:target_ids].join(', ')}"
      end
      puts "Import complete: #{output[:importable]} source posts, #{output[:statuses_to_create]} new statuses; #{output[:already_imported]} source posts were already imported."
    ensure
      @connection.execute("SELECT pg_advisory_unlock(#{lock_id})") if locked
    end

    def ensure_table!
      @connection.create_table(TABLE, if_not_exists: true) do |t|
        t.bigint :target_account_id, null: false
        t.text :source_key, null: false
        t.bigint :status_id, null: false
        t.string :payload_sha256, null: false
        t.timestamps
        t.index [:target_account_id, :source_key], unique: true, name: 'index_gts_migrator_source_target'
      end
      @mapping.reset_column_information
    end

    def allocate_thread_ids(timestamp, count)
      raise Error, 'Too many thread parts for one historical timestamp' unless count.between?(1, 65_536)
      100.times do
        start = SecureRandom.random_number(65_537 - count)
        ids = Array.new(count) { |index| GtsMigrator.historical_id(timestamp, start + index) }
        return ids unless Status.unscoped.where(id: ids).exists?
      end
      raise Error, 'Could not allocate historical status IDs'
    end

    def build_status(item, text, timestamp, id, parent)
      payload = item[:payload]
      status = @account.statuses.new(text: text, spoiler_text: payload[:spoiler_text],
                                    visibility: payload[:visibility], sensitive: payload[:sensitive],
                                    language: payload[:language], created_at: timestamp,
                                    updated_at: Time.now.utc, edited_at: payload[:edited_at] && Time.iso8601(payload[:edited_at]))
      # Same original timestamp for every part; increasing IDs preserve thread order.
      status.override_timestamps = true
      status.id = id
      status.thread = parent if parent
      status.define_singleton_method(:trigger_create_webhooks) {}
      status.define_singleton_method(:trigger_update_webhooks) {}
      status.define_singleton_method(:announce_new_content_to_subscribed_fasp) {}
      status.define_singleton_method(:announce_updated_content_to_subscribed_fasp) {}
      status.define_singleton_method(:announce_trends_to_subscribed_fasp) {}
      status
    end

    def import_one(item)
      media_created = []
      begin
        @connection.transaction do
          payload = item[:payload]
          timestamp = Time.iso8601(payload[:created_at])
          parts = item.fetch(:parts)
          ids = allocate_thread_ids(timestamp, parts.length)
          parent = nil
          if item[:parent]
            parent_id = @plans.fetch(item[:parent]).fetch(:target_id)
            parent = Status.unscoped.find(parent_id)
          end
          item[:record]['media'].each do |m|
            attachment = @account.media_attachments.new(description: m['description'])
            attachment.delay_processing = false
            media_created << attachment
            File.open(@archive.path(m['path']), 'rb') { |f| attachment.file = f; attachment.save! }
            if m['focus'].is_a?(Hash) && m['focus'].key?('x') && m['focus'].key?('y')
              attachment.focus = "#{m['focus']['x']},#{m['focus']['y']}"
              attachment.save!
            end
          end
          parts.each_with_index do |text, index|
            status = build_status(item, text, timestamp, ids[index], parent)
            status.media_attachments = index.zero? ? media_created : []
            status.ordered_media_attachment_ids = index.zero? ? media_created.map(&:id) : []
            status.save!
            ProcessHashtagsService.new.call(status)
            @mapping.create!(target_account_id: @account.id, source_key: GtsMigrator.part_key(item[:source_key], index),
                             status_id: status.id, payload_sha256: item[:sha256])
            parent = status
          end
          item[:target_ids] = ids
          item[:target_id] = ids.first
        end
      rescue StandardError
        # Database rollback cannot remove already written object-store files.
        media_created.each do |media|
          next if media.persisted? && MediaAttachment.unscoped.exists?(id: media.id)
          begin
            media.file.destroy
            media.thumbnail.destroy
          rescue StandardError
            warn 'Could not clean up media after rollback; storage cleanup is required'
          end
        end
        raise
      end
    end
  end

  def self.main(argv)
    opts = options(argv)
    archive = Archive.new(opts[:archive])
    if opts[:check]
      puts "Archive verified: #{archive.records.length} posts, all checksums match"
      return 0
    end
    raise Error, 'Run the importer inside Mastodon with bundle exec rails runner' unless defined?(Rails) && defined?(Status)
    Importer.new(archive, opts).run
    0
  rescue StandardError => e
    warn "Error: #{e.class}: #{e.message}"
    1
  end
end

exit GtsMigrator.main(ARGV) unless ENV['GTS_MIGRATOR_LIBRARY_ONLY'] == '1'
