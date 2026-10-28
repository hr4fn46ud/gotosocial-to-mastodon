# frozen_string_literal: true
require 'minitest/autorun'
ENV['GTS_MIGRATOR_LIBRARY_ONLY'] = '1'
require_relative '../import'

class PreflightTest < Minitest::Test
  ValidationError = Struct.new(:attribute, :type, :full_message)

  class Draft
    attr_reader :errors, :validated
    def initialize(errors)
      @errors = errors
    end

    def valid?
      @validated = true
      errors.empty?
    end

    def media_attachments=(_value)
      raise 'A dry run must never add placeholder media'
    end
  end

  def check(errors, media:)
    draft = Draft.new(errors)
    result = GtsMigrator.preflight_errors(draft, has_archived_media: media)
    assert draft.validated
    result
  end

  def test_media_post_with_text_needs_no_placeholder_media
    assert_empty check([], media: true)
  end

  def test_media_only_post_accepts_expected_text_presence_error
    error = ValidationError.new(:text, :blank, "Text can't be blank")
    assert_empty check([error], media: true)
  end

  def test_empty_post_without_media_still_fails
    error = ValidationError.new(:text, :blank, "Text can't be blank")
    assert_equal ["Text can't be blank"], check([error], media: false)
  end

  def test_length_limit_is_never_suppressed
    error = ValidationError.new(:text, :invalid, 'Text character limit of 500 exceeded')
    assert_equal [error.full_message], check([error], media: true)
  end

  def test_unrelated_error_is_never_suppressed
    error = ValidationError.new(:account, :blank, "Account can't be blank")
    assert_equal [error.full_message], check([error], media: true)
  end

  def test_media_error_is_never_suppressed
    error = ValidationError.new(:media_attachments, :invalid, 'Media attachments is invalid')
    assert_equal [error.full_message], check([error], media: true)
  end
end
