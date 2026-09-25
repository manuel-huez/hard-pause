use std::collections::HashSet;
use std::net::IpAddr;

use serde::{Deserialize, Serialize};
use unicode_normalization::{char::is_combining_mark, UnicodeNormalization};
use unicode_segmentation::UnicodeSegmentation;

use crate::protection::ProtectionMode;

const MAXIMUM_DOMAINS: usize = 10_000;
const MAXIMUM_APPLICATIONS: usize = 1_000;
const MAXIMUM_NAME_LENGTH: usize = 120;
const MAXIMUM_REQUIREMENT_LENGTH: usize = 16_384;
const MAXIMUM_URL_PATTERN_LENGTH: usize = 4_096;
const MINIMUM_DELAY: f64 = 60.0;
const MAXIMUM_DELAY: f64 = 366.0 * 24.0 * 60.0 * 60.0;

#[derive(Clone, Debug, Deserialize, Serialize, Eq, Hash, PartialEq)]
pub struct Application {
    pub bundle_identifier: String,
    pub display_name: String,
    pub designated_requirement: Option<String>,
}

impl Application {
    pub(crate) fn id(&self) -> String {
        format!(
            "{}\0{}",
            self.bundle_identifier,
            self.designated_requirement.as_deref().unwrap_or("legacy")
        )
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Rules {
    pub blocked_domains: Vec<String>,
    #[serde(default)]
    pub allowed_domains: Vec<String>,
    pub blocked_applications: Vec<Application>,
    pub blocked_adult_domains: Vec<String>,
    pub adult_rules_version: Option<i64>,
    #[serde(default, rename(serialize = "blockedURLPatterns"))]
    pub blocked_url_patterns: Vec<String>,
    #[serde(default)]
    pub blocks_adult_websites: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct ParsedPattern {
    pub scheme: Option<String>,
    pub host: String,
    pub subdomains: bool,
    pub canonical_host: String,
    pub port: Option<u16>,
    pub resource: Option<String>,
    pub canonical: String,
}

#[derive(Deserialize)]
pub struct BrowserURL {
    pub scheme: Option<String>,
    pub host: Option<String>,
    pub port: Option<i64>,
    pub path: String,
    pub query: Option<String>,
    pub fragment: Option<String>,
}

#[derive(Deserialize)]
pub struct URLMatch {
    pub pattern: String,
    pub url: BrowserURL,
}

#[derive(Deserialize)]
pub struct RuleAdditions {
    pub rules: Rules,
    pub domains: Vec<String>,
    pub url_patterns: Vec<String>,
    pub applications: Vec<Application>,
    pub adult_websites: bool,
}

#[derive(Deserialize)]
pub struct Draft {
    pub name: String,
    pub rules: Rules,
    pub protection_mode: ProtectionMode,
    pub break_delay: String,
    pub full_unlock_delay: String,
    pub break_duration: String,
    pub elapsed_duration: Option<String>,
}

pub fn is_literal_ip_address(value: &str) -> bool {
    value.parse::<IpAddr>().is_ok()
}

pub fn normalize_domain(input: &str) -> Option<String> {
    let mut value = input.trim().to_lowercase();
    if value.is_empty() || value.contains('*') {
        return None;
    }
    value = value.trim_end_matches('.').to_owned();
    if value.is_empty() {
        return None;
    }
    if is_literal_ip_address(&value) {
        return Some(value);
    }
    if value.starts_with('[') && value.ends_with(']') {
        let unwrapped = &value[1..value.len() - 1];
        return is_literal_ip_address(unwrapped).then(|| unwrapped.to_owned());
    }

    let authority = if let Some((scheme, remainder)) = value.split_once("://") {
        if !scheme.starts_with(|c: char| c.is_ascii_alphabetic())
            || !scheme
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'))
        {
            return None;
        }
        remainder
    } else {
        value.as_str()
    };
    let authority = authority.split(['/', '?', '#']).next()?;
    let authority = authority.rsplit('@').next()?;
    let host = if let Some(remainder) = authority.strip_prefix('[') {
        let (address, suffix) = remainder.split_once(']')?;
        if !suffix.is_empty() && !valid_domain_port_suffix(suffix) {
            return None;
        }
        address
    } else {
        let (host, suffix) = authority.split_once(':').unwrap_or((authority, ""));
        if authority.contains(':') && !valid_domain_port_suffix(&format!(":{suffix}")) {
            return None;
        }
        host
    };
    let host = percent_decode_host(host)?.nfc().collect::<String>();
    let host = host.trim_end_matches('.');
    if is_literal_ip_address(host) {
        return Some(host.to_owned());
    }
    if host.is_empty() || host.graphemes(true).count() > 253 || host.contains(['_', ' ']) {
        return None;
    }
    let valid = host.split('.').all(|label| {
        !label.is_empty()
            && label.graphemes(true).count() <= 63
            && !label.starts_with('-')
            && !label.ends_with('-')
            && label.graphemes(true).all(valid_domain_character)
    });
    valid.then(|| host.to_owned())
}

fn valid_domain_character(character: &str) -> bool {
    if character == "-" {
        return true;
    }
    let mut scalars = character.chars();
    scalars.next().is_some_and(char::is_alphanumeric)
        && scalars.all(|scalar| {
            scalar.is_alphanumeric()
                || is_combining_mark(scalar)
                || matches!(scalar, '\u{200c}' | '\u{200d}')
        })
}

fn valid_domain_port_suffix(suffix: &str) -> bool {
    suffix
        .strip_prefix(':')
        .is_some_and(|port| port.bytes().all(|byte| byte.is_ascii_digit()))
}

fn percent_decode_host(host: &str) -> Option<String> {
    percent_decode_utf8(host).map(|value| value.to_lowercase())
}

fn percent_decode_utf8(value: &str) -> Option<String> {
    let bytes = value.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            let hex = bytes.get(index + 1..index + 3)?;
            let value = u8::from_str_radix(std::str::from_utf8(hex).ok()?, 16).ok()?;
            decoded.push(value);
            index += 3;
        } else {
            decoded.push(bytes[index]);
            index += 1;
        }
    }
    String::from_utf8(decoded).ok()
}

pub fn parse_pattern(input: &str) -> Option<ParsedPattern> {
    let value = input.trim();
    if value.is_empty()
        || value.graphemes(true).count() > MAXIMUM_URL_PATTERN_LENGTH
        || value.contains('\\')
        || value
            .chars()
            .any(|c| c.is_whitespace() || c <= '\u{1f}' || c == '\u{7f}')
    {
        return None;
    }
    let (scheme, remainder) = if let Some((candidate, remainder)) = value.split_once("://") {
        let candidate = candidate.to_lowercase();
        if candidate != "http" && candidate != "https" {
            return None;
        }
        (Some(candidate), remainder)
    } else {
        (None, value)
    };
    let resource_start = remainder.find(['/', '?', '#']);
    let authority = resource_start.map_or(remainder, |index| &remainder[..index]);
    let mut resource = resource_start.map(|index| remainder[index..].to_owned());
    if resource.as_ref().is_some_and(|r| r.starts_with(['?', '#'])) {
        resource = resource.map(|r| format!("/{r}"));
    }
    if authority.is_empty() || authority.contains('@') {
        return None;
    }
    let (host, subdomains, canonical_host, port) = parse_authority(authority)?;
    if resource.as_deref() == Some("/") {
        resource = None;
    }
    if resource
        .as_ref()
        .is_some_and(|r| !r.contains(['*', '?', '#']))
    {
        while resource
            .as_ref()
            .is_some_and(|r| r.len() > 1 && r.ends_with('/'))
        {
            resource.as_mut()?.pop();
        }
    }
    let canonical = format!(
        "{}{}{}{}",
        scheme.as_ref().map_or(String::new(), |s| format!("{s}://")),
        canonical_host,
        port.map_or(String::new(), |p| format!(":{p}")),
        resource.as_deref().unwrap_or("")
    );
    Some(ParsedPattern {
        scheme,
        host,
        subdomains,
        canonical_host,
        port,
        resource,
        canonical,
    })
}

fn parse_authority(authority: &str) -> Option<(String, bool, String, Option<u16>)> {
    if let Some(remainder) = authority.strip_prefix('[') {
        let (address, suffix) = remainder.split_once(']')?;
        let port = if suffix.is_empty() {
            None
        } else {
            Some(parse_port(suffix.strip_prefix(':')?)?)
        };
        if !is_literal_ip_address(address) {
            return None;
        }
        let host = address.to_lowercase();
        return Some((host.clone(), false, format!("[{host}]"), port));
    }
    if is_literal_ip_address(authority) {
        let host = authority.to_lowercase();
        let canonical = if host.contains(':') {
            format!("[{host}]")
        } else {
            host.clone()
        };
        return Some((host, false, canonical, None));
    }
    let (host_input, port) = if let Some((host, port)) = authority.rsplit_once(':') {
        if host.contains(':') {
            return None;
        }
        (host, Some(parse_port(port)?))
    } else {
        (authority, None)
    };
    if let Some(suffix_input) = host_input.strip_prefix("*.") {
        let suffix = normalize_domain(suffix_input)?;
        if is_literal_ip_address(&suffix) || suffix.contains(':') {
            return None;
        }
        return Some((suffix.clone(), true, format!("*.{suffix}"), port));
    }
    if host_input.contains('*') {
        return None;
    }
    let host = normalize_domain(host_input)?;
    let canonical = if host.contains(':') {
        format!("[{host}]")
    } else {
        host.clone()
    };
    Some((host, false, canonical, port))
}

fn parse_port(input: &str) -> Option<u16> {
    if input.is_empty() || !input.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let port = input.parse::<u16>().ok()?;
    (port != 0).then_some(port)
}

pub fn exact_domain(input: &str) -> Option<String> {
    let parsed = parse_pattern(input)?;
    (!parsed.subdomains && parsed.port.is_none() && parsed.resource.is_none())
        .then_some(parsed.host)
}

pub fn network_domains(input: &str) -> Vec<String> {
    match parse_pattern(input) {
        Some(parsed)
            if parsed.subdomains
                && parsed.scheme.is_none()
                && parsed.port.is_none()
                && parsed.resource.is_none()
                && parsed.host.contains('.') =>
        {
            vec![format!("www.{}", parsed.host)]
        }
        _ => vec![],
    }
}

pub fn matches_url(input: &URLMatch) -> bool {
    let Some(pattern) = parse_pattern(&input.pattern) else {
        return false;
    };
    let scheme = input.url.scheme.as_deref().unwrap_or("").to_lowercase();
    if scheme != "http" && scheme != "https" {
        return false;
    }
    let Some(host) = input.url.host.as_deref() else {
        return false;
    };
    let host = host.to_lowercase();
    let host = host.trim_end_matches('.');
    if pattern
        .scheme
        .as_ref()
        .is_some_and(|expected| expected != &scheme)
    {
        return false;
    }
    let expected_host = idna::domain_to_ascii(&pattern.host)
        .ok()
        .unwrap_or(pattern.host)
        .to_lowercase();
    if pattern.subdomains {
        if host == expected_host || !host.ends_with(&format!(".{expected_host}")) {
            return false;
        }
    } else if host != expected_host {
        return false;
    }
    if let Some(port) = pattern.port {
        let effective_port = input.url.port.or(match scheme.as_str() {
            "http" => Some(80),
            "https" => Some(443),
            _ => None,
        });
        if effective_port != Some(i64::from(port)) {
            return false;
        }
    }
    let Some(resource) = pattern.resource else {
        return true;
    };
    if !resource.contains(['*', '?', '#']) {
        let path = percent_decode_utf8(&input.url.path).unwrap_or_else(|| input.url.path.clone());
        let expected = percent_decode_utf8(&resource).unwrap_or(resource);
        return path == expected || path.starts_with(&format!("{expected}/"));
    }
    let mut actual = input.url.path.clone();
    if let Some(query) = &input.url.query {
        actual.push('?');
        actual.push_str(query);
    }
    if let Some(fragment) = &input.url.fragment {
        actual.push('#');
        actual.push_str(fragment);
    }
    glob_matches(&resource, &actual)
        || glob_matches(
            &resource,
            &percent_decode_utf8(&actual).unwrap_or(actual.clone()),
        )
}

fn glob_matches(pattern: &str, value: &str) -> bool {
    let pattern_bytes = pattern.as_bytes();
    let value_bytes = value.as_bytes();
    let (mut pattern_index, mut value_index) = (0, 0);
    let mut star_index = None;
    let mut value_after_star = 0;
    while value_index < value_bytes.len() {
        if pattern_index < pattern_bytes.len()
            && pattern_bytes[pattern_index] == value_bytes[value_index]
        {
            pattern_index += 1;
            value_index += 1;
        } else if pattern_index < pattern_bytes.len() && pattern_bytes[pattern_index] == b'*' {
            star_index = Some(pattern_index);
            pattern_index += 1;
            value_after_star = value_index;
        } else if let Some(star_index) = star_index {
            pattern_index = star_index + 1;
            value_after_star += 1;
            value_index = value_after_star;
        } else {
            return false;
        }
    }
    while pattern_index < pattern_bytes.len() && pattern_bytes[pattern_index] == b'*' {
        pattern_index += 1;
    }
    pattern_index == pattern_bytes.len()
}

fn unique_by<T>(values: impl IntoIterator<Item = T>, key: impl Fn(&T) -> String) -> Vec<T> {
    let mut seen = HashSet::new();
    values
        .into_iter()
        .filter(|value| seen.insert(key(value)))
        .collect()
}

pub fn normalize_rules(mut rules: Rules) -> Rules {
    let network_domains = rules
        .blocked_url_patterns
        .iter()
        .flat_map(|pattern| network_domains(pattern))
        .collect::<Vec<_>>();
    rules.blocked_domains = unique_by(
        rules
            .blocked_domains
            .into_iter()
            .chain(network_domains)
            .filter_map(|domain| normalize_domain(&domain)),
        Clone::clone,
    );
    rules.blocked_applications = unique_by(rules.blocked_applications, Application::id);
    rules.allowed_domains = unique_by(
        rules.allowed_domains.into_iter().filter_map(|domain| normalize_domain(&domain)),
        Clone::clone,
    );
    rules.blocked_url_patterns = unique_by(
        rules
            .blocked_url_patterns
            .into_iter()
            .filter_map(|pattern| parse_pattern(&pattern).map(|parsed| parsed.canonical)),
        Clone::clone,
    );
    rules
}

pub fn add_rules(mut additions: RuleAdditions) -> Rules {
    let network_domains = additions
        .url_patterns
        .iter()
        .flat_map(|pattern| network_domains(pattern))
        .collect::<Vec<_>>();
    additions.rules.blocked_domains = unique_by(
        additions
            .rules
            .blocked_domains
            .into_iter()
            .chain(additions.domains)
            .chain(network_domains),
        Clone::clone,
    );
    additions.rules.blocked_applications = unique_by(
        additions
            .rules
            .blocked_applications
            .into_iter()
            .chain(additions.applications),
        Application::id,
    );
    additions.rules.blocked_url_patterns = unique_by(
        additions
            .rules
            .blocked_url_patterns
            .into_iter()
            .chain(additions.url_patterns),
        Clone::clone,
    );
    additions.rules.blocks_adult_websites |= additions.adult_websites;
    additions.rules
}

pub fn includes_all_rules(current: &Rules, previous: &Rules) -> bool {
    fn subset<T: Eq + std::hash::Hash>(current: &[T], previous: &[T]) -> bool {
        let values = current.iter().collect::<HashSet<_>>();
        previous.iter().all(|value| values.contains(value))
    }
    subset(&current.blocked_domains, &previous.blocked_domains)
        && subset(&previous.allowed_domains, &current.allowed_domains)
        && subset(
            &current.blocked_url_patterns,
            &previous.blocked_url_patterns,
        )
        && subset(
            &current.blocked_applications,
            &previous.blocked_applications,
        )
        && subset(
            &current.blocked_adult_domains,
            &previous.blocked_adult_domains,
        )
        && (!previous.blocks_adult_websites || current.blocks_adult_websites)
        && (previous.blocked_adult_domains.is_empty()
            || current.adult_rules_version == previous.adult_rules_version)
}

pub fn validate_rules(
    rules: &Rules,
    allow_legacy_application_identity: bool,
) -> Result<(), &'static str> {
    if rules.blocked_domains.len()
        + rules.allowed_domains.len()
        + rules.blocked_adult_domains.len()
        + rules.blocked_url_patterns.len()
        > MAXIMUM_DOMAINS
        || rules.blocked_applications.len() > MAXIMUM_APPLICATIONS
    {
        return Err("too_many_rules");
    }
    if rules.blocked_domains.is_empty()
        && rules.blocked_adult_domains.is_empty()
        && rules.blocked_applications.is_empty()
        && rules.blocked_url_patterns.is_empty()
        && !rules.blocks_adult_websites
    {
        return Err("no_rules");
    }
    if rules
        .blocked_domains
        .iter()
        .chain(&rules.blocked_adult_domains)
        .any(|domain| {
            normalize_domain(domain).as_deref() != Some(domain)
                || domain.graphemes(true).count() > 253
        })
        || unique_by(rules.blocked_domains.iter(), |s| (*s).clone()).len()
            != rules.blocked_domains.len()
        || unique_by(rules.blocked_adult_domains.iter(), |s| (*s).clone()).len()
            != rules.blocked_adult_domains.len()
    {
        return Err("invalid_domain");
    }
    if rules.allowed_domains.iter().any(|domain| {
        normalize_domain(domain).as_deref() != Some(domain)
            || is_literal_ip_address(domain)
            || domain.graphemes(true).count() > 253
    }) || unique_by(rules.allowed_domains.iter(), |s| (*s).clone()).len()
        != rules.allowed_domains.len()
    {
        return Err("invalid_domain");
    }
    if rules.blocked_url_patterns.iter().any(|pattern| {
        pattern.graphemes(true).count() > MAXIMUM_URL_PATTERN_LENGTH
            || parse_pattern(pattern)
                .as_ref()
                .map(|parsed| parsed.canonical.as_str())
                != Some(pattern)
    }) || unique_by(rules.blocked_url_patterns.iter(), |s| (*s).clone()).len()
        != rules.blocked_url_patterns.len()
    {
        return Err("invalid_url_pattern");
    }
    if rules.blocked_adult_domains.is_empty() != rules.adult_rules_version.is_none() {
        return Err("invalid_adult_rules");
    }
    if unique_by(rules.blocked_applications.iter(), |app| app.id()).len()
        != rules.blocked_applications.len()
    {
        return Err("duplicate_application");
    }
    for app in &rules.blocked_applications {
        if app.bundle_identifier.is_empty()
            || app.bundle_identifier.graphemes(true).count() > 512
            || app.display_name.is_empty()
            || app.display_name.graphemes(true).count() > 512
        {
            return Err("invalid_application");
        }
        if let Some(requirement) = &app.designated_requirement {
            if requirement.is_empty()
                || requirement.graphemes(true).count() > MAXIMUM_REQUIREMENT_LENGTH
            {
                return Err("invalid_application_identity");
            }
        } else if !allow_legacy_application_identity {
            return Err("missing_application_identity");
        }
    }
    Ok(())
}

pub fn validate_draft(
    draft: &Draft,
    mutation: bool,
    allow_legacy_application_identity: bool,
) -> Result<String, &'static str> {
    let clean_name = draft.name.trim();
    if mutation {
        if clean_name.is_empty() || clean_name.graphemes(true).count() > MAXIMUM_NAME_LENGTH {
            return Err("invalid_mutation_name");
        }
    } else if clean_name != draft.name
        || draft.name.is_empty()
        || draft.name.graphemes(true).count() > MAXIMUM_NAME_LENGTH
    {
        return Err("invalid_saved_name");
    }
    validate_rules(&draft.rules, allow_legacy_application_identity)?;
    for (value, code) in [
        (&draft.break_delay, "invalid_break_delay"),
        (&draft.full_unlock_delay, "invalid_full_unlock_delay"),
        (&draft.break_duration, "invalid_break_duration"),
    ] {
        validate_duration(value).map_err(|_| code)?;
    }
    if let Some(value) = &draft.elapsed_duration {
        validate_duration(value).map_err(|_| "invalid_fixed_duration")?;
    }
    if !draft.protection_mode.allows_breaks() && draft.elapsed_duration.is_some() {
        return Err(if mutation {
            "invalid_mutation_fixed_plan"
        } else {
            "invalid_saved_fixed_plan"
        });
    }
    Ok(clean_name.to_owned())
}

fn validate_duration(value: &str) -> Result<(), ()> {
    let duration = value.parse::<f64>().map_err(|_| ())?;
    if duration.is_finite() && (MINIMUM_DELAY..=MAXIMUM_DELAY).contains(&duration) {
        Ok(())
    } else {
        Err(())
    }
}
