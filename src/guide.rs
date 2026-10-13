// The full programme guide (XMLTV), stored locally so programmes can be
// searched. Xtream sources serve it at /xmltv.php; M3U playlists may name one
// in their header (url-tvg / x-tvg-url). Programmes are matched to channels
// by their guide id (Xtream `epg_channel_id`, M3U `tvg-id`).

use std::{
    collections::HashMap,
    fs::File,
    io::{BufRead, BufReader, Read, Write},
    path::PathBuf,
    sync::atomic::{AtomicBool, Ordering},
};

use anyhow::{Context, Result, bail};
use flate2::read::MultiGzDecoder;
use quick_xml::{Reader, events::Event};

use crate::{
    source_type, sql,
    types::Source,
    utils::{self, get_user_agent_from_source},
    xtream,
};

// Guides are downloaded again after this long.
const UPDATE_EVERY_SECONDS: i64 = 12 * 60 * 60;
// Kept: past programmes of channels with an archive (for catch-up), and the
// coming days.
const KEEP_PAST_SECONDS: i64 = 7 * 24 * 60 * 60;
const KEEP_FUTURE_SECONDS: i64 = 3 * 24 * 60 * 60;
const MAX_DESCRIPTION_CHARS: usize = 400;

static UPDATING: AtomicBool = AtomicBool::new(false);

pub struct GuideProgram {
    pub epg_id: String,
    pub title: String,
    pub description: Option<String>,
    pub start: i64,
    pub stop: i64,
}

// Downloads the guides of enabled sources that have one and haven't been
// updated recently (or all of them with `force`). Returns without doing
// anything while another update runs.
pub async fn update_guides(force: bool) -> Result<()> {
    if UPDATING.swap(true, Ordering::SeqCst) {
        return Ok(());
    }
    let result = update_all(force).await;
    UPDATING.store(false, Ordering::SeqCst);
    result
}

async fn update_all(force: bool) -> Result<()> {
    let now = chrono::Utc::now().timestamp();
    let mut failed = Vec::new();
    for source in sql::get_sources()? {
        let Some(source_id) = source.id else { continue };
        if !source.enabled {
            continue;
        }
        let recent = sql::get_guide_updated(source_id)?
            .is_some_and(|updated| now - updated < UPDATE_EVERY_SECONDS);
        if recent && !force {
            continue;
        }
        let Some(url) = guide_url(&source)? else {
            continue;
        };
        if let Err(e) = update_source(&source, source_id, &url).await {
            tracing::error!("{:?}", e.context(format!("Guide for {}", source.name)));
            failed.push(source.name);
        }
    }
    if !failed.is_empty() {
        bail!("Couldn't download the programme guide of {}", failed.join(", "));
    }
    Ok(())
}

fn guide_url(source: &Source) -> Result<Option<String>> {
    Ok(match source.source_type {
        source_type::XTREAM => {
            let mut source = source.clone();
            let mut url = xtream::build_xtream_url(&mut source)?;
            url.set_path("/xmltv.php");
            Some(url.to_string())
        }
        source_type::M3U | source_type::M3U_LINK => {
            sql::get_source_epg_url(source.id.context("no source id")?)?
        }
        _ => None,
    })
}

async fn update_source(source: &Source, source_id: i64, url: &str) -> Result<()> {
    // Channels imported before guide ids were stored get them on the next
    // refresh; until then there's nothing to match, so it isn't marked done.
    let channels = sql::get_guide_channels(source_id)?;
    if channels.is_empty() {
        return Ok(());
    }
    let path = download(source, url).await?;
    let programs = tokio::task::spawn_blocking(move || {
        let file = File::open(&path).context("Failed to open the guide")?;
        let now = chrono::Utc::now().timestamp();
        let programs = read_guide(file, &channels, now);
        let _ = std::fs::remove_file(&path);
        programs
    })
    .await??;
    tracing::info!("Guide for {}: {} programmes", source.name, programs.len());
    sql::replace_guide_programs(source_id, &programs)?;
    Ok(())
}

async fn download(source: &Source, url: &str) -> Result<PathBuf> {
    let client = reqwest::Client::builder()
        .user_agent(get_user_agent_from_source(source)?)
        .build()?;
    let mut response = client.get(url).send().await?;
    if !response.status().is_success() {
        bail!("Guide download failed, status: {}", response.status());
    }
    let mut path = PathBuf::from(utils::TEMP_PATH.get().context("no temp path")?);
    std::fs::create_dir_all(&path)?;
    path.push("guide.xml");
    let mut file = File::create(&path)?;
    while let Some(chunk) = response.chunk().await? {
        file.write_all(&chunk)?;
    }
    Ok(path)
}

// Reads the programmes of the given channels (guide id -> has archive) from an
// XMLTV file, gzipped or not.
pub fn read_guide(
    file: impl Read,
    channels: &HashMap<String, bool>,
    now: i64,
) -> Result<Vec<GuideProgram>> {
    let mut reader = BufReader::new(file);
    let gzipped = reader.fill_buf()?.starts_with(&[0x1f, 0x8b]);
    if gzipped {
        parse_guide(BufReader::new(MultiGzDecoder::new(reader)), channels, now)
    } else {
        parse_guide(reader, channels, now)
    }
}

#[derive(PartialEq)]
enum Field {
    None,
    Title,
    Description,
}

fn parse_guide(
    input: impl BufRead,
    channels: &HashMap<String, bool>,
    now: i64,
) -> Result<Vec<GuideProgram>> {
    let mut reader = Reader::from_reader(input);
    let mut buf = Vec::new();
    let mut programs = Vec::new();
    let mut current: Option<GuideProgram> = None;
    let mut field = Field::None;
    loop {
        match reader.read_event_into(&mut buf)? {
            Event::Start(e) if e.name().as_ref() == b"programme" => {
                current = program_from_attributes(&e, channels, now);
            }
            Event::Start(e) if current.is_some() => {
                field = match e.name().as_ref() {
                    // Only the first title and description (others are translations)
                    b"title" if current.as_ref().is_some_and(|p| p.title.is_empty()) => {
                        Field::Title
                    }
                    b"desc" if current.as_ref().is_some_and(|p| p.description.is_none()) => {
                        Field::Description
                    }
                    _ => Field::None,
                }
            }
            Event::Text(e) if field != Field::None => {
                push_text(&mut current, &field, &e.decode()?);
            }
            Event::CData(e) if field != Field::None => {
                push_text(&mut current, &field, &e.decode()?);
            }
            Event::GeneralRef(e) if field != Field::None => {
                let text = match e.resolve_char_ref()? {
                    Some(c) => c.to_string(),
                    None => match e.decode()?.as_ref() {
                        "amp" => "&",
                        "lt" => "<",
                        "gt" => ">",
                        "quot" => "\"",
                        "apos" => "'",
                        _ => "",
                    }
                    .to_string(),
                };
                push_text(&mut current, &field, &text);
            }
            Event::End(e) => {
                if e.name().as_ref() == b"programme" {
                    if let Some(mut program) = current.take() {
                        program.title = program.title.trim().to_string();
                        program.description = program
                            .description
                            .map(|d| d.trim().chars().take(MAX_DESCRIPTION_CHARS).collect())
                            .filter(|d: &String| !d.is_empty());
                        if !program.title.is_empty() {
                            programs.push(program);
                        }
                    }
                }
                field = Field::None;
            }
            Event::Eof => break,
            _ => {}
        }
        buf.clear();
    }
    Ok(programs)
}

fn push_text(current: &mut Option<GuideProgram>, field: &Field, text: &str) {
    let Some(program) = current else { return };
    match field {
        Field::Title => program.title.push_str(text),
        Field::Description => program.description.get_or_insert_with(String::new).push_str(text),
        Field::None => {}
    }
}

// The programme if its channel is one of ours and it falls in the kept window.
fn program_from_attributes(
    e: &quick_xml::events::BytesStart,
    channels: &HashMap<String, bool>,
    now: i64,
) -> Option<GuideProgram> {
    let attribute = |name: &str| -> Option<String> {
        e.try_get_attribute(name)
            .ok()
            .flatten()
            .and_then(|a| a.unescape_value().ok().map(|v| v.trim().to_string()))
    };
    let epg_id = attribute("channel")?;
    let has_archive = *channels.get(&epg_id)?;
    let start = parse_time(&attribute("start")?)?;
    let stop = parse_time(&attribute("stop")?)?;
    let oldest = if has_archive { now - KEEP_PAST_SECONDS } else { now };
    if stop <= oldest || start > now + KEEP_FUTURE_SECONDS || stop <= start {
        return None;
    }
    Some(GuideProgram {
        epg_id,
        title: String::new(),
        description: None,
        start,
        stop,
    })
}

// XMLTV times: "20261013190000 +0300", or without an offset meaning UTC.
fn parse_time(text: &str) -> Option<i64> {
    let text = text.trim();
    if let Ok(t) = chrono::DateTime::parse_from_str(text, "%Y%m%d%H%M%S %z") {
        return Some(t.timestamp());
    }
    chrono::NaiveDateTime::parse_from_str(text.get(0..14)?, "%Y%m%d%H%M%S")
        .ok()
        .map(|t| t.and_utc().timestamp())
}

#[cfg(test)]
mod tests {
    use super::*;

    const GUIDE: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<tv>
  <channel id="news.uk"><display-name>News</display-name></channel>
  <programme start="20261013100000 +0000" stop="20261013110000 +0000" channel="news.uk">
    <title lang="en">Morning &amp; Co</title>
    <title lang="fr">Matin</title>
    <desc lang="en">Headlines &#8211; weather</desc>
  </programme>
  <programme start="20261013110000 +0200" stop="20261013120000 +0200" channel="news.uk">
    <title><![CDATA[Midday]]></title>
  </programme>
  <programme start="20261001100000 +0000" stop="20261001110000 +0000" channel="news.uk">
    <title>Too old</title>
  </programme>
  <programme start="20261013100000 +0000" stop="20261013110000 +0000" channel="other">
    <title>Not ours</title>
  </programme>
  <programme start="20261013090000" stop="20261013100000" channel="kids">
    <title>Past without archive</title>
  </programme>
  <programme start="20261013120000" stop="20261013130000" channel="kids">
    <title>Cartoons</title>
  </programme>
</tv>"#;

    fn channels() -> HashMap<String, bool> {
        HashMap::from([("news.uk".to_string(), true), ("kids".to_string(), false)])
    }

    // 2026-10-13 10:30 UTC
    const NOW: i64 = 1_791_887_400;

    #[test]
    fn reads_programmes_of_known_channels_in_window() {
        let programs = read_guide(GUIDE.as_bytes(), &channels(), NOW).unwrap();
        let titles: Vec<&str> = programs.iter().map(|p| p.title.as_str()).collect();
        assert_eq!(titles, ["Morning & Co", "Midday", "Cartoons"]);
        assert_eq!(programs[0].description.as_deref(), Some("Headlines \u{2013} weather"));
        assert_eq!(programs[0].start, NOW - 30 * 60);
        // +0200: 11:00 local is 09:00 UTC, already over but kept for the archive
        assert_eq!(programs[1].stop, NOW - 30 * 60);
        assert_eq!(programs[2].epg_id, "kids");
    }

    #[test]
    fn reads_gzipped_guides() {
        let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
        encoder.write_all(GUIDE.as_bytes()).unwrap();
        let gz = encoder.finish().unwrap();
        assert_eq!(read_guide(gz.as_slice(), &channels(), NOW).unwrap().len(), 3);
    }
}
