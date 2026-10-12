use std::collections::HashMap;

use anyhow::Result;

use crate::{sql, types::Settings};

pub const USE_STREAM_CACHING: &str = "useStreamingCaching";
pub const DEFAULT_VIEW: &str = "defaultView";
pub const REFRESH_ON_START: &str = "refreshOnStart";
pub const DEFAULT_SORT: &str = "defaultSort";
pub const FORCE_TV_MODE: &str = "forceTvMode";
pub const SHOW_LIVESTREAMS: &str = "showLivestreams";
pub const SHOW_MOVIES: &str = "showMovies";
pub const SHOW_SERIES: &str = "showSeries";
pub const VOLUME_BRIGHTNESS_GESTURES: &str = "volumeBrightnessGestures";
pub const SWIPE_TO_CHANGE_CHANNEL: &str = "swipeToChangeChannel";
pub const DOUBLE_TAP_SEEK: &str = "doubleTapSeek";
pub const SEEK_SECONDS: &str = "seekSeconds";
pub const PICTURE_IN_PICTURE: &str = "pictureInPicture";
pub const KEEP_AUDIO_AFTER_PIP: &str = "keepAudioAfterPip";
pub const SHOW_CONTINUE_WATCHING: &str = "showContinueWatching";
pub const AUTOPLAY_NEXT_EPISODE: &str = "autoplayNextEpisode";
pub const AUTOPLAY_COUNTDOWN_SECONDS: &str = "autoplayCountdownSeconds";
pub const SHOW_EPG: &str = "showEpg";
pub const PARENTAL_PIN: &str = "parentalPin";

pub fn get_settings() -> Result<Settings> {
    let map = sql::get_settings()?;
    let settings = Settings {
        use_stream_caching: map.get(USE_STREAM_CACHING).and_then(|s| s.parse().ok()),
        default_view: map.get(DEFAULT_VIEW).and_then(|s| s.parse().ok()),
        refresh_on_start: map.get(REFRESH_ON_START).and_then(|s| s.parse().ok()),
        default_sort: map.get(DEFAULT_SORT).and_then(|s| s.parse().ok()),
        force_tv_mode: map.get(FORCE_TV_MODE).and_then(|s| s.parse().ok()),
        show_livestreams: map.get(SHOW_LIVESTREAMS).and_then(|s| s.parse().ok()),
        show_movies: map.get(SHOW_MOVIES).and_then(|s| s.parse().ok()),
        show_series: map.get(SHOW_SERIES).and_then(|s| s.parse().ok()),
        volume_brightness_gestures: map
            .get(VOLUME_BRIGHTNESS_GESTURES)
            .and_then(|s| s.parse().ok()),
        swipe_to_change_channel: map
            .get(SWIPE_TO_CHANGE_CHANNEL)
            .and_then(|s| s.parse().ok()),
        double_tap_seek: map.get(DOUBLE_TAP_SEEK).and_then(|s| s.parse().ok()),
        seek_seconds: map.get(SEEK_SECONDS).and_then(|s| s.parse().ok()),
        picture_in_picture: map.get(PICTURE_IN_PICTURE).and_then(|s| s.parse().ok()),
        keep_audio_after_pip: map.get(KEEP_AUDIO_AFTER_PIP).and_then(|s| s.parse().ok()),
        show_continue_watching: map.get(SHOW_CONTINUE_WATCHING).and_then(|s| s.parse().ok()),
        autoplay_next_episode: map.get(AUTOPLAY_NEXT_EPISODE).and_then(|s| s.parse().ok()),
        autoplay_countdown_seconds: map
            .get(AUTOPLAY_COUNTDOWN_SECONDS)
            .and_then(|s| s.parse().ok()),
        show_epg: map.get(SHOW_EPG).and_then(|s| s.parse().ok()),
        parental_pin: map.get(PARENTAL_PIN).filter(|s| !s.is_empty()).cloned(),
    };
    Ok(settings)
}

pub fn update_settings(settings: Settings) -> Result<()> {
    let mut map: HashMap<String, Option<String>> = HashMap::with_capacity(5);

    if let Some(use_stream_caching) = settings.use_stream_caching {
        map.insert(
            USE_STREAM_CACHING.to_string(),
            Some(use_stream_caching.to_string()),
        );
    }
    if let Some(default_view) = settings.default_view {
        map.insert(DEFAULT_VIEW.to_string(), Some(default_view.to_string()));
    }
    if let Some(refresh_on_start) = settings.refresh_on_start {
        map.insert(
            REFRESH_ON_START.to_string(),
            Some(refresh_on_start.to_string()),
        );
    }
    if let Some(sort) = settings.default_sort {
        map.insert(DEFAULT_SORT.to_string(), Some(sort.to_string()));
    }
    if let Some(force_tv_mode) = settings.force_tv_mode {
        map.insert(FORCE_TV_MODE.to_string(), Some(force_tv_mode.to_string()));
    }
    if let Some(show_livestreams) = settings.show_livestreams {
        map.insert(
            SHOW_LIVESTREAMS.to_string(),
            Some(show_livestreams.to_string()),
        );
    }
    if let Some(show_movies) = settings.show_movies {
        map.insert(SHOW_MOVIES.to_string(), Some(show_movies.to_string()));
    }
    if let Some(show_series) = settings.show_series {
        map.insert(SHOW_SERIES.to_string(), Some(show_series.to_string()));
    }
    insert_opt(&mut map, VOLUME_BRIGHTNESS_GESTURES, settings.volume_brightness_gestures);
    insert_opt(&mut map, SWIPE_TO_CHANGE_CHANNEL, settings.swipe_to_change_channel);
    insert_opt(&mut map, DOUBLE_TAP_SEEK, settings.double_tap_seek);
    insert_opt(&mut map, SEEK_SECONDS, settings.seek_seconds);
    insert_opt(&mut map, PICTURE_IN_PICTURE, settings.picture_in_picture);
    insert_opt(&mut map, KEEP_AUDIO_AFTER_PIP, settings.keep_audio_after_pip);
    insert_opt(&mut map, SHOW_CONTINUE_WATCHING, settings.show_continue_watching);
    insert_opt(&mut map, AUTOPLAY_NEXT_EPISODE, settings.autoplay_next_episode);
    insert_opt(
        &mut map,
        AUTOPLAY_COUNTDOWN_SECONDS,
        settings.autoplay_countdown_seconds,
    );
    insert_opt(&mut map, SHOW_EPG, settings.show_epg);
    // An empty PIN removes it.
    insert_opt(&mut map, PARENTAL_PIN, settings.parental_pin);
    sql::update_settings(map)?;
    Ok(())
}

fn insert_opt<T: ToString>(map: &mut HashMap<String, Option<String>>, key: &str, value: Option<T>) {
    if let Some(value) = value {
        map.insert(key.to_string(), Some(value.to_string()));
    }
}
