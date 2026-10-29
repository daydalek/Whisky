//! Graph topology stays intact while runs of choices collapse into compact branch nodes.
use crate::walkthrough::{field_text, items, translated};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};

pub(crate) const NODE_W: f32 = 224.;
pub(crate) const NODE_H: f32 = 82.;

#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum Kind {
    Entry,
    Save,
    Ending,
    Branch,
    Choice,
    Note,
}

#[derive(Clone)]
pub(crate) struct Node {
    pub(crate) key: String,
    pub(crate) label: String,
    pub(crate) detail: String,
    pub(crate) kind: Kind,
    pub(crate) expandable: bool,
    pub(crate) x: f32,
    pub(crate) y: f32,
    lane: usize,
}

#[derive(Default, Clone)]
pub(crate) struct Tree {
    pub(crate) nodes: Vec<Node>,
    pub(crate) edges: Vec<(usize, usize)>,
    pub(crate) extent: [f32; 2],
}

impl Tree {
    fn node(
        &mut self,
        key: String,
        label: String,
        detail: String,
        kind: Kind,
        lane: usize,
        expandable: bool,
    ) -> usize {
        if let Some(index) = self.nodes.iter().position(|n| n.key == key) {
            return index;
        }
        self.nodes.push(Node {
            key,
            label,
            detail,
            kind,
            lane,
            expandable,
            x: 0.,
            y: 0.,
        });
        self.nodes.len() - 1
    }
    fn edge(&mut self, from: usize, to: usize) {
        if from != to && !self.edges.contains(&(from, to)) {
            self.edges.push((from, to));
        }
    }
    fn anchor(&mut self, chart: &Value, node: &Value, original: bool, lane: usize) -> usize {
        let key = field_text(node, "key");
        let (collection, field, kind, detail) = match field_text(node, "node_type") {
            "save" => ("saves", "label", Kind::Save, "存档分支"),
            "ending" => ("endings", "name", Kind::Ending, "结局"),
            _ => ("entries", "label", Kind::Entry, "游玩入口"),
        };
        let value = items(chart, collection)
            .iter()
            .find(|n| field_text(n, "key") == key);
        let label = value
            .map(|n| translated(n, field, original))
            .unwrap_or_else(|| key.into());
        let unlock = value
            .map(|n| field_text(n, "unlocked_by_ending_key"))
            .unwrap_or_default();
        let detail = if unlock.is_empty() {
            detail.into()
        } else {
            let ending = items(chart, "endings")
                .iter()
                .find(|e| field_text(e, "key") == unlock)
                .map(|e| translated(e, "name", original))
                .unwrap_or_else(|| unlock.into());
            format!("解锁：{ending}")
        };
        self.node(
            format!("{collection}:{key}"),
            label,
            detail,
            kind,
            lane,
            false,
        )
    }

    pub(crate) fn build(
        chart: &Value,
        scope: &str,
        original: bool,
        expanded: &BTreeSet<String>,
    ) -> Self {
        let mut tree = Self::default();
        for (lane, segment) in items(chart, "segments").iter().enumerate() {
            let Some(from) = segment.get("from_node") else {
                continue;
            };
            let mut previous = tree.anchor(chart, from, original, lane);
            let section = items(chart, "sections")
                .iter()
                .find(|s| field_text(s, "key") == field_text(segment, "section_key"));
            let title = section
                .map(|s| translated(s, "title", original))
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| "共通路线".into());
            let steps = items(segment, "steps");
            let mut first = 0;
            let mut chunk = 0;
            while first < steps.len() {
                let end = (first..steps.len())
                    .find(|&i| field_text(&steps[i], "step_type") == "save")
                    .unwrap_or(steps.len());
                if end > first {
                    let key = format!("{scope}:{}:{chunk}", field_text(segment, "key"));
                    let open = expanded.contains(&key);
                    let condition = if first == 0 {
                        translated(segment, "condition", original)
                    } else {
                        String::new()
                    };
                    let detail = if condition.is_empty() {
                        format!(
                            "{} 个步骤 · 点击{}",
                            end - first,
                            if open { "折叠" } else { "展开" }
                        )
                    } else {
                        format!("{} · {} 步", condition, end - first)
                    };
                    let branch =
                        tree.node(key.clone(), title.clone(), detail, Kind::Branch, lane, true);
                    tree.edge(previous, branch);
                    previous = branch;
                    if open {
                        for (offset, step) in steps[first..end].iter().enumerate() {
                            let kind = if field_text(step, "step_type") == "choice" {
                                Kind::Choice
                            } else {
                                Kind::Note
                            };
                            let label = translated(step, "text", original);
                            let alternatives = items(step, "alternatives")
                                .iter()
                                .map(|v| {
                                    v.as_str()
                                        .map(str::to_owned)
                                        .unwrap_or_else(|| translated(v, "text", original))
                                })
                                .collect::<Vec<_>>()
                                .join(" / ");
                            let detail = if !alternatives.is_empty() {
                                format!("亦可：{alternatives}")
                            } else if step.get("achievement").and_then(Value::as_bool) == Some(true)
                            {
                                "★ 成就选项".into()
                            } else {
                                format!("步骤 {}", first + offset + 1)
                            };
                            let step_node = tree.node(
                                format!("{key}:step:{offset}"),
                                label,
                                detail,
                                kind,
                                lane,
                                false,
                            );
                            tree.edge(previous, step_node);
                            previous = step_node;
                        }
                    }
                    chunk += 1;
                }
                if end < steps.len() {
                    let save = serde_json::json!({"node_type":"save","key":field_text(&steps[end],"save_key")});
                    let next = tree.anchor(chart, &save, original, lane);
                    tree.edge(previous, next);
                    previous = next;
                    first = end + 1;
                } else {
                    first = end;
                }
            }
            if let Some(to) = segment.get("to_node") {
                let target = tree.anchor(chart, to, original, lane);
                tree.edge(previous, target);
            }
        }
        tree.layout();
        tree
    }

    fn layout(&mut self) {
        let count = self.nodes.len();
        let mut incoming = vec![0; count];
        for &(_, b) in &self.edges {
            incoming[b] += 1;
        }
        let mut queue = std::collections::VecDeque::new();
        for (i, &n) in incoming.iter().enumerate() {
            if n == 0 {
                queue.push_back(i);
            }
        }
        let mut depth = vec![0usize; count];
        while let Some(a) = queue.pop_front() {
            for &(from, to) in &self.edges {
                if from == a {
                    depth[to] = depth[to].max(depth[a] + 1);
                    incoming[to] -= 1;
                    if incoming[to] == 0 {
                        queue.push_back(to);
                    }
                }
            }
        }
        // Cyclic imported graphs retain their edges and get bounded, distinct positions.
        let mut occupied = BTreeMap::<usize, BTreeSet<usize>>::new();
        for (i, node) in self.nodes.iter_mut().enumerate() {
            let rows = occupied.entry(depth[i]).or_default();
            let mut lane = node.lane;
            while rows.contains(&lane) {
                lane += 1;
            }
            rows.insert(lane);
            node.x = depth[i] as f32 * (NODE_W + 72.);
            node.y = lane as f32 * (NODE_H + 42.);
            self.extent[0] = self.extent[0].max(node.x + NODE_W);
            self.extent[1] = self.extent[1].max(node.y + NODE_H);
        }
    }
}

#[derive(Clone)]
pub(crate) struct Camera {
    pub(crate) needs_fit: bool,
    pub(crate) zoom: f32,
    pub(crate) pan: [f32; 2],
}
impl Default for Camera {
    fn default() -> Self {
        Self {
            needs_fit: true,
            zoom: 0.75,
            pan: [28., 80.],
        }
    }
}
impl Camera {
    pub(crate) fn pan_by(&mut self, delta: [f32; 2]) {
        self.needs_fit = false;
        self.pan[0] += delta[0];
        self.pan[1] += delta[1];
    }
    /// Start at the beginning of the graph at a readable, unscaled size.
    pub(crate) fn readable(&mut self) {
        self.needs_fit = false;
        self.zoom = 1.;
        self.pan = [32., 32.];
    }
    pub(crate) fn zoom_at(&mut self, factor: f32, anchor: [f32; 2]) {
        self.needs_fit = false;
        let next = (self.zoom * factor).clamp(0.15, 2.);
        for i in 0..2 {
            self.pan[i] = anchor[i] - (anchor[i] - self.pan[i]) * next / self.zoom;
        }
        self.zoom = next;
    }
    pub(crate) fn fit(&mut self, extent: [f32; 2], viewport: [f32; 2]) {
        self.needs_fit = false;
        self.zoom = ((viewport[0] - 64.) / extent[0].max(1.))
            .min((viewport[1] - 64.) / extent[1].max(1.))
            .clamp(0.15, 1.);
        self.pan = [
            (viewport[0] - extent[0] * self.zoom) / 2.,
            (viewport[1] - extent[1] * self.zoom) / 2.,
        ];
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn shared_save_connects_branches_and_collapsing_retains_endings() {
        let chart: Value = serde_json::from_str::<Value>(include_str!(
            "../tests/fixtures/nextmoe-walkthrough.json"
        ))
        .unwrap()["chart"]
            .clone();
        let folded = Tree::build(&chart, "test", false, &BTreeSet::new());
        let save = folded
            .nodes
            .iter()
            .position(|n| n.kind == Kind::Save)
            .unwrap();
        assert_eq!(folded.edges.iter().filter(|(a, _)| *a == save).count(), 2);
        assert_eq!(
            folded
                .nodes
                .iter()
                .filter(|n| n.kind == Kind::Ending)
                .count(),
            2
        );
        let expanded = folded
            .nodes
            .iter()
            .filter(|n| n.expandable)
            .map(|n| n.key.clone())
            .collect();
        let open = Tree::build(&chart, "test", false, &expanded);
        assert!(open.nodes.len() > folded.nodes.len());
        assert_eq!(
            open.nodes.iter().filter(|n| n.kind == Kind::Save).count(),
            1
        );
        for n in &open.nodes {
            assert!(n.x.is_finite() && n.y.is_finite());
        }
    }
    #[test]
    fn zoom_retains_world_position_under_pointer_and_obeys_limits() {
        let mut camera = Camera::default();
        let anchor = [320., 240.];
        let world = [
            (anchor[0] - camera.pan[0]) / camera.zoom,
            (anchor[1] - camera.pan[1]) / camera.zoom,
        ];
        camera.zoom_at(1.5, anchor);
        for i in 0..2 {
            assert!((camera.pan[i] + world[i] * camera.zoom - anchor[i]).abs() < 0.001);
        }
        camera.zoom_at(100., anchor);
        assert_eq!(camera.zoom, 2.);
        camera.fit([1000., 500.], [800., 600.]);
        assert!(camera.pan[0] >= 0. && camera.pan[1] >= 0.);
    }
    #[test]
    fn scrolling_and_readable_view_reset_camera() {
        let mut camera = Camera::default();
        camera.pan_by([12., -24.]);
        assert!(!camera.needs_fit);
        assert_eq!(camera.pan, [40., 56.]);
        camera.zoom_at(0.5, [100., 100.]);
        camera.readable();
        assert_eq!(camera.zoom, 1.);
        assert_eq!(camera.pan, [32., 32.]);
    }
}
