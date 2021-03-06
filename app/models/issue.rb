class Issue < ActiveRecord::Base
  include EmptyArrayRemovable

  store_accessor :meta, :github_issue_id, :github_issue_number, :bitbucket_issue_id,
    :github_issue_comments_count, :github_issue_html_url, :github_labels, :bitbucket_issue_comment_count

  has_many :users, :through => :user_to_issue_connections

  has_many :user_to_issue_connections, :dependent => :destroy

  belongs_to :project, :counter_cache => true

  has_many :sections, :through => :issue_to_section_connections

  has_many :issue_to_section_connections, :dependent => :destroy

  validates :title, :length => { :maximum => Settings.max_string_field_size }, :presence => true

  validates :body, :length => { :maximum => Settings.max_text_field_size }, :allow_blank => true

  before_create :assign_issue_to_section_connections

  before_update :check_section_connections

  def assign_issue_to_section_connections
    project.sections.includes(:project).where('ARRAY[?]::varchar[] && tags', tags).each do |section|
      build_section_connection(section)
    end

    project.sections.where(:include_all => true).each do |section|
      build_section_connection(section)
    end
  end

  def parse_tags(source_column_id, target_column_id)
    tags - (project.columns.where(:id => source_column_id.to_i).first.try(:tags).to_a & tags) +
      project.columns.where(:id => target_column_id.to_i).first.try(:tags).to_a
  end

  def enqueue_issue_sync(user_id)
    return unless github_issue_id.present?

    SyncGithubIssueWorker.perform_async(id, user_id)
  end

  def sync_with_github(user_id)
    user = User.where(:id => user_id).first

    return unless user.present?

    client = user.github_client

    return unless client.present?

    client.update_issue(project.github_full_name, github_issue_number, :labels => tags)
  end

  def parse_attributes_for_update(attributes)
    { :id => attributes[:id], :tags => parse_tags(attributes[:source_column_id], attributes[:target_column_id]) }
  end

  class << self
    def user_change_issue(issue_id, user_id)
      issue = Issue.where(:id => issue_id).first

      return unless issue.present?

      issue.enqueue_issue_sync(user_id) if issue.github_issue_id.present?

      NotificationWorker.perform_async(issue_id, user_id)
    end
  end

  private

  def build_section_connection(section)
    column = project.columns.where('ARRAY[?]::varchar[] && tags', tags).first

    return unless column.present?

    connection = issue_to_section_connections.where(:project_id => project_id, :section_id => section.id).
      first_or_initialize

    connection.issue_order = column.max_order(section) + 1

    connection.column_id = column.id

    self.issue_to_section_connections << connection
  end

  def check_section_connections
    assign_issue_to_section_connections if tags_changed?    
  end
end
