use std::collections::HashMap;

use anyhow::{Context, Result, anyhow};

use crate::{
    sql,
    types::{Backup, BackupChannel, BackupLockedGroup, BackupPosition, BackupSource, Source},
    utils,
};

const APP_ID: &str = "fred-tv";
const BACKUP_VERSION: u32 = 1;

// Sources (with credentials), settings, favorite lists, favorites, history and
// watch positions as JSON. Channels themselves are re-downloaded on restore.
pub fn export_backup() -> Result<String> {
    let mut settings = sql::get_settings()?;
    settings.remove(sql::LAST_SEEN_VERSION_KEY);
    let sources = sql::get_sources()?;
    let source_names: HashMap<i64, String> = sources
        .iter()
        .filter_map(|s| s.id.map(|id| (id, s.name.clone())))
        .collect();
    let backup = Backup {
        app: APP_ID.to_string(),
        version: BACKUP_VERSION,
        created_at: chrono::Utc::now().timestamp(),
        sources: sources
            .into_iter()
            .map(|s| BackupSource {
                locked: s.locked,
                name: s.name,
                source_type: s.source_type,
                url: s.url,
                username: s.username,
                password: s.password,
                user_agent: s.user_agent,
                stream_user_agent: s.stream_user_agent,
                enabled: s.enabled,
            })
            .collect(),
        settings,
        favorite_lists: sql::get_favorite_lists()?
            .into_iter()
            .map(|l| l.name)
            .collect(),
        channels: sql::get_backup_channels()?,
        positions: sql::get_backup_positions()?,
        locked_groups: sql::get_locked_groups()?
            .into_iter()
            .filter_map(|(source_id, name)| {
                Some(BackupLockedGroup {
                    source: source_names.get(&source_id)?.clone(),
                    name,
                })
            })
            .collect(),
    };
    Ok(serde_json::to_string_pretty(&backup)?)
}

// Merges a backup into the current data and returns a summary for the user.
// Sources that already exist (by name) are kept as they are; missing ones are
// added and downloaded.
pub async fn import_backup(json: String) -> Result<String> {
    let backup: Backup =
        serde_json::from_str(&json).context("This file is not a Fred TV backup")?;
    if backup.app != APP_ID {
        return Err(anyhow!("This file is not a Fred TV backup"));
    }
    if backup.version > BACKUP_VERSION {
        return Err(anyhow!(
            "This backup was made by a newer version of Fred TV"
        ));
    }

    sql::update_settings(
        backup
            .settings
            .iter()
            .map(|(k, v)| (k.clone(), Some(v.clone())))
            .collect(),
    )?;

    let mut list_ids: HashMap<String, i64> = sql::get_favorite_lists()?
        .into_iter()
        .map(|l| (l.name.to_lowercase(), l.id))
        .collect();
    for name in &backup.favorite_lists {
        if !list_ids.contains_key(&name.trim().to_lowercase()) {
            let list = sql::create_favorite_list(name)?;
            list_ids.insert(list.name.to_lowercase(), list.id);
        }
    }

    let existing: HashMap<String, i64> = sql::get_sources()?
        .into_iter()
        .filter_map(|s| s.id.map(|id| (s.name, id)))
        .collect();
    let mut source_ids = existing.clone();
    let mut added = 0;
    let mut failed: Vec<String> = Vec::new();
    for backup_source in &backup.sources {
        if existing.contains_key(&backup_source.name) {
            continue;
        }
        let mut source = to_source(backup_source);
        let id = sql::insert_backup_source(&source)?;
        source.id = Some(id);
        source_ids.insert(source.name.clone(), id);
        added += 1;
        if let Err(e) = utils::refresh_source(source).await {
            tracing::error!("{:?}", e.context("Failed to load restored source"));
            failed.push(backup_source.name.clone());
        }
    }

    for backup_source in backup.sources.iter().filter(|s| s.locked) {
        if let Some(id) = source_ids.get(&backup_source.name) {
            sql::set_source_locked(*id, true)?;
        }
    }
    for group in &backup.locked_groups {
        if let Some(id) = source_ids.get(&group.source) {
            sql::lock_group_by_name(*id, &group.name)?;
        }
    }

    for (name, id) in &source_ids {
        let channels: Vec<&BackupChannel> =
            backup.channels.iter().filter(|c| &c.source == name).collect();
        if !channels.is_empty() {
            sql::restore_backup_channels(*id, &channels, &list_ids)?;
        }
        let positions: Vec<&BackupPosition> =
            backup.positions.iter().filter(|p| &p.source == name).collect();
        if !positions.is_empty() {
            sql::restore_backup_positions(*id, &positions)?;
        }
    }

    let mut summary = format!(
        "Backup restored: {added} source{} added",
        if added == 1 { "" } else { "s" }
    );
    if !failed.is_empty() {
        summary += &format!(
            ". Couldn't download {}; try refreshing it from Settings",
            failed.join(", ")
        );
    }
    Ok(summary)
}

fn to_source(source: &BackupSource) -> Source {
    Source {
        id: None,
        name: source.name.clone(),
        url: source.url.clone(),
        url_origin: None,
        username: source.username.clone(),
        password: source.password.clone(),
        source_type: source.source_type,
        enabled: source.enabled,
        user_agent: source.user_agent.clone(),
        stream_user_agent: source.stream_user_agent.clone(),
        last_updated: None,
        locked: source.locked,
    }
}

#[cfg(test)]
pub fn import_backup_sync_err(json: &str) -> bool {
    tokio::runtime::Runtime::new()
        .unwrap()
        .block_on(import_backup(json.to_string()))
        .is_err()
}
