use std::path::PathBuf;
use std::str::FromStr;
use std::sync::OnceLock;
use std::vec;
use std::{collections::HashMap, sync::LazyLock};

use crate::sort_type;
use crate::types::{ChannelPreserve, FavoriteList, Season};
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

pub fn set_movie_position(channel_id: i64, movie_position: i64) -> Result<()> {
    let sql = get_conn()?;
    sql.execute(
        r#"
        INSERT INTO movie_positions (channel_id, position)
        VALUES (?, ?)
        ON CONFLICT(channel_id) DO UPDATE SET position = excluded.position
        "#,
        params![channel_id, movie_position],
    )?;
    Ok(())
}

pub fn get_movie_position(channel_id: i64) -> Result<Option<i64>> {
    let sql = get_conn()?;
    let position: Option<i64> = sql
        .query_row(
            r#"
        SELECT position
        FROM movie_positions
        WHERE channel_id = ?
        LIMIT 1
    "#,
            params!(channel_id),
            |row| row.get(0),
        )
        .optional()?;
    Ok(position)
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
            .query_row("SELECT id FROM channels WHERE name = ?", [name], |r| r.get(0))
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

    // One test, because the connection pool and DB path are process-wide.
    #[test]
    fn favorite_lists_flow() {
        let dir = std::env::temp_dir().join(format!("fred-tv-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        DB_PATH_OVERRIDE.set(dir.to_string_lossy().to_string()).unwrap();
        apply_migrations().unwrap();

        let source_id = {
            let mut sql = get_conn().unwrap();
            let tx = sql.transaction().unwrap();
            let id = create_or_find_source_by_name(
                &tx,
                &crate::types::Source {
                    id: None,
                    name: "test".to_string(),
                    url: None,
                    url_origin: None,
                    username: None,
                    password: None,
                    source_type: crate::source_type::M3U,
                    enabled: true,
                    user_agent: None,
                    stream_user_agent: None,
                    last_updated: None,
                },
            )
            .unwrap();
            tx.commit().unwrap();
            id
        };
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
    }
}
