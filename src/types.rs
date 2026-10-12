use serde::{Deserialize, Serialize};

#[derive(Clone, PartialEq, Debug, Deserialize, Serialize)]
pub struct Channel {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<i64>,
    pub name: String,
    pub url: Option<String>,
    pub group: Option<String>,
    pub image: Option<String>,
    pub media_type: u8,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_id: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub series_id: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub group_id: Option<i64>,
    pub favorite: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stream_id: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tv_archive: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub season_id: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub episode_num: Option<i64>,
    #[serde(default)]
    pub locked: bool,
}

#[derive(Clone, PartialEq, Debug, Deserialize, Serialize, Default)]
pub struct Season {
    pub id: Option<i64>,
    pub name: String,
    pub season_number: i64,
    pub image: Option<String>,
    pub series_id: i64,
    pub source_id: i64,
}

#[derive(Clone, PartialEq, Debug, Deserialize, Serialize)]
pub struct Source {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<i64>,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url_origin: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub username: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub password: Option<String>,
    pub source_type: u8,
    pub enabled: bool,
    pub user_agent: Option<String>,
    pub stream_user_agent: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_updated: Option<i64>,
    #[serde(default)]
    pub locked: bool,
}

#[derive(Clone, PartialEq, Debug, Deserialize, Serialize)]
pub struct Settings {
    pub use_stream_caching: Option<bool>,
    pub default_view: Option<u8>,
    pub refresh_on_start: Option<bool>,
    pub default_sort: Option<u8>,
    pub force_tv_mode: Option<bool>,
    pub show_livestreams: Option<bool>,
    pub show_movies: Option<bool>,
    pub show_series: Option<bool>,
    pub volume_brightness_gestures: Option<bool>,
    pub swipe_to_change_channel: Option<bool>,
    pub double_tap_seek: Option<bool>,
    pub seek_seconds: Option<u32>,
    pub picture_in_picture: Option<bool>,
    pub keep_audio_after_pip: Option<bool>,
    pub show_continue_watching: Option<bool>,
    pub autoplay_next_episode: Option<bool>,
    pub autoplay_countdown_seconds: Option<u32>,
    pub show_epg: Option<bool>,
    pub parental_pin: Option<String>,
}

#[derive(Clone, PartialEq, Debug, Deserialize, Serialize)]
pub struct Filters {
    pub query: Option<String>,
    pub source_ids: Vec<i64>,
    pub media_types: Option<Vec<u8>>,
    pub view_type: u8,
    pub page: u8,
    pub series_id: Option<i64>,
    pub group_id: Option<i64>,
    pub use_keywords: bool,
    pub sort: u8,
    pub season: Option<i64>,
    pub favorite_list_id: Option<i64>,
    pub include_locked: bool,
}

#[derive(Clone, PartialEq, Debug, Deserialize, Serialize, Default)]
pub struct ChannelHttpHeaders {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub channel_id: Option<i64>,
    pub referrer: Option<String>,
    pub user_agent: Option<String>,
    pub http_origin: Option<String>,
    pub ignore_ssl: Option<bool>,
}

#[derive(Clone, PartialEq, Debug, Deserialize, Serialize)]
pub struct ChannelPreserve {
    pub name: String,
    pub favorite: bool,
    pub last_watched: Option<i64>,
    #[serde(default)]
    pub is_group: bool,
    #[serde(default)]
    pub list_ids: Vec<i64>,
}

#[derive(Clone, PartialEq, Debug, Deserialize, Serialize)]
pub struct FavoriteList {
    pub id: i64,
    pub name: String,
}

#[derive(Clone, PartialEq, Debug, Deserialize, Serialize)]
pub struct XtreamStatus {
    pub user_info: XtreamStatusUserInfo,
}

#[derive(Clone, PartialEq, Debug, Deserialize, Serialize)]
pub struct XtreamStatusUserInfo {
    pub exp_date: serde_json::Value,
}

#[derive(Clone, PartialEq, Debug)]
pub struct ContinueWatching {
    pub channel: Channel,
    pub position: i64,
    pub duration: Option<i64>,
    pub series_name: Option<String>,
}

#[derive(Clone, PartialEq, Debug, Deserialize, Serialize)]
pub struct Backup {
    pub app: String,
    pub version: u32,
    pub created_at: i64,
    pub sources: Vec<BackupSource>,
    #[serde(default)]
    pub settings: std::collections::HashMap<String, String>,
    #[serde(default)]
    pub favorite_lists: Vec<String>,
    #[serde(default)]
    pub channels: Vec<BackupChannel>,
    #[serde(default)]
    pub positions: Vec<BackupPosition>,
    #[serde(default)]
    pub locked_groups: Vec<BackupLockedGroup>,
}

#[derive(Clone, PartialEq, Debug, Deserialize, Serialize)]
pub struct BackupLockedGroup {
    pub source: String,
    pub name: String,
}

#[derive(Clone, PartialEq, Debug)]
pub struct EpgProgram {
    pub title: String,
    pub description: Option<String>,
    pub start: i64,
    pub stop: i64,
    pub has_archive: bool,
    pub catchup_url: Option<String>,
}

#[derive(Clone, PartialEq, Debug)]
pub struct EpgNowNext {
    pub channel_id: i64,
    pub now: Option<EpgProgram>,
    pub next: Option<EpgProgram>,
}

#[derive(Clone, PartialEq, Debug, Deserialize, Serialize)]
pub struct BackupSource {
    pub name: String,
    #[serde(default)]
    pub locked: bool,
    pub source_type: u8,
    pub url: Option<String>,
    pub username: Option<String>,
    pub password: Option<String>,
    pub user_agent: Option<String>,
    pub stream_user_agent: Option<String>,
    pub enabled: bool,
}

#[derive(Clone, PartialEq, Debug, Deserialize, Serialize)]
pub struct BackupChannel {
    pub source: String,
    pub name: String,
    pub favorite: bool,
    pub last_watched: Option<i64>,
    #[serde(default)]
    pub lists: Vec<String>,
}

#[derive(Clone, PartialEq, Debug, Deserialize, Serialize)]
pub struct BackupPosition {
    pub source: String,
    pub name: String,
    pub url: Option<String>,
    pub position: i64,
    pub duration: Option<i64>,
    pub updated_at: Option<i64>,
}
