use hard_pause_core::dispatch;
use serde_json::{json, Value};

fn call(op: &str, args: Value) -> Value {
    dispatch(
        json!({"version": 1, "op": op, "args": args})
            .to_string()
            .as_bytes(),
    )
}

#[test]
fn normalizes_domain_and_scoped_pattern_without_broadening_it() {
    assert_eq!(
        call(
            "policy.normalize_domain",
            json!({"value": " HTTPS://WWW.Example.COM/path "})
        )["result"]["value"],
        "www.example.com"
    );
    assert_eq!(
        call(
            "policy.normalize_domain",
            json!({"value": "https://[2001:db8::1]/path"})
        )["result"]["value"],
        "2001:db8::1"
    );
    assert_eq!(
        call(
            "policy.normalize_domain",
            json!({"value": "ex%61mple.com:65536"})
        )["result"]["value"],
        "example.com"
    );
    assert!(call(
        "policy.normalize_domain",
        json!({"value": "example.com:bogus"})
    )["result"]["value"]
        .is_null());
    assert_eq!(
        call(
            "policy.parse_url_pattern",
            json!({"value": " HTTPS://*.Example.COM:0443/r/Focus/ "})
        )["result"]["value"]["canonical"],
        "https://*.example.com:443/r/Focus"
    );
    assert_eq!(
        call("policy.network_domains", json!({"value": "*.example.com"}))["result"]["value"],
        json!(["www.example.com"])
    );
    assert_eq!(
        call(
            "policy.network_domains",
            json!({"value": "*.example.com/videos"})
        )["result"]["value"],
        json!([])
    );
}

#[test]
fn unicode_domains_use_composed_storage_and_grapheme_validation() {
    let decomposed = "e\u{301}.example";
    let devanagari = "क\u{93f}.example";
    assert_eq!(
        call("policy.normalize_domain", json!({"value": decomposed}))["result"]["value"],
        "é.example"
    );
    assert_eq!(
        call("policy.normalize_domain", json!({"value": devanagari}))["result"]["value"],
        devanagari
    );
    assert_eq!(
        call("policy.normalize_domain", json!({"value": "क्ष.example"}))["result"]["value"],
        "क्ष.example"
    );
    assert_eq!(
        call(
            "policy.parse_url_pattern",
            json!({"value": format!("{decomposed}/read")})
        )["result"]["value"]["canonical"],
        "é.example/read"
    );
    let rules = json!({
        "blocked_domains": ["é.example", devanagari],
        "blocked_applications": [], "blocked_adult_domains": [],
        "adult_rules_version": null
    });
    assert_eq!(
        call(
            "policy.validate_rules",
            json!({"rules": rules, "allow_legacy_application_identity": false})
        )["ok"],
        true
    );
}

#[test]
fn browser_match_uses_idna_path_boundaries_and_literal_globs() {
    let url = |host: &str, path: &str| {
        json!({
            "scheme": "https", "host": host, "port": null,
            "path": path, "query": null, "fragment": null
        })
    };
    assert_eq!(
        call(
            "policy.matches_url",
            json!({
                "pattern": "bücher.example/read", "url": url("xn--bcher-kva.example", "/read/chapter")
            })
        )["result"]["value"],
        true
    );
    assert_eq!(
        call(
            "policy.matches_url",
            json!({
                "pattern": "reddit.com/r/focus", "url": url("reddit.com", "/r/%66ocus/comments")
            })
        )["result"]["value"],
        true
    );
    assert_eq!(
        call(
            "policy.matches_url",
            json!({
                "pattern": "reddit.com/r/focus", "url": url("reddit.com", "/r/focused")
            })
        )["result"]["value"],
        false
    );
    assert_eq!(
        call(
            "policy.matches_url",
            json!({
                "pattern": "example.com/v1.0+copy(1)/*",
                "url": url("example.com", "/v1.0+copy(1)/file")
            })
        )["result"]["value"],
        true
    );
}

#[test]
fn normalized_rules_keep_native_json_field_and_legacy_defaults() {
    let rules = json!({
        "blocked_domains": ["Example.COM", "example.com"],
        "blocked_applications": [],
        "blocked_adult_domains": [],
        "adult_rules_version": null,
        "blocked_url_patterns": ["*.Example.COM", "*.example.com"]
    });
    let result = call("policy.normalize_rules", rules);
    assert_eq!(result["ok"], true);
    assert_eq!(
        result["result"]["rules"]["blocked_domains"],
        json!(["example.com", "www.example.com"])
    );
    assert_eq!(
        result["result"]["rules"]["blockedURLPatterns"],
        json!(["*.example.com"])
    );
    assert!(result["result"]["rules"]
        .get("blocked_url_patterns")
        .is_none());
}

#[test]
fn active_rule_update_cannot_add_allowed_domain() {
    let previous = json!({
        "blocked_domains": ["example.com"],
        "blocked_applications": [],
        "blocked_adult_domains": [],
        "adult_rules_version": null
    });
    let mut current = previous.clone();
    current["allowed_domains"] = json!(["example.com"]);
    assert_eq!(call("policy.includes_all_rules", json!({
        "current": current, "previous": previous
    }))["result"]["value"], false);
}

#[test]
fn draft_validation_preserves_legacy_identity_and_wait_errors() {
    let mut rules = json!({
        "blocked_domains": ["example.com"],
        "blocked_applications": [{
            "bundle_identifier": "org.example.legacy",
            "display_name": "Legacy",
            "designated_requirement": null
        }],
        "blocked_adult_domains": [],
        "adult_rules_version": null
    });
    let draft = |rules: Value, delay: &str| {
        json!({
            "name": " Study ", "rules": rules, "protection_mode": "softLock",
            "break_delay": delay, "full_unlock_delay": "60", "break_duration": "60",
            "elapsed_duration": null
        })
    };
    let args = |draft: Value, legacy: bool| {
        json!({
            "draft": draft, "mutation": true,
            "allow_legacy_application_identity": legacy
        })
    };
    assert_eq!(
        call(
            "policy.validate_draft",
            args(draft(rules.clone(), "60"), false)
        )["error"]["code"],
        "missing_application_identity"
    );
    assert_eq!(
        call(
            "policy.validate_draft",
            args(draft(rules.clone(), "NaN"), true)
        )["error"]["code"],
        "invalid_break_delay"
    );
    rules["blocked_applications"] = json!([]);
    assert_eq!(
        call("policy.validate_draft", args(draft(rules, "60"), false))["result"]["name"],
        "Study"
    );
}
