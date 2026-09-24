use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

pub const MAXIMUM_BYTES: usize = 32 * 1024 * 1024;
pub const MAXIMUM_ENTRIES: usize = 1_500_000;
pub const MAXIMUM_SUPPLEMENT_BYTES: usize = 1024 * 1024;
pub const MAXIMUM_SUPPLEMENT_ENTRIES: usize = 10_000;

#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum DomainListFormat {
    BlockListProject { minimum_count: usize },
    HardPauseSupplement { category: String },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct PortableDomainList {
    pub domains: BTreeSet<String>,
    pub skipped_entries: usize,
    pub metadata: BTreeMap<String, String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct InvalidData;

impl PortableDomainList {
    pub fn parse(data: &[u8], format: &DomainListFormat) -> Result<Self, InvalidData> {
        let maximum_bytes = match format {
            DomainListFormat::BlockListProject { .. } => MAXIMUM_BYTES,
            DomainListFormat::HardPauseSupplement { .. } => MAXIMUM_SUPPLEMENT_BYTES,
        };
        if data.len() > maximum_bytes {
            return Err(InvalidData);
        }
        let text = std::str::from_utf8(data).map_err(|_| InvalidData)?;
        let mut domains = BTreeSet::new();
        let mut metadata = BTreeMap::new();
        let mut duplicate_metadata = false;
        let mut entries = 0;
        let mut skipped_entries = 0;
        for line in text.split(|character: char| {
            matches!(character, '\n' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}')
        }) {
            let trimmed = line.trim();
            if let Some(declaration) = trimmed.strip_prefix('#') {
                if let Some((key, value)) = declaration.trim().split_once(':') {
                    let key = key.trim().to_lowercase();
                    if key.is_empty() {
                        return Err(InvalidData);
                    }
                    if metadata.insert(key, value.trim().to_owned()).is_some() {
                        duplicate_metadata = true;
                    }
                }
                continue;
            }
            if trimmed.is_empty() {
                continue;
            }
            entries += 1;
            if entries > MAXIMUM_ENTRIES {
                return Err(InvalidData);
            }
            let domain = trimmed.to_lowercase();
            if is_valid_domain(&domain) {
                domains.insert(domain);
            } else {
                skipped_entries += 1;
            }
        }
        let declared_count = metadata
            .get("entries")
            .and_then(|count| count.replace(',', "").trim().parse::<usize>().ok());
        if declared_count != Some(entries) {
            return Err(InvalidData);
        }
        match format {
            DomainListFormat::BlockListProject { minimum_count } => {
                if domains.len() < *minimum_count || skipped_entries > entries / 1000 {
                    return Err(InvalidData);
                }
            }
            DomainListFormat::HardPauseSupplement { category } => {
                if metadata.get("format").map(String::as_str) != Some("hard-pause-domain-list-v1")
                    || !metadata
                        .get("category")
                        .is_some_and(|found| found.eq_ignore_ascii_case(category))
                    || !metadata
                        .get("revision")
                        .is_some_and(|date| is_iso_date(date))
                    || !metadata
                        .get("license")
                        .is_some_and(|value| !value.is_empty())
                    || !metadata
                        .get("provenance")
                        .is_some_and(|value| !value.is_empty())
                    || duplicate_metadata
                    || entries > MAXIMUM_SUPPLEMENT_ENTRIES
                    || skipped_entries != 0
                    || domains.len() != entries
                {
                    return Err(InvalidData);
                }
            }
        }
        Ok(Self {
            domains,
            skipped_entries,
            metadata,
        })
    }

    pub fn contains(&self, canonical_ascii_host: &str) -> bool {
        contains(canonical_ascii_host, &self.domains)
    }
}

pub fn contains(canonical_ascii_host: &str, domains: &BTreeSet<String>) -> bool {
    let host = canonical_ascii_host.to_lowercase();
    let mut candidate = host.trim_matches('.');
    while candidate.contains('.') {
        if domains.contains(candidate) {
            return true;
        }
        candidate = match candidate.split_once('.') {
            Some((_, remainder)) => remainder,
            None => break,
        };
    }
    false
}

pub fn is_valid_domain(value: &str) -> bool {
    if value.len() > 253 || !value.contains('.') {
        return false;
    }
    let Some(last) = value.rsplit('.').next() else {
        return false;
    };
    if !last.bytes().any(|byte| byte.is_ascii_alphabetic()) {
        return false;
    }
    value.split('.').all(|label| {
        !label.is_empty()
            && label.len() <= 63
            && !label.starts_with('-')
            && !label.ends_with('-')
            && label
                .bytes()
                .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
    })
}

fn is_iso_date(value: &str) -> bool {
    let bytes = value.as_bytes();
    if bytes.len() != 10
        || bytes[4] != b'-'
        || bytes[7] != b'-'
        || !bytes
            .iter()
            .enumerate()
            .all(|(index, byte)| index == 4 || index == 7 || byte.is_ascii_digit())
    {
        return false;
    }
    let year = value[0..4].parse::<u32>().unwrap_or(0);
    let month = value[5..7].parse::<u32>().unwrap_or(0);
    let day = value[8..10].parse::<u32>().unwrap_or(0);
    if year == 0 {
        return false;
    }
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    let days_in_month = match month {
        2 if leap => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        _ => return false,
    };
    (1..=days_in_month).contains(&day)
}
