require 'securerandom'
require 'devise'
require 'digest'

class User < ApplicationRecord
  self.ignored_columns = %w[banned flattr_username]

  AUTHOR_NOTIFICATION_NONE = 1
  AUTHOR_NOTIFICATION_DISCUSSION = 2
  AUTHOR_NOTIFICATION_COMMENT = 3

  serialize :announcements_seen, Array

  scope :moderators, -> { joins(:roles).where(roles: { name: 'moderator' }) }
  scope :administrators, -> { joins(:roles).where(roles: { name: 'administrator' }) }

  scope :banned, -> { where.not(banned_at: nil) }
  scope :not_banned, -> { where(banned_at: nil) }

  has_many :authors, dependent: :destroy
  has_many :scripts, through: :authors
  has_many :reports_as_reporter, foreign_key: :reporter_id, inverse_of: :reporter, class_name: 'Report'
  has_many :script_reports, foreign_key: 'reporter_id'
  has_many :discussions, foreign_key: 'poster_id', inverse_of: :poster
  has_many :comments, foreign_key: 'poster_id', inverse_of: :poster
  has_many :discussion_subscriptions, dependent: :destroy

  # Gotta to it this way because you can't pass a parameter to a has_many, and we need it has_many
  # to do eager loading.
  Script.subsets.each do |subset|
    has_many "#{subset}_listable_scripts".to_sym, -> { listable(subset) }, class_name: 'Script', through: :authors, source: :script
  end

  has_and_belongs_to_many :roles, dependent: :destroy

  has_many :identities, dependent: :destroy

  has_many :script_sets, dependent: :destroy

  belongs_to :locale, optional: true

  has_and_belongs_to_many :conversations
  has_many :conversation_subscriptions, dependent: :destroy

  before_destroy(prepend: true) do
    scripts.select { |script| script.authors.where.not(user_id: id).none? }.each(&:destroy!)
  end

  BANNED_EMAIL_SALT = '95b68f92d7f373b07dfe101a4b3b46708ae161739b263016eefa3d01762879936507ff2a55442e9a47c681d895de4d905565e2645caff432a987b07457bc005b'.freeze

  after_destroy do
    next unless canonical_email && banned_at

    hash = Digest::SHA1.hexdigest(BANNED_EMAIL_SALT + canonical_email)
    BannedEmailHash.create(email_hash: hash, deleted_at: Time.now, banned_at: banned_at) unless BannedEmailHash.where(email_hash: hash).any?
  end

  def self.email_previously_banned_and_deleted?(email)
    return false unless email

    email = EmailAddress.canonical(email)
    hash = Digest::SHA1.hexdigest(BANNED_EMAIL_SALT + email)
    BannedEmailHash.where(email_hash: hash).any?
  end

  before_validation do
    self.canonical_email = EmailAddress.canonical(email)
  end

  before_save do
    self.email_domain = email ? email.split('@').last : nil
  end

  after_create do
    UserCheckingJob.perform_later(self)
  end

  after_update do
    # To clear partial caches
    scripts.touch_all if saved_change_to_name?
  end

  # Include default devise modules. Others available are:
  # :lockable, :timeoutable and :omniauthable
  devise :database_authenticatable, :registerable, :recoverable, :rememberable, :trackable, :validatable, :confirmable

  # Prevent session termination vulnerability
  # https://makandracards.com/makandra/53562-devise-invalidating-all-sessions-for-a-user
  def authenticatable_salt
    "#{super}#{session_token}"
  end

  def invalidate_all_sessions!
    self.session_token = SecureRandom.hex
  end

  validates_presence_of :name, :profile_markup, :preferred_markup
  validates_uniqueness_of :name, case_sensitive: false
  validates_length_of :profile, maximum: 10_000
  validates_inclusion_of :profile_markup, in: %w[html markdown]
  validates_inclusion_of :preferred_markup, in: %w[html markdown]
  validates :author_email_notification_type_id, inclusion: { in: [AUTHOR_NOTIFICATION_NONE, AUTHOR_NOTIFICATION_DISCUSSION, AUTHOR_NOTIFICATION_COMMENT] }

  validate do
    errors.add(:email) if new_record? && identities.none? && !EmailAddress.valid?(email)
  end

  validate do
    errors.add(:email) if new_record? && email && SpammyEmailDomain.where(domain: email.split('@').last, block_type: SpammyEmailDomain::BLOCK_TYPE_REGISTER).any?
  end

  validate do
    errors.add(:base, 'This email has been banned.') if (new_record? || email_changed? || unconfirmed_email_changed?) && (User.banned.where(canonical_email: canonical_email).any? || User.email_previously_banned_and_deleted?(canonical_email))
  end

  # Devise runs this when password_required?, and we override that so
  # that users don't have to deal with passwords all the time. Add it
  # back when Devise won't run it and the user is actually setting the
  # password.
  validates_confirmation_of :password, if: proc { |u| !u.password_required? && !u.password.nil? }

  strip_attributes

  def discussions_on_scripts_written
    Discussion.not_deleted.where(script: script_ids).order(stat_last_reply_date: :desc)
  end

  def to_param
    slug = slugify(name)
    return id if slug.blank?

    "#{id}-#{slug}"
  end

  def moderator?
    roles.where(name: 'Moderator').any?
  end

  def administrator?
    roles.where(name: 'Administrator').any?
  end

  def generate_webhook_secret
    self.webhook_secret = SecureRandom.hex(64)
  end

  def pretty_signin_methods
    return identity_providers_used.map { |p| Identity.pretty_provider(p) }.compact
  end

  def identity_providers_used
    return identities.map(&:provider).uniq
  end

  def favorite_script_set
    return ScriptSet.where(favorite: true).where(user_id: id).first
  end

  def serializable_hash(options = nil)
    h = super({ only: [:id, :name] }.merge(options || {})).merge({
                                                                   url: Rails.application.routes.url_helpers.user_url(nil, self),
                                                                 })
    # rename listable_scripts to scripts
    unless h['listable_scripts'].nil?
      h['scripts'] = h['listable_scripts']
      h.delete('listable_scripts')
    end
    return h
  end

  # Returns the user's preferred locale code, if we have that locale available, otherwise nil.
  def available_locale_code
    return nil if locale.nil?
    return nil unless locale.ui_available

    return locale.code
  end

  def non_locked_scripts
    return scripts.not_locked
  end

  def lock_all_scripts!(reason:, moderator:, delete_type:)
    non_locked_scripts.each do |s|
      s.delete_reason = reason
      s.locked = true
      s.script_delete_type_id = delete_type
      s.save(validate: false)
      ma_delete = ModeratorAction.new
      ma_delete.moderator = moderator
      ma_delete.script = s
      ma_delete.action = 'Delete and lock'
      ma_delete.reason = reason
      ma_delete.save!
    end
  end

  def posting_permission
    # Assume identity providers are good at stopping bots.
    return :allowed if identities.any?
    return :allowed if email.blank?

    sed = SpammyEmailDomain.find_by(domain: email.split('@').last)
    if sed
      return :blocked if sed.blocked_script_posting?
      return :needs_confirmation if in_confirmation_period?
    end

    return :needs_confirmation unless confirmed?

    :allowed
  end

  def in_confirmation_period?
    created_at > 5.minutes.ago
  end

  def allow_posting_profile?
    posting_permission == :allowed && (scripts.not_deleted.any? || comments.any?)
  end

  def update_trusted_report!
    resolved_count = script_reports.resolved.count + reports_as_reporter.resolved.count
    if resolved_count < 3
      update(trusted_reports: false)
    else
      upheld_count = script_reports.upheld.count + reports_as_reporter.resolved.count
      update(trusted_reports: (upheld_count.to_f / resolved_count) >= 0.75)
    end
  end

  def seen_announcement?(key)
    announcements_seen&.include?(key.to_s)
  end

  def announcement_seen!(key)
    (self.announcements_seen ||= []) << key
    save!
  end

  def ban!(moderator:, reason:, private_reason: nil, ban_related: true)
    return if banned?

    User.transaction do
      ModeratorAction.create!(
        moderator: moderator,
        user: self,
        action: 'Ban',
        reason: reason,
        private_reason: private_reason
      )
      update_columns(banned_at: Time.now)
      script_reports.unresolved.each(&:dismiss!)
    end

    if ban_related
      User.not_banned.where(canonical_email: canonical_email).each do |user|
        user.ban!(moderator: moderator, reason: reason, private_reason: private_reason, ban_related: false)
      end
    end

    Report.unresolved.where(item: self).each do |report|
      report.uphold!(moderator: moderator)
    end
  end

  def report_stats(ignore_report: nil)
    report_scope = reports_as_reporter
    report_scope = report_scope.where.not(id: ignore_report) if ignore_report
    stats = report_scope.group(:result).count
    {
      pending: stats[nil] || 0,
      dismissed: stats['dismissed'] || 0,
      upheld: stats['upheld'] || 0,
    }
  end

  def subscribed_to?(discussion)
    discussion_subscriptions.where(discussion: discussion).any?
  end

  def subscribed_to_conversation?(conversation)
    conversation_subscriptions.where(conversation: conversation).any?
  end

  # Override devise's method to send async. https://github.com/heartcombo/devise#activejob-integration
  def send_devise_notification(notification, *args)
    devise_mailer.send(notification, self, *args).deliver_later
  end

  def needs_to_recaptcha?
    scripts.not_deleted.where('created_at <= ?', 1.month.ago).none?
  end

  def existing_conversation_with(users)
    c = conversations
    users.each { |user| c = c.where(id: user.conversation_ids) }
    c.first
  end

  def delete_all_comments!(by_user: nil)
    discussions.not_deleted.each { |comment| comment.soft_destroy!(by_user: by_user) }
    comments.not_deleted.each { |comment| comment.soft_destroy!(by_user: by_user) }
    Report.unresolved.where(item: comments).each { |report| report.uphold!(moderator: by_user) }
  end

  def banned?
    banned_at.present?
  end

  protected

  def password_required?
    new_record? && identities.empty?
  end

  def confirmation_required?
    false
  end
end
