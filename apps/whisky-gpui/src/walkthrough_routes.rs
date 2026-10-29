//! Reading-order model for NextMoe charts: each segment becomes a route that
//! links back to the route producing its starting save, so the reader can show
//! a nested route index and a linear, step-by-step page per route.
use crate::walkthrough::{field_text, items, translated};
use crate::walkthrough_tree::Kind;
use serde_json::Value;

#[derive(Clone)]
pub(crate) struct Anchor {
    pub(crate) kind: Kind,
    pub(crate) label: String,
    /// Extra context such as the ending that unlocks an entry.
    pub(crate) detail: String,
}

#[derive(Clone)]
pub(crate) enum Step {
    Choice {
        number: usize,
        text: String,
        alternatives: Vec<String>,
        achievement: bool,
    },
    Note(String),
    Save {
        label: String,
        /// Route indices that continue from this save.
        branches: Vec<usize>,
    },
}

#[derive(Clone)]
pub(crate) struct Route {
    pub(crate) key: String,
    pub(crate) title: String,
    /// Stable per-section index used for tinting.
    pub(crate) section: usize,
    pub(crate) condition: String,
    pub(crate) from: Anchor,
    pub(crate) to: Option<Anchor>,
    pub(crate) steps: Vec<Step>,
    pub(crate) parent: Option<usize>,
    pub(crate) depth: usize,
    pub(crate) choices: usize,
}

#[derive(Default, Clone)]
pub(crate) struct Routes {
    pub(crate) routes: Vec<Route>,
    /// Depth-first reading order (parents before the branches they lead to).
    pub(crate) order: Vec<usize>,
    pub(crate) endings: usize,
}

fn anchor(chart: &Value, node: &Value, original: bool) -> Anchor {
    let key = field_text(node, "key");
    let (collection, field, kind) = match field_text(node, "node_type") {
        "save" => ("saves", "label", Kind::Save),
        "ending" => ("endings", "name", Kind::Ending),
        _ => ("entries", "label", Kind::Entry),
    };
    let value = items(chart, collection)
        .iter()
        .find(|n| field_text(n, "key") == key);
    let label = value
        .map(|n| translated(n, field, original))
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| key.into());
    let unlock = value
        .map(|n| field_text(n, "unlocked_by_ending_key"))
        .unwrap_or_default();
    let detail = if unlock.is_empty() {
        String::new()
    } else {
        let ending = items(chart, "endings")
            .iter()
            .find(|e| field_text(e, "key") == unlock)
            .map(|e| translated(e, "name", original))
            .unwrap_or_else(|| unlock.into());
        format!("需先达成「{ending}」")
    };
    Anchor {
        kind,
        label,
        detail,
    }
}

impl Routes {
    pub(crate) fn build(chart: &Value, original: bool) -> Self {
        let segments = items(chart, "segments");
        let sections = items(chart, "sections");
        let mut routes: Vec<Route> = Vec::with_capacity(segments.len());
        for (index, segment) in segments.iter().enumerate() {
            let section_key = field_text(segment, "section_key");
            let section = sections
                .iter()
                .position(|s| field_text(s, "key") == section_key)
                .unwrap_or(sections.len());
            let title = sections
                .get(section)
                .map(|s| translated(s, "title", original))
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| "共通路线".into());
            let mut number = 0;
            let steps = items(segment, "steps")
                .iter()
                .filter_map(|step| match field_text(step, "step_type") {
                    "save" => {
                        let save = serde_json::json!({"node_type": "save", "key": field_text(step, "save_key")});
                        Some(Step::Save {
                            label: anchor(chart, &save, original).label,
                            branches: Vec::new(),
                        })
                    }
                    "choice" => {
                        number += 1;
                        Some(Step::Choice {
                            number,
                            text: translated(step, "text", original),
                            alternatives: items(step, "alternatives")
                                .iter()
                                .map(|v| {
                                    v.as_str()
                                        .map(str::to_owned)
                                        .unwrap_or_else(|| translated(v, "text", original))
                                })
                                .filter(|s| !s.is_empty())
                                .collect(),
                            achievement: step.get("achievement").and_then(Value::as_bool)
                                == Some(true),
                        })
                    }
                    _ => {
                        let text = translated(step, "text", original);
                        (!text.is_empty()).then_some(Step::Note(text))
                    }
                })
                .collect();
            routes.push(Route {
                key: {
                    let key = field_text(segment, "key");
                    if key.is_empty() { format!("#{index}") } else { key.into() }
                },
                title,
                section,
                condition: translated(segment, "condition", original),
                from: segment
                    .get("from_node")
                    .map(|n| anchor(chart, n, original))
                    .unwrap_or(Anchor {
                        kind: Kind::Entry,
                        label: "开始游戏".into(),
                        detail: String::new(),
                    }),
                to: segment.get("to_node").filter(|n| n.is_object()).map(|n| anchor(chart, n, original)),
                steps,
                parent: None,
                depth: 0,
                choices: number,
            });
        }

        // Link a route to whichever route reaches its starting save/ending first.
        let mut children: Vec<Vec<usize>> = vec![Vec::new(); routes.len()];
        for (index, segment) in segments.iter().enumerate() {
            let Some(from) = segment.get("from_node") else { continue };
            let key = field_text(from, "key");
            let parent = match field_text(from, "node_type") {
                "save" => segments.iter().enumerate().find_map(|(p, s)| {
                    items(s, "steps")
                        .iter()
                        .position(|st| {
                            field_text(st, "step_type") == "save"
                                && field_text(st, "save_key") == key
                        })
                        .filter(|_| p != index)
                        .map(|_| p)
                }),
                "ending" => segments.iter().position(|s| {
                    s.get("to_node").is_some_and(|t| {
                        field_text(t, "node_type") == "ending" && field_text(t, "key") == key
                    })
                }),
                _ => None,
            }
            .filter(|&p| p != index);
            if let Some(parent) = parent {
                routes[index].parent = Some(parent);
                children[parent].push(index);
            }
            if field_text(from, "node_type") == "save" {
                for (p, s) in segments.iter().enumerate() {
                    let saves = items(s, "steps")
                        .iter()
                        .filter(|st| field_text(st, "step_type") == "save");
                    let mut slot = routes[p]
                        .steps
                        .iter_mut()
                        .filter(|st| matches!(st, Step::Save { .. }));
                    for st in saves {
                        let step = slot.next();
                        if p != index && field_text(st, "save_key") == key {
                            if let Some(Step::Save { branches, .. }) = step {
                                branches.push(index);
                            }
                        }
                    }
                }
            }
        }

        // Depth-first reading order; cycles fall back to provider order.
        let mut order = Vec::with_capacity(routes.len());
        let mut seen = vec![false; routes.len()];
        fn visit(
            i: usize,
            depth: usize,
            routes: &mut [Route],
            children: &[Vec<usize>],
            seen: &mut [bool],
            order: &mut Vec<usize>,
        ) {
            if seen[i] {
                return;
            }
            seen[i] = true;
            routes[i].depth = depth;
            order.push(i);
            for &c in &children[i] {
                visit(c, depth + 1, routes, children, seen, order);
            }
        }
        for i in 0..routes.len() {
            if routes[i].parent.is_none() {
                visit(i, 0, &mut routes, &children, &mut seen, &mut order);
            }
        }
        for i in 0..routes.len() {
            if !seen[i] {
                routes[i].parent = None;
                visit(i, 0, &mut routes, &children, &mut seen, &mut order);
            }
        }
        Self {
            endings: items(chart, "endings").len(),
            routes,
            order,
        }
    }

    pub(crate) fn index_of(&self, key: Option<&str>) -> Option<usize> {
        key.and_then(|k| self.routes.iter().position(|r| r.key == k))
    }

    /// Ancestors from the root route down to (excluding) `index`.
    pub(crate) fn lineage(&self, index: usize) -> Vec<usize> {
        let mut chain = Vec::new();
        let mut cursor = self.routes[index].parent;
        while let Some(p) = cursor {
            if chain.contains(&p) || p == index {
                break;
            }
            chain.push(p);
            cursor = self.routes[p].parent;
        }
        chain.reverse();
        chain
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn branches_nest_under_the_route_that_creates_their_save() {
        let chart: Value = serde_json::from_str::<Value>(include_str!(
            "../tests/fixtures/nextmoe-walkthrough.json"
        ))
        .unwrap()["chart"]
            .clone();
        let routes = Routes::build(&chart, false);
        assert_eq!(routes.routes.len(), 2);
        assert_eq!(routes.order, vec![0, 1]);
        let branch = &routes.routes[1];
        assert_eq!(branch.parent, Some(0));
        assert_eq!(branch.depth, 1);
        assert_eq!(branch.choices, 2);
        assert!(matches!(branch.to.as_ref().map(|a| a.kind), Some(Kind::Ending)));
        let save = routes.routes[0]
            .steps
            .iter()
            .find_map(|s| match s {
                Step::Save { branches, .. } => Some(branches.clone()),
                _ => None,
            })
            .unwrap();
        assert_eq!(save, vec![1]);
        assert_eq!(routes.lineage(1), vec![0]);
        assert_eq!(routes.index_of(Some("g2")), Some(1));
    }

    #[test]
    fn cyclic_routes_are_still_listed_once() {
        let chart = serde_json::json!({
            "saves": [{"key": "a"}, {"key": "b"}],
            "segments": [
                {"key": "x", "from_node": {"node_type": "save", "key": "b"},
                 "steps": [{"step_type": "save", "save_key": "a"}]},
                {"key": "y", "from_node": {"node_type": "save", "key": "a"},
                 "steps": [{"step_type": "save", "save_key": "b"}]}
            ]
        });
        let routes = Routes::build(&chart, false);
        assert_eq!(routes.order.len(), 2);
        for i in 0..2 {
            assert!(routes.lineage(i).len() <= 1);
        }
    }
}
