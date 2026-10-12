use std::{
    collections::HashMap,
    sync::{LazyLock, Mutex},
};

use anyhow::{Context, Result};
use futures::{StreamExt, stream};

use crate::{
    sql::{self, EpgTarget},
    types::{EpgNowNext, EpgProgram, Source},
    xtream,
};

// Programmes fetched per channel for now/next; a few spare ones let the cache
// stay useful after the current programme ends.
const SHORT_EPG_LIMIT: u32 = 4;
const CACHE_SECONDS: i64 = 30 * 60;
const PARALLEL_REQUESTS: usize = 6;

struct Cached {
    fetched_at: i64,
    programs: Vec<EpgProgram>,
}

// Keyed by (source id, stream id), so it survives a refresh's new channel ids.
static CACHE: LazyLock<Mutex<HashMap<(i64, i64), Cached>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

// What's on now and next for these channels. Only Xtream livestreams have an
// EPG; other channels are left out of the result.
pub async fn get_now_next(channel_ids: Vec<i64>) -> Result<Vec<EpgNowNext>> {
    let targets = sql::get_epg_targets(&channel_ids)?;
    let sources = sources_by_id(&targets)?;
    let now = chrono::Utc::now().timestamp();
    let clients: HashMap<i64, reqwest::Client> = sources
        .iter()
        .filter_map(|(id, s)| xtream::build_client(s).ok().map(|c| (*id, c)))
        .collect();
    let results: Vec<Option<EpgNowNext>> = stream::iter(targets)
        .map(|target| {
            let source = sources.get(&target.source_id);
            let client = clients.get(&target.source_id);
            async move {
                let programs = programs_for(&target, source?, client?, now).await;
                Some(now_next(target.channel_id, &programs, now))
            }
        })
        .buffer_unordered(PARALLEL_REQUESTS)
        .collect()
        .await;
    Ok(results.into_iter().flatten().collect())
}

// The channel's guide for catch-up: programmes that can be replayed from the
// archive, plus the one on now and those coming up.
pub async fn get_programs(channel_id: i64) -> Result<Vec<EpgProgram>> {
    let target = sql::get_epg_targets(&[channel_id])?
        .into_iter()
        .next()
        .context("This channel has no programme guide")?;
    let source = sql::get_source_from_id(target.source_id)?;
    let now = chrono::Utc::now().timestamp();
    Ok(xtream::get_epg_table(&source, target.stream_id)
        .await?
        .into_iter()
        .filter(|p| p.stop > now || p.has_archive)
        .collect())
}

fn sources_by_id(targets: &[EpgTarget]) -> Result<HashMap<i64, Source>> {
    let mut sources = HashMap::new();
    for target in targets {
        if !sources.contains_key(&target.source_id) {
            sources.insert(target.source_id, sql::get_source_from_id(target.source_id)?);
        }
    }
    Ok(sources)
}

async fn programs_for(
    target: &EpgTarget,
    source: &Source,
    client: &reqwest::Client,
    now: i64,
) -> Vec<EpgProgram> {
    let key = (target.source_id, target.stream_id);
    if let Some(cached) = CACHE.lock().unwrap().get(&key) {
        let fresh = now - cached.fetched_at < CACHE_SECONDS;
        // Refetch early once the cached programmes have run out.
        let covers_now = cached.programs.is_empty() || cached.programs.iter().any(|p| p.stop > now);
        if fresh && covers_now {
            return cached.programs.clone();
        }
    }
    let programs = xtream::get_short_epg(client, source, target.stream_id, SHORT_EPG_LIMIT)
        .await
        .inspect_err(|e| tracing::warn!("EPG for stream {}: {:?}", target.stream_id, e))
        .unwrap_or_default();
    CACHE.lock().unwrap().insert(
        key,
        Cached {
            fetched_at: now,
            programs: programs.clone(),
        },
    );
    programs
}

fn now_next(channel_id: i64, programs: &[EpgProgram], now: i64) -> EpgNowNext {
    let current = programs.iter().find(|p| p.start <= now && p.stop > now);
    let next = programs
        .iter()
        .find(|p| p.start >= current.map_or(now, |c| c.stop) && p.start > now);
    EpgNowNext {
        channel_id,
        now: current.cloned(),
        next: next.cloned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn program(start: i64, stop: i64) -> EpgProgram {
        EpgProgram {
            title: format!("{start}"),
            description: None,
            start,
            stop,
            has_archive: false,
            catchup_url: None,
        }
    }

    #[test]
    fn picks_now_and_next() {
        let programs = [program(0, 100), program(100, 200), program(200, 300)];
        let e = now_next(1, &programs, 150);
        assert_eq!(e.now.unwrap().start, 100);
        assert_eq!(e.next.unwrap().start, 200);
        // In a gap between programmes there's nothing on now
        let e = now_next(1, &[program(0, 100), program(120, 200)], 110);
        assert!(e.now.is_none());
        assert_eq!(e.next.unwrap().start, 120);
        let e = now_next(1, &programs, 400);
        assert!(e.now.is_none() && e.next.is_none());
    }
}
