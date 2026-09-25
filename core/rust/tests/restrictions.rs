use hard_pause_core::policy::{Application, Rules};
use hard_pause_core::restrictions::{
    compose, union, Activation, Block, Request, RestrictionSet, UnionRequest,
};

fn rules(domain: &str, application_name: &str) -> Rules {
    Rules {
        allowed_domains: vec![],
        blocked_domains: vec![domain.into()],
        blocked_applications: vec![Application {
            bundle_identifier: "com.example.app".into(),
            display_name: application_name.into(),
            designated_requirement: Some("signed".into()),
        }],
        blocked_adult_domains: vec!["adult.example".into()],
        adult_rules_version: None,
        blocked_url_patterns: vec!["*.example.com".into()],
        blocks_adult_websites: false,
    }
}

fn blocks() -> Vec<Block> {
    vec![
        Block {
            id: "A".into(),
            activation: Some(Activation {
                accumulated_elapsed: 10.0,
                break_ends_at_elapsed: None,
                rules: rules("one.example", "First"),
            }),
        },
        Block {
            id: "B".into(),
            activation: Some(Activation {
                accumulated_elapsed: 10.0,
                break_ends_at_elapsed: Some(60.0),
                rules: rules("two.example", "Second"),
            }),
        },
        Block {
            id: "C".into(),
            activation: None,
        },
    ]
}

#[test]
fn normal_projection_excludes_breaks_and_conservative_projection_keeps_them() {
    let normal = compose(Request {
        blocks: blocks(),
        including_breaks: false,
    });
    assert_eq!(normal.contributing_block_ids, ["A"]);
    assert_eq!(normal.blocked_domains, ["adult.example", "one.example"]);
    assert_eq!(normal.blocked_applications[0].display_name, "First");

    let conservative = compose(Request {
        blocks: blocks(),
        including_breaks: true,
    });
    assert_eq!(conservative.contributing_block_ids, ["A", "B"]);
    assert_eq!(
        conservative.blocked_domains,
        ["adult.example", "one.example", "two.example"]
    );
    assert_eq!(conservative.blocked_applications[0].display_name, "Second");
    assert_eq!(conservative.blocked_url_patterns, ["*.example.com"]);
}

#[test]
fn staging_union_retains_both_rule_sets_and_uses_candidate_application() {
    let current = RestrictionSet {
        blocked_domains: vec!["old.example".into()],
        blocked_applications: rules("old.example", "Old").blocked_applications,
        contributing_ids: vec!["A".into()],
        blocked_url_patterns: vec!["old.example/path".into()],
    };
    let candidate = RestrictionSet {
        blocked_domains: vec!["new.example".into()],
        blocked_applications: rules("new.example", "New").blocked_applications,
        contributing_ids: vec!["B".into()],
        blocked_url_patterns: vec!["new.example/path".into()],
    };
    let staged = union(UnionRequest { current, candidate });
    assert_eq!(staged.blocked_domains, ["new.example", "old.example"]);
    assert_eq!(
        staged.blocked_url_patterns,
        ["new.example/path", "old.example/path"]
    );
    assert_eq!(staged.contributing_block_ids, ["A", "B"]);
    assert_eq!(staged.blocked_applications[0].display_name, "New");
}

#[test]
fn allowed_domain_applies_only_to_its_own_block() {
    let mut first = rules("shared.example", "First");
    first.allowed_domains = vec!["shared.example".into()];
    let block = |id: &str, rules: Rules| Block {
        id: id.into(),
        activation: Some(Activation {
            accumulated_elapsed: 10.0,
            break_ends_at_elapsed: None,
            rules,
        }),
    };
    let first_only = compose(Request {
        blocks: vec![block("A", first.clone())],
        including_breaks: false,
    });
    assert!(!first_only.blocked_domains.contains(&"shared.example".into()));

    let both = compose(Request {
        blocks: vec![block("A", first), block("B", rules("shared.example", "Second"))],
        including_breaks: false,
    });
    assert!(both.blocked_domains.contains(&"shared.example".into()));
}
