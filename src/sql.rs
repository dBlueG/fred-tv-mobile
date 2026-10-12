use std::path::PathBuf;
use std::str::FromStr;
use std::sync::OnceLock;
use std::vec;
use std::{collections::HashMap, sync::LazyLock};

use crate::sort_type;
use crate::types::{
    BackupChannel, BackupPosition, ChannelPreserve, ContinueWatching, FavoriteList, Season,
};
use crate::{
    media_type,
    types::{Channel, ChannelHttpHeaders, Filters, Source},
    view_type,
};
use anyhow::{Context, Result, anyhow};
use r2d2::{Pool, PooledConnection};
use r2d2_sqlite::SqliteConnectionManager;
use rusqlite::{OptionalExtension, Row, Transaction, params, params_from_iter};
use rusqlite_migration::{M, Migrations};

const PAGE_SIZE: u8 = 36;
pub const DB_NAME: &str = "db_rust.sqlite";
pub const DB_SETTINGS_NAME: &str = "db_rust_settings.sqlite";
pub const LAST_SEEN_VERSION_KEY: &str = "last_seen_version";
pub static DB_PATH_OVERRIDE: OnceLock<String> = OnceLock::new();
static CONN: LazyLock<Pool<SqliteConnectionManager>> =
    LazyLock::new(|| create_connection_pool(DB_NAME));
static SETTINGS_CONN: LazyLock<Pool<SqliteConnectionManager>> =
    LazyLock::new(|| create_connection_pool(DB_SETTINGS_NAME));

pub fn get_conn() -> Result<PooledConnection<SqliteConnectionManager>> {
    CONN.try_get().context("No sqlite conns available")
}

pub fn get_settings_conn() -> Result<PooledConnection<SqliteConnectionManager>> {
    SETTINGS_CONN.try_get().context("No sqlite conns available")
}

fn create_connection_pool(db_name: &str) -> Pool<SqliteConnectionManager> {
    let manager = SqliteConnectionManager::file(get_and_create_db_path(db_name))
        .with_init(|c| {
            c.pragma_update_and_check(None, "journal_mode", "WAL", |_| Ok(()))?;
            // Safe with WAL: a crash can lose the last commit but never corrupts the db.
            c.pragma_update(None, "synchronous", "NORMAL")
        });
    r2d2::Pool::builder().max_size(20).build(manager).unwrap()
}

fn get_and_create_db_path(db_name: &str) -> String {
    let mut path = PathBuf::from_str(DB_PATH_OVERRIDE.get().unwrap()).unwrap();
    if !path.exists() {
        std::fs::create_dir_all(&path).unwrap();
    }
    path.push(db_name);
    return path.to_string_lossy().to_string();
}

pub fn apply_migrations() -> Result<()> {
    apply_main_migrations()?;
    migrate_settings_database()?;
    Ok(())
}

fn apply_main_migrations() -> Result<()> {
    let mut sql = get_conn()?;
    let migrations = Migrations::new(vec![M::up(
        r#"
CREATE TABLE "sources" (
  "id"                INTEGER PRIMARY KEY,
  "name"              varchar(100),
  "source_type"       integer,
  "url"               varchar(500),
  "username"          varchar(100),
  "password"          varchar(100),
  "enabled"           integer DEFAULT 1,
  "user_agent"        varchar(500),
  "stream_user_agent" varchar(500),
  "last_updated"      integer
);

CREATE TABLE "groups" (
  "id"          INTEGER PRIMARY KEY,
  "name"        varchar(100),
  "image"       varchar(500),
  "source_id"   integer,
  "media_type"  integer,
  FOREIGN KEY (source_id) REFERENCES sources(id)
);

CREATE TABLE "channels" (
  "id"           INTEGER PRIMARY KEY,
  "name"         varchar(100),
  "image"        varchar(500),
  "url"          varchar(500),
  "media_type"   integer,
  "source_id"    integer,
  "favorite"     integer,
  "series_id"    integer,
  "group_id"     integer,
  "stream_id"    integer,
  "last_watched" integer,
  "tv_archive"   integer,
  "season_id"    integer,
  "episode_num"  integer,
  FOREIGN KEY (source_id) REFERENCES sources(id),
  FOREIGN KEY (group_id) REFERENCES groups(id)
);

CREATE TABLE "channel_http_headers" (
  "id"           INTEGER PRIMARY KEY,
  "channel_id"   integer,
  "referrer"     varchar(500),
  "user_agent"   varchar(500),
  "http_origin"  varchar(500),
  "ignore_ssl"   integer DEFAULT 0,
  FOREIGN KEY (channel_id) REFERENCES channels(id) ON DELETE CASCADE
);

CREATE TABLE "movie_positions" (
  "id"         INTEGER PRIMARY KEY,
  "channel_id" integer,
  "position"   integer,
  FOREIGN KEY (channel_id) REFERENCES channels(id) ON DELETE CASCADE
);

CREATE TABLE "seasons" (
  "id"            INTEGER PRIMARY KEY,
  "name"          VARCHAR(50),
  "season_number" integer,
  "series_id"     integer,
  "source_id"     integer,
  "image"         varchar(200),
  FOREIGN KEY (source_id) REFERENCES sources(id) ON DELETE CASCADE
);

CREATE TABLE "settings" (
  "key"   VARCHAR(50) PRIMARY KEY,
  "value" VARCHAR(100)
);

CREATE INDEX index_channel_name ON channels(name);
CREATE UNIQUE INDEX channels_unique ON channels(name, source_id, url, series_id, season_id);

CREATE UNIQUE INDEX index_source_name ON sources(name);
CREATE INDEX index_source_enabled ON sources(enabled);

CREATE UNIQUE INDEX index_group_unique ON groups(name, source_id);
CREATE INDEX index_group_name ON groups(name);

CREATE INDEX index_channel_source_id ON channels(source_id);
CREATE INDEX index_channel_favorite ON channels(favorite);
CREATE INDEX index_channel_series_id ON channels(series_id);
CREATE INDEX index_channel_group_id ON channels(group_id);
CREATE INDEX index_channel_media_type ON channels(media_type);
CREATE INDEX index_channels_stream_id ON channels(stream_id);
CREATE INDEX index_channels_last_watched ON channels(last_watched);
CREATE INDEX index_channels_tv_archive ON channels(tv_archive);
CREATE INDEX index_channels_season_id ON channels(season_id);
CREATE INDEX index_channels_episode_num ON channels(episode_num);

CREATE INDEX index_group_source_id ON groups(source_id);
CREATE INDEX index_groups_media_type ON groups(media_type);

CREATE UNIQUE INDEX index_channel_http_headers_channel_id ON channel_http_headers(channel_id);
CREATE UNIQUE INDEX index_movie_positions_channel_id ON movie_positions(channel_id);
CREATE UNIQUE INDEX unique_seasons ON seasons(season_number, series_id, source_id);

ANALYZE;
"#,
    ),
    M::up(
        r#"
DROP TABLE IF EXISTS settings;

ANALYZE;
"#,
    ),
    M::up(
        r#"
CREATE TABLE "favorite_lists" (
  "id"   INTEGER PRIMARY KEY,
  "name" varchar(100) NOT NULL COLLATE NOCASE
);

CREATE TABLE "favorite_list_channels" (
  "list_id"    integer NOT NULL,
  "channel_id" integer NOT NULL,
  PRIMARY KEY (list_id, channel_id)
);

CREATE UNIQUE INDEX index_favorite_lists_name ON favorite_lists(name);
CREATE INDEX index_favorite_list_channels_channel_id ON favorite_list_channels(channel_id);

ANALYZE;
"#,
    ),
    // No query filters on these; they only slowed down imports.
    M::up(
        r#"
DROP INDEX IF EXISTS index_channels_stream_id;
DROP INDEX IF EXISTS index_channels_tv_archive;
DROP INDEX IF EXISTS index_channels_episode_num;
"#,
    ),
    // Positions are matched by source, name and URL instead of channel id,
    // because a source refresh re-creates its channels with new ids. The old
    // table's ON DELETE CASCADE (the bundled SQLite enforces foreign keys)
    // erased every position on refresh, so the table is rebuilt without it.
    M::up(
        r#"
CREATE TABLE "movie_positions_new" (
  "id"         INTEGER PRIMARY KEY,
  "channel_id" integer,
  "position"   integer,
  "duration"   integer,
  "updated_at" integer,
  "source_id"  integer,
  "name"       varchar(100),
  "url"        varchar(500)
);

INSERT INTO movie_positions_new (id, channel_id, position, updated_at, source_id, name, url)
SELECT mp.id, mp.channel_id, mp.position, strftime('%s', 'now'), c.source_id, c.name, c.url
FROM movie_positions mp
JOIN channels c ON c.id = mp.channel_id;

DROP TABLE movie_positions;
ALTER TABLE movie_positions_new RENAME TO movie_positions;

CREATE INDEX index_movie_positions_identity ON movie_positions(source_id, name);
CREATE INDEX index_movie_positions_updated_at ON movie_positions(updated_at);
"#,
    )]);
    migrations.to_latest(&mut sql)?;
    Ok(())
}

fn migrate_settings_database() -> Result<()> {
    let mut conn = get_settings_conn()?;
    let migrations = Migrations::new(vec![M::up(
        r#"
CREATE TABLE "settings" (
  "key"   VARCHAR(50) PRIMARY KEY,
  "value" VARCHAR(100)
);

ANALYZE;
"#,
    )]);
    migrations.to_latest(&mut conn)?;
    Ok(())
}

pub fn create_or_find_source_by_name(tx: &Transaction, source: &Source) -> Result<i64> {
    let id: Option<i64> = tx
        .query_row(
            "SELECT id FROM sources WHERE name = ?1",
            params![source.name],
            |r| r.get(0),
        )
        .optional()?;
    if let Some(id) = id {
        return Ok(id);
    }
    tx.execute(
    "INSERT INTO sources (name, source_type, url, username, password, user_agent, last_updated) VALUES (?, ?, ?, ?, ?, ?, ?)",
    params![source.name, source.source_type.clone() as u8, source.url, source.username, source.password, source.user_agent, chrono::Utc::now().timestamp()],
    )?;
    Ok(tx.last_insert_rowid())
}

pub fn insert_season(tx: &Transaction, season: Season) -> Result<i64> {
    tx.prepare_cached(
        r#"
        INSERT INTO seasons (name, image, series_id, season_number, source_id)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT (series_id, season_number, source_id)
        DO UPDATE SET
          image = excluded.image,
          name = excluded.name
        "#,
    )?
    .execute(params![
            season.name,
            season.image,
            season.series_id,
            season.season_number,
            season.source_id,
        ])?;
    Ok(tx
        .prepare_cached(
            r#"
        SELECT id
        FROM seasons
        WHERE series_id = ?
        AND season_number = ?
        AND source_id = ?
      "#,
        )?
        .query_row(
            params![season.series_id, season.season_number, season.source_id],
            |r| r.get(0),
        )?)
}

// Called once per channel during imports, so statements are cached rather than re-parsed.
pub fn insert_channel(tx: &Transaction, channel: Channel) -> Result<()> {
    tx.prepare_cached(
        r#"
INSERT INTO channels (name, group_id, image, url, source_id, media_type, series_id, favorite, stream_id, tv_archive, season_id, episode_num)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT (name, source_id, url, series_id, season_id)
DO UPDATE SET
    url = excluded.url,
    media_type = excluded.media_type,
    stream_id = excluded.stream_id,
    image = excluded.image,
    series_id = excluded.series_id,
    tv_archive = excluded.tv_archive,
    season_id = excluded.season_id;
"#,
    )?
    .execute(params![
            channel.name,
            channel.group_id,
            channel.image,
            channel.url,
            channel.source_id,
            channel.media_type as u8,
            channel.series_id,
            channel.favorite,
            channel.stream_id,
            channel.tv_archive,
            channel.season_id,
            channel.episode_num
        ])?;
    Ok(())
}

pub fn insert_channel_headers(tx: &Transaction, headers: ChannelHttpHeaders) -> Result<()> {
    tx.prepare_cached(
        r#"
INSERT OR IGNORE INTO channel_http_headers (channel_id, referrer, user_agent, http_origin, ignore_ssl)
VALUES (?, ?, ?, ?, ?);
"#,
    )?
    .execute(params![
            headers.channel_id,
            headers.referrer,
            headers.user_agent,
            headers.http_origin,
            headers.ignore_ssl
        ])?;
    Ok(())
}

fn get_or_insert_group(
    tx: &Transaction,
    group: &str,
    image: &Option<String>,
    source_id: &i64,
    media_type: u8,
) -> Result<i64> {
    let rows_changed = tx
        .prepare_cached(
            r#"
        INSERT OR IGNORE INTO groups (name, image, source_id, media_type)
        VALUES (?, ?, ?, ?);
        "#,
        )?
        .execute(params![group, &image, source_id, media_type])?;
    if rows_changed == 0 {
        return Ok(tx
            .prepare_cached("SELECT id FROM groups WHERE name = ? and source_id = ?")?
            .query_row(params![group, source_id], |row| row.get::<_, i64>("id"))?);
    }
    Ok(tx.last_insert_rowid())
}

pub fn set_channel_group_id(
    groups: &mut HashMap<String, i64>,
    channel: &mut Channel,
    tx: &Transaction,
    source_id: &i64,
) -> Result<()> {
    if channel.group.is_none() {
        return Ok(());
    }
    if !groups.contains_key(channel.group.as_ref().unwrap()) {
        let id = get_or_insert_group(
            tx,
            channel.group.as_ref().unwrap(),
            &channel.image,
            source_id,
            channel.media_type,
        )?;
        groups.insert(channel.group.clone().unwrap(), id);
        channel.group_id = Some(id);
    } else {
        channel.group_id = groups
            .get(channel.group.as_ref().unwrap())
            .map(|x| x.to_owned());
    }
    Ok(())
}

pub fn get_channel_headers_by_id(id: i64) -> Result<Option<ChannelHttpHeaders>> {
    let sql = get_conn()?;
    let headers = sql
        .query_row(
            "SELECT * FROM channel_http_headers WHERE channel_id = ?",
            params![id],
            row_to_channel_headers,
        )
        .optional()?;
    Ok(headers)
}

fn row_to_channel_headers(row: &Row) -> Result<ChannelHttpHeaders, rusqlite::Error> {
    Ok(ChannelHttpHeaders {
        id: row.get("id")?,
        channel_id: row.get("channel_id")?,
        http_origin: row.get("http_origin")?,
        referrer: row.get("referrer")?,
        user_agent: row.get("user_agent")?,
        ignore_ssl: row.get("ignore_ssl")?,
    })
}

pub fn get_settings() -> Result<HashMap<String, String>> {
    let sql = get_settings_conn()?;
    let map = sql
        .prepare("SELECT key, value FROM Settings")?
        .query_map([], |row| {
            let key: String = row.get(0)?;
            let value: String = row.get(1)?;
            Ok((key, value))
        })?
        .filter_map(Result::ok)
        .collect();
    Ok(map)
}

pub fn update_settings(map: HashMap<String, Option<String>>) -> Result<()> {
    let mut sql: PooledConnection<SqliteConnectionManager> = get_settings_conn()?;
    let tx = sql.transaction()?;
    for (key, value) in map {
        tx.execute(
            r#"
            INSERT INTO Settings (key, value)
            VALUES (?1, ?2)
            ON CONFLICT(key) DO UPDATE SET value = ?2
            "#,
            params![key, value],
        )?;
    }
    tx.commit()?;
    Ok(())
}

pub fn search(filters: Filters) -> Result<Vec<Channel>> {
    if filters.view_type == view_type::CATEGORIES
        && filters.group_id.is_none()
        && filters.series_id.is_none()
    {
        return search_group(filters);
    }
    if filters.series_id.is_some() && filters.season.is_none() {
        return search_series(filters);
    }
    let sql = get_conn()?;
    let offset: u16 = filters.page as u16 * PAGE_SIZE as u16 - PAGE_SIZE as u16;
    let media_types = match filters.series_id.is_some() {
        true => vec![1],
        false => filters.media_types.clone().unwrap_or(vec![]),
    };
    let query = filters.query.unwrap_or("".to_string());
    let keywords: Vec<String> = match filters.use_keywords {
        true => query
            .split(" ")
            .map(|f| format!("%{f}%").to_string())
            .collect(),
        false => vec![format!("%{query}%")],
    };
    let mut sql_query = format!(
        r#"
        SELECT * FROM CHANNELS
        WHERE ({})
        AND media_type IN ({})
        AND source_id IN ({})
        AND url IS NOT NULL"#,
        get_keywords_sql(keywords.len()),
        generate_placeholders(media_types.len()),
        generate_placeholders(filters.source_ids.len()),
    );
    let mut baked_params = 2;
    let favorite_list_id = match filters.view_type == view_type::FAVORITES
        && filters.series_id.is_none()
    {
        true => {
            sql_query += "\nAND favorite = 1";
            filters.favorite_list_id
        }
        false => None,
    };
    if favorite_list_id.is_some() {
        sql_query +=
            "\nAND id IN (SELECT channel_id FROM favorite_list_channels WHERE list_id = ?)";
        baked_params += 1;
    }

    if filters.series_id.is_some() {
        sql_query += &format!("\nAND series_id = ?");
        baked_params += 1;
    } else if filters.group_id.is_some() {
        sql_query += &format!("\nAND group_id = ?");
        baked_params += 1;
    }
    if filters.season.is_some() {
        sql_query += &format!("\nAND season_id = ?");
        baked_params += 1;
    }
    let order = match filters.sort {
        sort_type::ALPHABETICAL_DESC => "DESC",
        _ => "ASC",
    };
    if filters.view_type == view_type::HISTORY {
        sql_query += "\nAND last_watched IS NOT NULL";
        sql_query += "\nORDER BY last_watched DESC";
    } else if filters.season.is_some() {
        sql_query += &format!("\nORDER BY episode_num {0}, name {0}", order)
    } else if filters.sort != sort_type::PROVIDER {
        sql_query += &format!("\nORDER BY name {}", order);
    }
    sql_query += "\nLIMIT ?, ?";
    let mut params: Vec<&dyn rusqlite::ToSql> = Vec::with_capacity(
        baked_params + media_types.len() + filters.source_ids.len() + keywords.len(),
    );
    params.extend(to_to_sql(&keywords));
    params.extend(to_to_sql(&media_types));
    params.extend(to_to_sql(&filters.source_ids));
    if let Some(ref list_id) = favorite_list_id {
        params.push(list_id);
    }
    if let Some(ref series_id) = filters.series_id {
        params.push(series_id);
    } else if let Some(ref group) = filters.group_id {
        params.push(group);
    }
    if let Some(ref season) = filters.season {
        params.push(season);
    }
    params.push(&offset);
    params.push(&PAGE_SIZE);
    let channels: Vec<Channel> = sql
        .prepare(&sql_query)?
        .query_map(params_from_iter(params), row_to_channel)?
        .filter_map(Result::ok)
        .collect();
    Ok(channels)
}

fn search_series(filters: Filters) -> Result<Vec<Channel>> {
    let sql = get_conn()?;
    let offset: u16 = filters.page as u16 * PAGE_SIZE as u16 - PAGE_SIZE as u16;
    let query = filters.query.unwrap_or("".to_string());
    let keywords: Vec<String> = match filters.use_keywords {
        true => query
            .split(" ")
            .map(|f| format!("%{f}%").to_string())
            .collect(),
        false => vec![format!("%{query}%")],
    };
    let mut sql_query = format!(
        r#"
      SELECT *
      FROM seasons
      WHERE ({})
      AND source_id = ?
      AND series_id = ?
      "#,
        get_keywords_sql(keywords.len()),
    );
    let order = match filters.sort {
        sort_type::ALPHABETICAL_DESC => "DESC",
        _ => "ASC",
    };
    sql_query += &format!("\nORDER BY season_number {}", order);
    sql_query += "\nLIMIT ?, ?";
    let mut params: Vec<&dyn rusqlite::ToSql> =
        Vec::with_capacity(2 + filters.source_ids.len() + keywords.len());
    params.extend(to_to_sql(&keywords));
    params.push(filters.source_ids.first().context("no source ids")?);
    params.push(filters.series_id.as_ref().context("no series id")?);
    params.push(&offset);
    params.push(&PAGE_SIZE);
    let channels: Vec<Channel> = sql
        .prepare(&sql_query)?
        .query_map(params_from_iter(params), season_row_to_channel)?
        .filter_map(Result::ok)
        .collect();
    Ok(channels)
}

fn season_row_to_channel(row: &Row) -> std::result::Result<Channel, rusqlite::Error> {
    Ok(Channel {
        id: row.get("id")?,
        image: row.get("image")?,
        favorite: false,
        group: None,
        group_id: None,
        media_type: media_type::SEASON,
        name: row.get("name")?,
        series_id: row.get("series_id")?,
        season_id: None,
        source_id: None,
        stream_id: None,
        tv_archive: None,
        url: None,
        episode_num: None,
    })
}

fn to_to_sql<T: rusqlite::ToSql>(values: &[T]) -> Vec<&dyn rusqlite::ToSql> {
    values.iter().map(|x| x as &dyn rusqlite::ToSql).collect()
}

fn get_keywords_sql(size: usize) -> String {
    std::iter::repeat("name LIKE ?")
        .take(size)
        .collect::<Vec<_>>()
        .join(" AND ")
}

fn generate_placeholders(size: usize) -> String {
    std::iter::repeat("?")
        .take(size)
        .collect::<Vec<_>>()
        .join(",")
}

pub fn series_has_episodes(series_id: i64, source_id: i64) -> Result<bool> {
    let sql = get_conn()?;
    let series_exists = sql
        .query_row(
            r#"
      SELECT 1
      FROM channels
      WHERE series_id = ? AND source_id = ?
      LIMIT 1
    "#,
            params![series_id, source_id],
            |row| row.get::<_, u8>(0),
        )
        .optional()?
        .is_some();
    Ok(series_exists)
}

pub fn search_group(filters: Filters) -> Result<Vec<Channel>> {
    let sql = get_conn()?;
    let offset: u16 = filters.page as u16 * PAGE_SIZE as u16 - PAGE_SIZE as u16;
    let query = filters.query.unwrap_or("".to_string());
    let media_types = filters.media_types.unwrap_or_else(|| vec![]);
    let keywords: Vec<String> = match filters.use_keywords {
        true => query
            .split(" ")
            .map(|f| format!("%{f}%").to_string())
            .collect(),
        false => vec![format!("%{query}%")],
    };
    let mut params: Vec<&dyn rusqlite::ToSql> = Vec::with_capacity(2 + filters.source_ids.len());
    let mut sql_query = format!(
        r#"
        SELECT *
        FROM groups
        WHERE ({})
        AND source_id in ({})
        AND (media_type IS NULL OR media_type in ({}))
    "#,
        get_keywords_sql(keywords.len()),
        generate_placeholders(filters.source_ids.len()),
        generate_placeholders(media_types.len())
    );
    if filters.sort != sort_type::PROVIDER {
        let order = match filters.sort {
            sort_type::ALPHABETICAL_ASC => "ASC",
            sort_type::ALPHABETICAL_DESC => "DESC",
            _ => "ASC",
        };
        sql_query += &format!("\nORDER BY name {}", order);
    }
    sql_query += "\nLIMIT ?, ?";
    params.extend(to_to_sql(&keywords));
    params.extend(to_to_sql(&filters.source_ids));
    params.extend(to_to_sql(&media_types));
    params.push(&offset);
    params.push(&PAGE_SIZE);
    let channels: Vec<Channel> = sql
        .prepare(&sql_query)?
        .query_map(params_from_iter(params), row_to_group)?
        .filter_map(Result::ok)
        .collect();
    Ok(channels)
}

fn row_to_group(row: &Row) -> std::result::Result<Channel, rusqlite::Error> {
    let channel = Channel {
        id: row.get("id")?,
        name: row.get("name")?,
        group: None,
        image: row.get("image")?,
        media_type: media_type::GROUP,
        url: None,
        series_id: None,
        group_id: None,
        favorite: false,
        source_id: row.get("source_id")?,
        stream_id: None,
        tv_archive: None,
        season_id: None,
        episode_num: None,
    };
    Ok(channel)
}

fn row_to_channel(row: &Row) -> std::result::Result<Channel, rusqlite::Error> {
    let channel = Channel {
        id: row.get("id")?,
        name: row.get("name")?,
        group_id: row.get("group_id")?,
        image: row.get("image")?,
        media_type: row.get("media_type")?,
        source_id: row.get("source_id")?,
        url: row.get("url")?,
        favorite: row.get("favorite")?,
        episode_num: row.get("episode_num")?,
        series_id: None,
        group: None,
        stream_id: row.get("stream_id")?,
        tv_archive: row.get("tv_archive")?,
        season_id: row.get("season_id")?,
    };
    Ok(channel)
}

pub fn delete_channels_by_source(tx: &Transaction, source_id: i64) -> Result<()> {
    delete_favorite_list_entries_by_source(tx, source_id)?;
    tx.execute(
        r#"
        DELETE FROM channels
        WHERE source_id = ?
    "#,
        params![source_id],
    )?;
    Ok(())
}

pub fn delete_seasons_by_source(tx: &Transaction, source_id: i64) -> Result<()> {
    tx.execute(
        r#"
        DELETE FROM seasons
        WHERE source_id = ?
    "#,
        params![source_id],
    )?;
    Ok(())
}

pub fn delete_groups_by_source(tx: &Transaction, source_id: i64) -> Result<()> {
    tx.execute(
        r#"
        DELETE FROM groups
        WHERE source_id = ?
    "#,
        params!(source_id),
    )?;
    Ok(())
}

// Foreign keys aren't enforced, so list entries must be removed by hand
// before a source's channels are deleted.
fn delete_favorite_list_entries_by_source(
    conn: &rusqlite::Connection,
    source_id: i64,
) -> Result<()> {
    conn.execute(
        r#"
        DELETE FROM favorite_list_channels
        WHERE channel_id IN (SELECT id FROM channels WHERE source_id = ?)
    "#,
        params![source_id],
    )?;
    Ok(())
}

pub fn delete_source(id: i64) -> Result<()> {
    let sql = get_conn()?;
    delete_favorite_list_entries_by_source(&sql, id)?;
    sql.execute("DELETE FROM movie_positions WHERE source_id = ?", params![id])?;
    sql.execute(
        r#"
        DELETE FROM channels
        WHERE source_id = ?;
    "#,
        params![id],
    )?;
    sql.execute(
        r#"
        DELETE FROM groups
        WHERE source_id = ?;
    "#,
        params![id],
    )?;
    sql.execute(
        r#"
        DELETE FROM seasons
        WHERE source_id = ?;
    "#,
        params![id],
    )?;
    let count = sql.execute(
        r#"
        DELETE FROM sources
        WHERE id = ?;
    "#,
        params![id],
    )?;
    if count != 1 {
        return Err(anyhow!("No sources were deleted"));
    }
    sql.execute("ANALYZE;", params![])?;
    Ok(())
}

pub fn source_name_exists(name: &str) -> Result<bool> {
    let sql = get_conn()?;
    Ok(sql
        .query_row(
            r#"
    SELECT 1
    FROM sources
    WHERE name = ?1
    "#,
            [name],
            |row| row.get::<_, u8>(0),
        )
        .optional()?
        .is_some())
}

pub fn favorite_channel(channel_id: i64, favorite: bool) -> Result<()> {
    let mut sql = get_conn()?;
    let tx = sql.transaction()?;
    tx.execute(
        r#"
        UPDATE channels
        SET favorite = ?1
        WHERE id = ?2
    "#,
        params![favorite, channel_id],
    )?;
    if !favorite {
        tx.execute(
            "DELETE FROM favorite_list_channels WHERE channel_id = ?",
            params![channel_id],
        )?;
    }
    tx.commit()?;
    Ok(())
}

// Sets whether a channel is a favorite and replaces the lists it belongs to.
// A channel that isn't a favorite can't be in any list.
pub fn set_channel_favorite_lists(
    channel_id: i64,
    favorite: bool,
    list_ids: &[i64],
) -> Result<()> {
    let mut sql = get_conn()?;
    let tx = sql.transaction()?;
    tx.execute(
        r#"
        UPDATE channels
        SET favorite = ?1
        WHERE id = ?2
    "#,
        params![favorite, channel_id],
    )?;
    tx.execute(
        "DELETE FROM favorite_list_channels WHERE channel_id = ?",
        params![channel_id],
    )?;
    if favorite {
        for list_id in list_ids {
            tx.execute(
                r#"
                INSERT OR IGNORE INTO favorite_list_channels (list_id, channel_id)
                SELECT id, ?2 FROM favorite_lists WHERE id = ?1
            "#,
                params![list_id, channel_id],
            )?;
        }
    }
    tx.commit()?;
    Ok(())
}

pub fn get_channel_favorite_lists(channel_id: i64) -> Result<Vec<i64>> {
    let sql = get_conn()?;
    let ids = sql
        .prepare(
            "SELECT list_id FROM favorite_list_channels WHERE channel_id = ? ORDER BY list_id",
        )?
        .query_map(params![channel_id], |row| row.get(0))?
        .collect::<Result<Vec<i64>, _>>()?;
    Ok(ids)
}

pub fn get_favorite_lists() -> Result<Vec<FavoriteList>> {
    let sql = get_conn()?;
    let lists = sql
        .prepare("SELECT id, name FROM favorite_lists ORDER BY id")?
        .query_map([], |row| {
            Ok(FavoriteList {
                id: row.get("id")?,
                name: row.get("name")?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(lists)
}

fn validate_favorite_list_name(
    sql: &rusqlite::Connection,
    name: &str,
    id: Option<i64>,
) -> Result<String> {
    let name = name.trim();
    if name.is_empty() {
        return Err(anyhow!("List name can't be empty"));
    }
    let taken = sql
        .query_row(
            "SELECT 1 FROM favorite_lists WHERE name = ?1 AND id IS NOT ?2",
            params![name, id],
            |row| row.get::<_, u8>(0),
        )
        .optional()?
        .is_some();
    if taken {
        return Err(anyhow!("A list named \"{name}\" already exists"));
    }
    Ok(name.to_string())
}

pub fn create_favorite_list(name: &str) -> Result<FavoriteList> {
    let sql = get_conn()?;
    let name = validate_favorite_list_name(&sql, name, None)?;
    sql.execute("INSERT INTO favorite_lists (name) VALUES (?)", params![name])?;
    Ok(FavoriteList {
        id: sql.last_insert_rowid(),
        name,
    })
}

pub fn rename_favorite_list(id: i64, name: &str) -> Result<()> {
    let sql = get_conn()?;
    let name = validate_favorite_list_name(&sql, name, Some(id))?;
    let count = sql.execute(
        "UPDATE favorite_lists SET name = ?1 WHERE id = ?2",
        params![name, id],
    )?;
    if count != 1 {
        return Err(anyhow!("List not found"));
    }
    Ok(())
}

// Channels in the list stay in the main favorites.
pub fn delete_favorite_list(id: i64) -> Result<()> {
    let mut sql = get_conn()?;
    let tx = sql.transaction()?;
    tx.execute(
        "DELETE FROM favorite_list_channels WHERE list_id = ?",
        params![id],
    )?;
    tx.execute("DELETE FROM favorite_lists WHERE id = ?", params![id])?;
    tx.commit()?;
    Ok(())
}

pub fn get_sources() -> Result<Vec<Source>> {
    let sql = get_conn()?;
    let sources: Vec<Source> = sql
        .prepare("SELECT * FROM sources")?
        .query_map([], row_to_source)?
        .filter_map(Result::ok)
        .collect();
    Ok(sources)
}

pub fn get_enabled_sources_minimal() -> Result<Vec<i64>> {
    let sql = get_conn()?;
    Ok(sql
        .prepare("SELECT id FROM sources where enabled = 1")?
        .query_map([], |row| row.get(0))?
        .filter_map(Result::ok)
        .collect())
}

fn row_to_source(row: &Row) -> std::result::Result<Source, rusqlite::Error> {
    Ok(Source {
        id: row.get("id")?,
        name: row.get("name")?,
        username: row.get("username")?,
        password: row.get("password")?,
        url: row.get("url")?,
        source_type: row.get("source_type")?,
        url_origin: None,
        enabled: row.get("enabled")?,
        user_agent: row.get("user_agent")?,
        stream_user_agent: row.get("stream_user_agent")?,
        last_updated: row.get("last_updated")?,
    })
}

pub fn get_source_from_id(source_id: i64) -> Result<Source> {
    let sql = get_conn()?;
    Ok(sql.query_row(
        r#"
    SELECT * FROM sources where id = ?"#,
        [source_id],
        row_to_source,
    )?)
}

pub fn set_source_enabled(value: bool, source_id: i64) -> Result<()> {
    let sql = get_conn()?;
    sql.execute(
        r#"
        UPDATE sources
        SET enabled = ?
        WHERE id = ?
    "#,
        params![value, source_id],
    )?;
    Ok(())
}

pub fn do_tx<F, T>(f: F) -> Result<T>
where
    F: FnOnce(&Transaction) -> Result<T>,
{
    let mut sql = get_conn()?;
    let tx = sql.transaction()?;
    let result = f(&tx)?;
    tx.commit()?;
    Ok(result)
}

pub fn update_source(source: Source) -> Result<()> {
    let sql = get_conn()?;
    sql.execute(
        r#"
        UPDATE sources
        SET username = ?, password = ?, url = ?, user_agent = ?, stream_user_agent = ?
        WHERE id = ?"#,
        params![
            source.username,
            source.password,
            source.url,
            source.user_agent,
            source.stream_user_agent,
            source.id
        ],
    )?;
    Ok(())
}

pub fn wipe(tx: &Transaction, id: i64) -> Result<()> {
    delete_seasons_by_source(tx, id)?;
    delete_channels_by_source(tx, id)?;
    delete_groups_by_source(tx, id)?;
    Ok(())
}

pub fn get_preserve(tx: &Transaction, source_id: i64) -> Result<Vec<ChannelPreserve>> {
    let channels: Vec<ChannelPreserve> = tx
        .prepare(
            r#"
              SELECT name, favorite, last_watched,
                (SELECT group_concat(list_id) FROM favorite_list_channels
                 WHERE channel_id = channels.id) AS list_ids
              FROM channels
              WHERE (favorite = 1 OR last_watched IS NOT NULL)
              AND series_id IS NULL
              AND source_id = ?
            "#,
        )?
        .query_map(params![source_id], row_to_channel_preserve)?
        .filter_map(Result::ok)
        .collect();

    Ok(channels)
}

fn row_to_channel_preserve(row: &Row) -> Result<ChannelPreserve, rusqlite::Error> {
    Ok(ChannelPreserve {
        name: row.get("name")?,
        favorite: row.get("favorite")?,
        last_watched: row.get("last_watched")?,
        is_group: false,
        list_ids: row
            .get::<_, Option<String>>("list_ids")?
            .map(|ids| ids.split(',').filter_map(|id| id.parse().ok()).collect())
            .unwrap_or_default(),
    })
}

pub fn restore_preserve(
    tx: &Transaction,
    source_id: i64,
    preserve: Vec<ChannelPreserve>,
) -> Result<()> {
    for item in preserve {
        if item.is_group {
            tx.execute(
                r#"
                  UPDATE groups
                  WHERE name = ?
                  AND source_id = ?
                "#,
                params![item.name, source_id],
            )?;
        } else {
            tx.prepare_cached(
                r#"
                  UPDATE channels
                  SET favorite = ?, last_watched = ?
                  WHERE name = ?
                  AND source_id = ?
                "#,
            )?
            .execute(params![item.favorite, item.last_watched, item.name, source_id])?;
            for list_id in &item.list_ids {
                tx.prepare_cached(
                    r#"
                      INSERT OR IGNORE INTO favorite_list_channels (list_id, channel_id)
                      SELECT ?, id
                      FROM channels
                      WHERE name = ?
                      AND source_id = ?
                      AND series_id IS NULL
                    "#,
                )?
                .execute(params![list_id, item.name, source_id])?;
            }
        }
    }
    Ok(())
}

pub fn analyze(tx: &Transaction) -> Result<()> {
    // Approximate stats are enough for the planner and avoid scanning every index.
    tx.execute_batch("PRAGMA analysis_limit = 1000; ANALYZE;")?;
    Ok(())
}

pub fn add_last_watched(id: i64) -> Result<()> {
    let sql = get_conn()?;
    sql.execute(
        r#"
          UPDATE channels
          SET last_watched = strftime('%s', 'now')
          WHERE id = ?
        "#,
        params![id],
    )?;
    sql.execute(
        r#"
		  UPDATE channels
          SET last_watched = NULL
          WHERE last_watched IS NOT NULL
		  AND id NOT IN (
				SELECT id
				FROM channels
				WHERE last_watched IS NOT NULL
				ORDER BY last_watched DESC
				LIMIT 36
		  )
        "#,
        params![],
    )?;
    Ok(())
}

pub fn clear_history() -> Result<()> {
    let sql = get_conn()?;
    sql.execute(
        r#"
          UPDATE channels
          SET last_watched = NULL
          WHERE last_watched IS NOT NULL
        "#,
        params![],
    )?;
    Ok(())
}

pub fn update_source_last_updated(source_id: i64) -> Result<()> {
    let sql = get_conn()?;
    sql.execute(
        "UPDATE sources SET last_updated = ? WHERE id = ?",
        params![chrono::Utc::now().timestamp(), source_id],
    )?;
    Ok(())
}

// Positions within a minute of the end (5% for long videos) count as finished
// and are removed, so the next play starts from the beginning.
const FINISHED_MARGIN_SECONDS: i64 = 60;

fn is_finished(position: i64, duration: Option<i64>) -> bool {
    match duration {
        Some(duration) if duration > 0 => {
            let margin = (duration / 20).max(FINISHED_MARGIN_SECONDS.min(duration / 10));
            position >= duration - margin
        }
        _ => false,
    }
}

// ?2, ?3, ?4: source_id, name, url
const POSITION_IDENTITY: &str = "(source_id = ?2 AND name = ?3 AND url IS ?4)";

fn channel_identity(
    conn: &rusqlite::Connection,
    channel_id: i64,
) -> Result<Option<(Option<i64>, String, Option<String>)>> {
    Ok(conn
        .query_row(
            "SELECT source_id, name, url FROM channels WHERE id = ?",
            params![channel_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .optional()?)
}

pub fn set_movie_position(
    channel_id: i64,
    movie_position: i64,
    duration: Option<i64>,
) -> Result<()> {
    let mut sql = get_conn()?;
    let Some((source_id, name, url)) = channel_identity(&sql, channel_id)? else {
        return Ok(());
    };
    let tx = sql.transaction()?;
    tx.execute(
        &format!("DELETE FROM movie_positions WHERE channel_id = ?1 OR {POSITION_IDENTITY}"),
        params![channel_id, source_id, name, url],
    )?;
    if movie_position > 0 && !is_finished(movie_position, duration) {
        tx.execute(
            r#"
            INSERT INTO movie_positions (channel_id, position, duration, updated_at, source_id, name, url)
            VALUES (?1, ?5, ?6, strftime('%s', 'now'), ?2, ?3, ?4)
            "#,
            params![channel_id, source_id, name, url, movie_position, duration],
        )?;
    }
    tx.commit()?;
    Ok(())
}

pub fn remove_movie_position(channel_id: i64) -> Result<()> {
    let sql = get_conn()?;
    let Some((source_id, name, url)) = channel_identity(&sql, channel_id)? else {
        return Ok(());
    };
    sql.execute(
        &format!("DELETE FROM movie_positions WHERE channel_id = ?1 OR {POSITION_IDENTITY}"),
        params![channel_id, source_id, name, url],
    )?;
    Ok(())
}

pub fn get_movie_position(channel_id: i64) -> Result<Option<i64>> {
    let sql = get_conn()?;
    let position: Option<i64> = sql
        .query_row(
            r#"
        SELECT mp.position
        FROM channels c
        JOIN movie_positions mp
          ON mp.source_id = c.source_id AND mp.name = c.name AND mp.url IS c.url
        WHERE c.id = ?
        ORDER BY mp.updated_at DESC
        LIMIT 1
    "#,
            params!(channel_id),
            |row| row.get(0),
        )
        .optional()?;
    Ok(position)
}

const CONTINUE_WATCHING_LIMIT: u8 = 20;
// Shorter positions are kept for resuming but not listed.
const CONTINUE_WATCHING_MIN_SECONDS: i64 = 30;

// Unfinished movies and episodes of enabled sources, most recent first.
pub fn get_continue_watching() -> Result<Vec<ContinueWatching>> {
    let sql = get_conn()?;
    let items = sql
        .prepare(
            r#"
            SELECT c.*, mp.position AS mp_position, mp.duration AS mp_duration,
              (SELECT s.name FROM channels s
               WHERE c.series_id IS NOT NULL
               AND s.source_id = c.source_id
               AND s.media_type = ?1
               AND s.url = CAST(c.series_id AS TEXT)
               LIMIT 1) AS series_name
            FROM movie_positions mp
            JOIN channels c
              ON c.name = mp.name AND c.source_id = mp.source_id AND c.url = mp.url
            WHERE c.media_type = ?2
            AND c.source_id IN (SELECT id FROM sources WHERE enabled = 1)
            AND mp.position >= ?3
            GROUP BY mp.id
            ORDER BY mp.updated_at DESC
            LIMIT ?4
            "#,
        )?
        .query_map(
            params![
                media_type::SERIE,
                media_type::MOVIE,
                CONTINUE_WATCHING_MIN_SECONDS,
                CONTINUE_WATCHING_LIMIT
            ],
            |row| {
                Ok(ContinueWatching {
                    channel: row_to_channel(row)?,
                    position: row.get("mp_position")?,
                    duration: row.get("mp_duration")?,
                    series_name: row.get("series_name")?,
                })
            },
        )?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(items)
}

// The episode after this one in its series: next by season number, then
// episode number, then name. None for the last episode or a non-episode.
pub fn get_next_episode(channel_id: i64) -> Result<Option<Channel>> {
    let sql = get_conn()?;
    Ok(sql
        .query_row(
            r#"
            WITH cur AS (
              SELECT c.series_id, c.source_id,
                COALESCE(s.season_number, 0) AS sn,
                COALESCE(c.episode_num, 0) AS en,
                c.name AS nm
              FROM channels c
              LEFT JOIN seasons s ON s.id = c.season_id
              WHERE c.id = ?1 AND c.series_id IS NOT NULL
            )
            SELECT c.*
            FROM channels c
            LEFT JOIN seasons s ON s.id = c.season_id
            JOIN cur ON c.series_id = cur.series_id AND c.source_id = cur.source_id
            WHERE c.id != ?1
            AND c.url IS NOT NULL
            AND (COALESCE(s.season_number, 0), COALESCE(c.episode_num, 0), c.name)
                > (cur.sn, cur.en, cur.nm)
            ORDER BY COALESCE(s.season_number, 0), COALESCE(c.episode_num, 0), c.name
            LIMIT 1
            "#,
            params![channel_id],
            row_to_channel,
        )
        .optional()?)
}

// --- Backup ---

const LIST_SEPARATOR: char = '\u{1f}';

pub fn get_backup_channels() -> Result<Vec<BackupChannel>> {
    let sql = get_conn()?;
    let channels = sql
        .prepare(
            r#"
            SELECT s.name AS source, c.name, c.favorite, c.last_watched,
              (SELECT group_concat(fl.name, char(31))
               FROM favorite_list_channels flc
               JOIN favorite_lists fl ON fl.id = flc.list_id
               WHERE flc.channel_id = c.id) AS lists
            FROM channels c
            JOIN sources s ON s.id = c.source_id
            WHERE (c.favorite = 1 OR c.last_watched IS NOT NULL)
            AND c.series_id IS NULL
            "#,
        )?
        .query_map([], |row| {
            Ok(BackupChannel {
                source: row.get("source")?,
                name: row.get("name")?,
                favorite: row.get::<_, Option<bool>>("favorite")?.unwrap_or(false),
                last_watched: row.get("last_watched")?,
                lists: row
                    .get::<_, Option<String>>("lists")?
                    .map(|l| l.split(LIST_SEPARATOR).map(str::to_string).collect())
                    .unwrap_or_default(),
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(channels)
}

pub fn get_backup_positions() -> Result<Vec<BackupPosition>> {
    let sql = get_conn()?;
    let positions = sql
        .prepare(
            r#"
            SELECT s.name AS source, mp.name, mp.url, mp.position, mp.duration, mp.updated_at
            FROM movie_positions mp
            JOIN sources s ON s.id = mp.source_id
            "#,
        )?
        .query_map([], |row| {
            Ok(BackupPosition {
                source: row.get("source")?,
                name: row.get("name")?,
                url: row.get("url")?,
                position: row.get("position")?,
                duration: row.get("duration")?,
                updated_at: row.get("updated_at")?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(positions)
}

// Adds a source from a backup (without channels) and returns its id.
pub fn insert_backup_source(source: &Source) -> Result<i64> {
    do_tx(|tx| {
        let id = create_or_find_source_by_name(tx, source)?;
        tx.execute(
            "UPDATE sources SET enabled = ?, stream_user_agent = ?, last_updated = NULL WHERE id = ?",
            params![source.enabled, source.stream_user_agent, id],
        )?;
        Ok(id)
    })
}

// Merges backed-up favorites, history and list membership into the channels
// of the given source, matched by name. Never removes existing favorites.
pub fn restore_backup_channels(
    source_id: i64,
    channels: &[&BackupChannel],
    list_ids: &HashMap<String, i64>,
) -> Result<()> {
    do_tx(|tx| {
        for channel in channels {
            tx.prepare_cached(
                r#"
                UPDATE channels
                SET favorite = (COALESCE(favorite, 0) OR ?1),
                    last_watched = CASE
                      WHEN ?2 IS NULL THEN last_watched
                      WHEN last_watched IS NULL OR last_watched < ?2 THEN ?2
                      ELSE last_watched END
                WHERE name = ?3 AND source_id = ?4 AND series_id IS NULL
                "#,
            )?
            .execute(params![
                channel.favorite,
                channel.last_watched,
                channel.name,
                source_id
            ])?;
            if !channel.favorite {
                continue;
            }
            for list in &channel.lists {
                let Some(list_id) = list_ids.get(&list.to_lowercase()) else {
                    continue;
                };
                tx.prepare_cached(
                    r#"
                    INSERT OR IGNORE INTO favorite_list_channels (list_id, channel_id)
                    SELECT ?, id FROM channels
                    WHERE name = ? AND source_id = ? AND series_id IS NULL
                    "#,
                )?
                .execute(params![list_id, channel.name, source_id])?;
            }
        }
        Ok(())
    })
}

// Adds backed-up positions unless a newer one is already stored.
pub fn restore_backup_positions(source_id: i64, positions: &[&BackupPosition]) -> Result<()> {
    do_tx(|tx| {
        for p in positions {
            let newer = tx
                .query_row(
                    &format!(
                        "SELECT 1 FROM movie_positions WHERE {POSITION_IDENTITY} AND COALESCE(updated_at, 0) > COALESCE(?1, 0)"
                    ),
                    params![p.updated_at, source_id, p.name, p.url],
                    |_| Ok(()),
                )
                .optional()?
                .is_some();
            if newer {
                continue;
            }
            tx.execute(
                &format!("DELETE FROM movie_positions WHERE ?1 IS NULL AND {POSITION_IDENTITY}"),
                params![Option::<i64>::None, source_id, p.name, p.url],
            )?;
            tx.execute(
                r#"
                INSERT INTO movie_positions (channel_id, position, duration, updated_at, source_id, name, url)
                VALUES (NULL, ?, ?, ?, ?, ?, ?)
                "#,
                params![p.position, p.duration, p.updated_at, source_id, p.name, p.url],
            )?;
        }
        Ok(())
    })
}

pub fn get_whats_new() -> Result<Option<String>> {
    let sql = get_settings_conn()?;
    let version: Option<String> = sql
        .query_row(
            r#"
        SELECT value 
        FROM settings
        WHERE key = ?
        LIMIT 1
    "#,
            params![LAST_SEEN_VERSION_KEY],
            |row| row.get(0),
        )
        .optional()?;
    Ok(version)
}

pub fn has_sources() -> Result<bool> {
    let sql = get_conn()?;
    Ok(sql
        .query_row("SELECT 1 FROM sources LIMIT 1", [], |row| {
            row.get::<_, u8>(0)
        })
        .optional()?
        .is_some())
}

pub fn get_sources_by_type(source_type: u8) -> Result<Vec<Source>> {
    let sql = get_conn()?;
    let sources: Vec<Source> = sql
        .prepare("SELECT * FROM sources WHERE source_type = ?")?
        .query_map([source_type], row_to_source)?
        .filter_map(Result::ok)
        .collect();
    Ok(sources)
}

// The connection pool and DB path are process-wide, so DB tests share one
// database and run one at a time.
#[cfg(test)]
pub(crate) mod test_db {
    use std::sync::{Mutex, MutexGuard, Once};

    static INIT: Once = Once::new();
    static LOCK: Mutex<()> = Mutex::new(());

    pub fn lock() -> MutexGuard<'static, ()> {
        let guard = LOCK.lock().unwrap_or_else(|e| e.into_inner());
        INIT.call_once(|| {
            let dir = std::env::temp_dir().join(format!("fred-tv-test-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&dir);
            super::DB_PATH_OVERRIDE
                .set(dir.to_string_lossy().to_string())
                .unwrap();
            super::apply_migrations().unwrap();
        });
        guard
    }

    pub fn source(name: &str, source_type: u8, url: Option<&str>) -> i64 {
        let mut sql = super::get_conn().unwrap();
        let tx = sql.transaction().unwrap();
        let id = super::create_or_find_source_by_name(
            &tx,
            &crate::types::Source {
                id: None,
                name: name.to_string(),
                url: url.map(str::to_string),
                url_origin: None,
                username: None,
                password: None,
                source_type,
                enabled: true,
                user_agent: None,
                stream_user_agent: None,
                last_updated: None,
            },
        )
        .unwrap();
        tx.commit().unwrap();
        id
    }
}

#[cfg(test)]
mod test_favorite_lists {
    use super::*;
    use crate::types::Channel;

    fn channel(name: &str, source_id: i64) -> Channel {
        Channel {
            id: None,
            name: name.to_string(),
            url: Some(format!("http://example.local/{name}")),
            group: None,
            image: None,
            media_type: media_type::LIVESTREAM,
            source_id: Some(source_id),
            series_id: None,
            group_id: None,
            favorite: false,
            stream_id: None,
            tv_archive: None,
            season_id: None,
            episode_num: None,
        }
    }

    fn favorites(source_id: i64, list_id: Option<i64>) -> Vec<String> {
        search(Filters {
            query: None,
            source_ids: vec![source_id],
            media_types: Some(vec![media_type::LIVESTREAM]),
            view_type: view_type::FAVORITES,
            page: 1,
            series_id: None,
            group_id: None,
            use_keywords: false,
            sort: sort_type::ALPHABETICAL_ASC,
            season: None,
            favorite_list_id: list_id,
        })
        .unwrap()
        .into_iter()
        .map(|c| c.name)
        .collect()
    }

    fn channel_id(name: &str) -> i64 {
        get_conn()
            .unwrap()
            .query_row(
                "SELECT id FROM channels WHERE name = ? AND source_id = (SELECT id FROM sources WHERE name = 'test')",
                [name],
                |r| r.get(0),
            )
            .unwrap()
    }

    fn refresh(source_id: i64, names: &[&str]) {
        let mut sql = get_conn().unwrap();
        let tx = sql.transaction().unwrap();
        let preserve = get_preserve(&tx, source_id).unwrap();
        wipe(&tx, source_id).unwrap();
        for name in names {
            insert_channel(&tx, channel(name, source_id)).unwrap();
        }
        restore_preserve(&tx, source_id, preserve).unwrap();
        tx.commit().unwrap();
    }

    #[test]
    fn favorite_lists_flow() {
        let _db = super::test_db::lock();
        let source_id = super::test_db::source("test", crate::source_type::M3U, None);
        refresh(source_id, &["BBC News", "ESPN", "CNN"]);

        // Creating and validating lists
        let news = create_favorite_list(" News ").unwrap();
        assert_eq!(news.name, "News");
        let sports = create_favorite_list("Sports").unwrap();
        assert!(create_favorite_list("news").is_err());
        assert!(create_favorite_list("   ").is_err());

        // Adding to lists makes a channel a favorite
        set_channel_favorite_lists(channel_id("BBC News"), true, &[news.id]).unwrap();
        set_channel_favorite_lists(channel_id("CNN"), true, &[news.id, sports.id]).unwrap();
        favorite_channel(channel_id("ESPN"), true).unwrap();
        assert_eq!(favorites(source_id, None), ["BBC News", "CNN", "ESPN"]);
        assert_eq!(favorites(source_id, Some(news.id)), ["BBC News", "CNN"]);
        assert_eq!(favorites(source_id, Some(sports.id)), ["CNN"]);
        assert_eq!(
            get_channel_favorite_lists(channel_id("CNN")).unwrap(),
            [news.id, sports.id]
        );

        // Favoriting without lists keeps existing list entries
        favorite_channel(channel_id("CNN"), true).unwrap();
        assert_eq!(favorites(source_id, Some(sports.id)), ["CNN"]);

        // Lists survive a source refresh, which re-creates the channels
        refresh(source_id, &["BBC News", "ESPN", "CNN", "Bloomberg"]);
        assert_eq!(favorites(source_id, None), ["BBC News", "CNN", "ESPN"]);
        assert_eq!(favorites(source_id, Some(news.id)), ["BBC News", "CNN"]);

        // Renaming
        rename_favorite_list(sports.id, "Sport").unwrap();
        assert!(rename_favorite_list(sports.id, "NEWS").is_err());
        assert_eq!(
            get_favorite_lists().unwrap().iter().map(|l| l.name.as_str()).collect::<Vec<_>>(),
            ["News", "Sport"]
        );

        // Removing a favorite removes it from every list
        favorite_channel(channel_id("CNN"), false).unwrap();
        assert_eq!(favorites(source_id, Some(news.id)), ["BBC News"]);
        assert!(get_channel_favorite_lists(channel_id("CNN")).unwrap().is_empty());

        // Deleting a list keeps its channels in the main favorites
        delete_favorite_list(news.id).unwrap();
        assert_eq!(favorites(source_id, None), ["BBC News", "ESPN"]);
        assert!(get_channel_favorite_lists(channel_id("BBC News")).unwrap().is_empty());

        // Deleting a source removes its list entries
        set_channel_favorite_lists(channel_id("ESPN"), true, &[sports.id]).unwrap();
        delete_source(source_id).unwrap();
        let entries: i64 = get_conn()
            .unwrap()
            .query_row("SELECT count(*) FROM favorite_list_channels", [], |r| r.get(0))
            .unwrap();
        assert_eq!(entries, 0);
        for list in get_favorite_lists().unwrap() {
            delete_favorite_list(list.id).unwrap();
        }
    }
}

#[cfg(test)]
mod test_watch_progress {
    use super::*;
    use crate::types::Channel;

    fn movie(name: &str, source_id: i64) -> Channel {
        Channel {
            id: None,
            name: name.to_string(),
            url: Some(format!("http://example.local/movie/{name}.mp4")),
            group: None,
            image: None,
            media_type: media_type::MOVIE,
            source_id: Some(source_id),
            series_id: None,
            group_id: None,
            favorite: false,
            stream_id: None,
            tv_archive: None,
            season_id: None,
            episode_num: None,
        }
    }

    fn insert_catalog(source_id: i64) {
        let mut sql = get_conn().unwrap();
        let tx = sql.transaction().unwrap();
        let preserve = get_preserve(&tx, source_id).unwrap();
        wipe(&tx, source_id).unwrap();
        insert_channel(&tx, movie("Movie A", source_id)).unwrap();
        insert_channel(&tx, movie("Movie B", source_id)).unwrap();
        insert_channel(
            &tx,
            Channel {
                media_type: media_type::SERIE,
                url: Some("77".to_string()),
                ..movie("The Show", source_id)
            },
        )
        .unwrap();
        for season_number in [1, 2] {
            let season_id = insert_season(
                &tx,
                Season {
                    name: format!("Season {season_number}"),
                    season_number,
                    series_id: 77,
                    source_id,
                    ..Default::default()
                },
            )
            .unwrap();
            for episode in [2, 1] {
                insert_channel(
                    &tx,
                    Channel {
                        series_id: Some(77),
                        season_id: Some(season_id),
                        episode_num: Some(episode),
                        url: Some(format!("http://example.local/series/{season_number}{episode}.mp4")),
                        ..movie(&format!("S{season_number}E{episode}"), source_id)
                    },
                )
                .unwrap();
            }
        }
        restore_preserve(&tx, source_id, preserve).unwrap();
        tx.commit().unwrap();
    }

    fn id(name: &str, source_id: i64) -> i64 {
        get_conn()
            .unwrap()
            .query_row(
                "SELECT id FROM channels WHERE name = ? AND source_id = ?",
                params![name, source_id],
                |r| r.get(0),
            )
            .unwrap()
    }

    fn continue_watching(source_id: i64) -> Vec<(String, i64, Option<String>)> {
        get_continue_watching()
            .unwrap()
            .into_iter()
            .filter(|c| c.channel.source_id == Some(source_id))
            .map(|c| (c.channel.name, c.position, c.series_name))
            .collect()
    }

    #[test]
    fn positions_continue_watching_and_next_episode() {
        let _db = test_db::lock();
        let source_id = test_db::source("watch", crate::source_type::M3U, None);
        insert_catalog(source_id);

        // Positions and Continue Watching
        set_movie_position(id("Movie A", source_id), 600, Some(3600)).unwrap();
        set_movie_position(id("Movie B", source_id), 10, Some(3600)).unwrap();
        set_movie_position(id("S1E2", source_id), 300, Some(1500)).unwrap();
        assert_eq!(get_movie_position(id("Movie A", source_id)).unwrap(), Some(600));
        assert_eq!(get_movie_position(id("Movie B", source_id)).unwrap(), Some(10));
        let names: Vec<String> = continue_watching(source_id).into_iter().map(|c| c.0).collect();
        assert!(names.contains(&"Movie A".to_string()));
        assert!(!names.contains(&"Movie B".to_string()), "too short to list");
        let episode = continue_watching(source_id)
            .into_iter()
            .find(|c| c.0 == "S1E2")
            .unwrap();
        assert_eq!(episode.2.as_deref(), Some("The Show"));

        // Positions survive a refresh, which gives channels new ids (another
        // source's channel takes the next free id, so the ids shift).
        let old_id = id("Movie A", source_id);
        let other = test_db::source("watch other", crate::source_type::M3U, None);
        do_tx(|tx| insert_channel(tx, movie("Other", other))).unwrap();
        insert_catalog(source_id);
        assert_ne!(id("Movie A", source_id), old_id);
        assert_eq!(get_movie_position(id("Movie A", source_id)).unwrap(), Some(600));

        // Updating replaces; finishing removes
        set_movie_position(id("Movie A", source_id), 900, Some(3600)).unwrap();
        assert_eq!(get_movie_position(id("Movie A", source_id)).unwrap(), Some(900));
        set_movie_position(id("Movie A", source_id), 3500, Some(3600)).unwrap();
        assert_eq!(get_movie_position(id("Movie A", source_id)).unwrap(), None);
        remove_movie_position(id("S1E2", source_id)).unwrap();
        assert!(continue_watching(source_id).is_empty());

        // Next episode: by season, then episode number
        let next = |name: &str| get_next_episode(id(name, source_id)).unwrap().map(|c| c.name);
        assert_eq!(next("S1E1").as_deref(), Some("S1E2"));
        assert_eq!(next("S1E2").as_deref(), Some("S2E1"));
        assert_eq!(next("S2E1").as_deref(), Some("S2E2"));
        assert_eq!(next("S2E2"), None);
        assert_eq!(next("Movie A"), None);

        delete_source(source_id).unwrap();
        delete_source(other).unwrap();
    }

    #[test]
    fn backup_round_trip() {
        let _db = test_db::lock();
        let source_id = test_db::source(
            "backup",
            crate::source_type::M3U,
            Some("/does/not/exist.m3u"),
        );
        insert_catalog(source_id);
        let list = create_favorite_list("Backup list").unwrap();
        set_channel_favorite_lists(id("Movie A", source_id), true, &[list.id]).unwrap();
        set_movie_position(id("Movie B", source_id), 1200, Some(3600)).unwrap();
        update_settings(HashMap::from([(
            "seekSeconds".to_string(),
            Some("30".to_string()),
        )]))
        .unwrap();

        let json = crate::backup::export_backup().unwrap();
        assert!(json.contains("\"Backup list\""));

        // Restore onto an empty database (the source file can't be downloaded)
        delete_source(source_id).unwrap();
        delete_favorite_list(list.id).unwrap();
        update_settings(HashMap::from([(
            "seekSeconds".to_string(),
            Some("10".to_string()),
        )]))
        .unwrap();
        let runtime = tokio::runtime::Runtime::new().unwrap();
        let summary = runtime
            .block_on(crate::backup::import_backup(json.clone()))
            .unwrap();
        assert!(summary.contains("Couldn't download backup"), "{summary}");
        assert_eq!(get_settings().unwrap()["seekSeconds"], "30");
        let restored = get_sources().unwrap().into_iter().find(|s| s.name == "backup").unwrap();
        let new_source = restored.id.unwrap();

        // Once the channels exist again, favorites, lists and positions apply
        insert_catalog(new_source);
        let summary = runtime.block_on(crate::backup::import_backup(json)).unwrap();
        assert!(summary.contains("0 sources added"), "{summary}");
        let movie_a = id("Movie A", new_source);
        let lists = get_favorite_lists().unwrap();
        let restored_list = lists.iter().find(|l| l.name == "Backup list").unwrap();
        assert_eq!(get_channel_favorite_lists(movie_a).unwrap(), [restored_list.id]);
        assert_eq!(get_movie_position(id("Movie B", new_source)).unwrap(), Some(1200));

        assert!(crate::backup::import_backup_sync_err("{}"));
        delete_source(new_source).unwrap();
        delete_favorite_list(restored_list.id).unwrap();
    }
}
