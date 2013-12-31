# == Schema Information
#
# Table name: watchlists
#
#  id               :integer          not null, primary key
#  user_id          :integer
#  anime_id         :integer
#  status           :string(255)
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  episodes_watched :integer          default(0)
#  rating           :decimal(2, 1)
#  last_watched     :datetime
#  imported         :boolean
#  private          :boolean          default(FALSE)
#  notes            :text
#  rewatched_times  :integer          default(0)
#  rewatching       :boolean
#

class LibraryEntry < ActiveRecord::Base
  self.table_name = "watchlists"

  attr_accessible :user_id, :anime_id, :status, :rating

  belongs_to :user
  belongs_to :anime
  has_many :stories, dependent: :destroy, foreign_key: :watchlist_id

  validates :user, :anime, :status, presence: true
  validates :user_id, uniqueness: {scope: :anime_id}

  VALID_STATUSES = ["Currently Watching", "Plan to Watch", "Completed", "On Hold",
                    "Dropped"]
  validates :status, inclusion: {in: VALID_STATUSES}

  validate :rating_is_valid
  def rating_is_valid
    if self.rating and (self.rating <= 0 or self.rating > 5 or (self.rating * 2) % 1 != 0)
      errors.add(:rating, "is not in the valid range")
    end
  end

  # FIXME Need to write tests for this. Also need to improve this interface. :/
  def generate_status_change_story
    if self.status_changed?
      Substory.from_action({
        user_id: self.user_id,
        action_type: "watchlist_status_update",
        anime_id: self.anime.slug,
        old_status: self.status_was,
        new_status: self.status,
        time: Time.now
      })
    end
  end

  before_save do
    self.generate_status_change_story

    # Track aggregated rating frequencies for the show.
    # Need the hand-written SQL because there's no way to other way to atomically
    # increment/decrement hstore fields.
    if self.persisted?
      if self.rating_changed?
        okey = (self.rating_was || "nil").to_s
        nkey = (self.rating || "nil").to_s
        Anime.update_all(
          "rating_frequencies = COALESCE(rating_frequencies, hstore(ARRAY[]::text[])) || hstore('#{okey}', ((COALESCE((rating_frequencies -> '#{okey}'), '0'))::integer - 1)::text) || hstore('#{nkey}', ((COALESCE((rating_frequencies -> '#{nkey}'), '0'))::integer + 1)::text)",
          "id = #{self.anime.id}"
        )
      end
    else
      # New record -- just need to do an increment.
      nkey = (self.rating || "nil").to_s
      Anime.update_all(
        "rating_frequencies = COALESCE(rating_frequencies, hstore(ARRAY[]::text[])) || hstore('#{nkey}', ((COALESCE((rating_frequencies -> '#{nkey}'), '0'))::integer + 1)::text)",
        "id = #{self.anime.id}"
      )
    end
  end

  after_create do
    Anime.increment_counter 'user_count', self.anime_id
  end

  before_destroy do
    Anime.decrement_counter 'user_count', self.anime_id

    # Update the shows rating frequencies. Handwritten SQL for atomicity.
    nkey = (self.rating || "nil").to_s
    Anime.update_all(
      "rating_frequencies = COALESCE(rating_frequencies, hstore(ARRAY[]::text[])) || hstore('#{nkey}', ((COALESCE((rating_frequencies -> '#{nkey}'), '0'))::integer - 1)::text)",
      "id = #{self.anime.id}"
    )
  end
end