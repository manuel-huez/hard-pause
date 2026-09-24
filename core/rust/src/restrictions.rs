use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

use crate::policy::{Application, Rules};

#[derive(Deserialize)]
pub struct Block {
    pub id: String,
    pub activation: Option<Activation>,
}

#[derive(Deserialize)]
pub struct Activation {
    pub accumulated_elapsed: f64,
    pub break_ends_at_elapsed: Option<f64>,
    pub rules: Rules,
}

#[derive(Deserialize)]
pub struct Request {
    pub blocks: Vec<Block>,
    pub including_breaks: bool,
}

#[derive(Serialize)]
pub struct EffectiveRestrictions {
    pub blocked_domains: Vec<String>,
    pub blocked_applications: Vec<Application>,
    #[serde(rename = "contributingBlockIDs")]
    pub contributing_block_ids: Vec<String>,
    #[serde(rename = "blockedURLPatterns")]
    pub blocked_url_patterns: Vec<String>,
}

#[derive(Deserialize)]
pub struct RestrictionSet {
    pub blocked_domains: Vec<String>,
    pub blocked_applications: Vec<Application>,
    pub contributing_ids: Vec<String>,
    pub blocked_url_patterns: Vec<String>,
}

#[derive(Deserialize)]
pub struct UnionRequest {
    pub current: RestrictionSet,
    pub candidate: RestrictionSet,
}

pub fn union(request: UnionRequest) -> EffectiveRestrictions {
    let mut domains = BTreeSet::new();
    let mut applications = BTreeMap::new();
    let mut block_ids = BTreeSet::new();
    let mut url_patterns = BTreeSet::new();
    for set in [request.current, request.candidate] {
        domains.extend(set.blocked_domains);
        block_ids.extend(set.contributing_ids);
        url_patterns.extend(set.blocked_url_patterns);
        for application in set.blocked_applications {
            applications.insert(application.id(), application);
        }
    }
    EffectiveRestrictions {
        blocked_domains: domains.into_iter().collect(),
        blocked_applications: applications.into_values().collect(),
        contributing_block_ids: block_ids.into_iter().collect(),
        blocked_url_patterns: url_patterns.into_iter().collect(),
    }
}

pub fn compose(request: Request) -> EffectiveRestrictions {
    let mut domains = BTreeSet::new();
    let mut applications = BTreeMap::new();
    let mut block_ids = BTreeSet::new();
    let mut url_patterns = BTreeSet::new();
    for block in request.blocks {
        let Some(activation) = block.activation else {
            continue;
        };
        if !request.including_breaks
            && activation
                .break_ends_at_elapsed
                .is_some_and(|end| activation.accumulated_elapsed < end)
        {
            continue;
        }
        block_ids.insert(block.id);
        domains.extend(activation.rules.blocked_domains);
        domains.extend(activation.rules.blocked_adult_domains);
        url_patterns.extend(activation.rules.blocked_url_patterns);
        for application in activation.rules.blocked_applications {
            applications.insert(application.id(), application);
        }
    }
    EffectiveRestrictions {
        blocked_domains: domains.into_iter().collect(),
        blocked_applications: applications.into_values().collect(),
        contributing_block_ids: block_ids.into_iter().collect(),
        blocked_url_patterns: url_patterns.into_iter().collect(),
    }
}
