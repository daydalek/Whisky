//! Target geometry for the existing three library presentations.
//! Animation state belongs to GPUI Base, keyed by game identity in `main.rs`.
//!
//! The mixed shelf packs rows with the same sliding-window knapsack DP as
//! WhiskyCore's `LibraryCoverGrid.swift`; keep the two in step when either
//! changes so macOS and Linux present identical rows.

use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CardRect {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

#[derive(Debug)]
pub struct LibraryLayout {
    pub cards: Vec<(usize, CardRect)>,
    pub height: f32,
    /// The cover width the layout actually drew, which is the chosen width when
    /// there is one and the filled column width otherwise. The size control
    /// parks its thumb here so an automatic layout still reads truthfully.
    pub cover_width: f32,
}

/// Which side of the central rail a staggered card sits on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StaggeredSide {
    Left,
    Right,
}

/// One card target in the staggered two-column timeline.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct StaggeredCard {
    /// Index into the library's entry list.
    pub index: usize,
    /// Card rect in content space.
    pub rect: CardRect,
    /// The column the card occupies; drives the connector direction.
    pub side: StaggeredSide,
    /// Content-space rail node centre — the card's vertical middle.
    pub node_y: f32,
}

/// Geometry for the staggered two-column timeline (mode index 5).
#[derive(Debug)]
pub struct StaggeredLayout {
    pub cards: Vec<StaggeredCard>,
    /// Date/group chips centred on the rail: `(center y, text)`.
    pub markers: Vec<(f32, String)>,
    /// Content height covering the last card plus the trailing margin.
    pub height: f32,
    /// Horizontal centre of the rail in content space.
    pub rail_x: f32,
    /// Rail segment bounds: just past the outermost node/marker.
    pub rail_top: f32,
    pub rail_bottom: f32,
    pub card_width: f32,
    pub card_height: f32,
    /// The cover column width the card body should draw.
    pub cover_width: f32,
    /// Below this column width the card drops its description row.
    pub compact: bool,
}

/// Outer margin of the staggered page, matching the other presentations.
pub const STAGGERED_MARGIN: f32 = 20.;
/// Content-space gap between a card edge and the rail the connector spans.
pub const STAGGERED_RAIL_GAP: f32 = 40.;
/// Vertical gap between two cards in the same column.
const STAGGERED_GAP: f32 = 26.;
const STAGGERED_TOP: f32 = 22.;
const STAGGERED_BOTTOM: f32 = 30.;
/// Extra rail space a group boundary opens for its date chip.
const STAGGERED_MARKER_GAP: f32 = 44.;
/// The rail overshoots the first and last node by this much.
const STAGGERED_RAIL_OVERHANG: f32 = 16.;
/// Narrowest column before the card body squeezes instead of giving up.
const STAGGERED_MIN_COLUMN: f32 = 190.;
/// Column width below which the card hides its description row.
const STAGGERED_COMPACT: f32 = 330.;

/// Narrowest and widest cover the size control can ask for.
pub const MIN_COVER_WIDTH: f32 = 110.;
pub const MAX_COVER_WIDTH: f32 = 320.;
/// The width the column count has always been derived from.
pub const DEFAULT_COVER_WIDTH: f32 = 140.;
/// No chosen width: covers divide the row between them.
pub const AUTOMATIC_COVER_WIDTH: f32 = 0.;
/// The margin a shelf row keeps on each side, and the gap between covers.
const SHELF_MARGIN: f32 = 18.;
const SHELF_GAP: f32 = 12.;

/// `None` means the row is filled, `Some` is the desired cover width.
///
/// A chosen width cannot also keep the row flush: with a fixed window width the
/// filled size only depends on how many columns fit, so it changes in steps of
/// tens of points. The value therefore steers the pick — the layout snaps to
/// the nearest of [`cover_levels`], the sizes at which covers divide the row
/// exactly — instead of holding the width and leaving edge slack.
pub fn chosen_cover_width(value: f32) -> Option<f32> {
    if value.is_finite() && value > 0. {
        Some(value.clamp(MIN_COVER_WIDTH, MAX_COVER_WIDTH))
    } else {
        None
    }
}

/// Points of row the shelf can lay covers into for a `width`-point viewport.
pub fn shelf_available(width: f32) -> f32 {
    (width - SHELF_MARGIN * 2.).max(1.)
}

/// Flush cover widths the shelf can draw for `available` points of row,
/// narrowest first — the steps of the size control. Every entry divides the
/// row exactly, so picking one never leaves a gap at the edges.
pub fn cover_levels(available: f32) -> Vec<f32> {
    let available = available.max(1.);
    let span = available + SHELF_GAP;
    let widest = (span / (MAX_COVER_WIDTH + SHELF_GAP)).ceil().max(1.) as usize;
    let narrowest = (span / (MIN_COVER_WIDTH + SHELF_GAP))
        .floor()
        .max(widest as f32) as usize;
    (widest..=narrowest)
        .rev()
        .map(|columns| span / columns as f32 - SHELF_GAP)
        .collect()
}

/// Column count whose flush cover width is nearest `desired`, restricted to
/// counts that keep covers inside `[MIN_COVER_WIDTH, MAX_COVER_WIDTH]`.
fn cover_columns(available: f32, desired: f32) -> usize {
    let available = available.max(1.);
    let span = available + SHELF_GAP;
    let widest = (span / (MAX_COVER_WIDTH + SHELF_GAP)).ceil().max(1.) as usize;
    let narrowest = (span / (MIN_COVER_WIDTH + SHELF_GAP))
        .floor()
        .max(widest as f32) as usize;
    (widest..=narrowest)
        .min_by(|&a, &b| {
            let left = (span / a as f32 - SHELF_GAP - desired).abs();
            let right = (span / b as f32 - SHELF_GAP - desired).abs();
            left.total_cmp(&right)
        })
        .unwrap_or(1)
}

impl LibraryLayout {
    /// `cover_width` is the size control's value; [`AUTOMATIC_COVER_WIDTH`]
    /// divides the row at the default column count. Either way the layout
    /// snaps to a flush level, so every full row reaches both edges.
    pub fn shelf_with_width(
        indices: &[usize],
        width: f32,
        cover_width: f32,
        landscape: impl Fn(usize) -> bool,
    ) -> Self {
        let available = shelf_available(width);
        let columns = match chosen_cover_width(cover_width) {
            Some(desired) => cover_columns(available, desired),
            None => ((available + SHELF_GAP) / (DEFAULT_COVER_WIDTH + SHELF_GAP))
                .floor()
                .max(1.) as usize,
        };
        let unit = (available - (columns - 1) as f32 * SHELF_GAP) / columns as f32;
        let card_height = unit * 1.5;
        let spans: Vec<u32> = indices
            .iter()
            .map(|&index| if landscape(index) { columns.min(2) as u32 } else { 1 })
            .collect();
        let rows = pack(&spans, columns);
        let mut cards = Vec::with_capacity(indices.len());
        for (row_index, row) in rows.iter().enumerate() {
            let mut column = 0;
            for &index in row {
                let span = spans[index] as usize;
                cards.push((
                    indices[index],
                    CardRect {
                        x: SHELF_MARGIN + column as f32 * (unit + SHELF_GAP),
                        y: SHELF_MARGIN + row_index as f32 * (card_height + SHELF_GAP),
                        width: unit * span as f32 + SHELF_GAP * (span - 1) as f32,
                        height: card_height,
                    },
                ));
                column += span;
            }
        }
        Self {
            cards,
            height: SHELF_MARGIN * 2. + rows.len() as f32 * (card_height + SHELF_GAP)
                - if rows.is_empty() { 0. } else { SHELF_GAP },
            cover_width: unit,
        }
    }

    pub fn timeline(indices: &[usize], width: f32) -> Self {
        let cover_width = if width > 1000. { 145. } else { 125. };
        Self::grid(indices, width, 1, 24., 12., cover_width * 1.5 + 26.)
    }

    /// The staggered two-column timeline: cards alternate left/right of a
    /// centered rail and the right column hangs half a pitch below the left.
    ///
    /// `label(index, position)` names the date group a card belongs to
    /// (`None` marks no group); a boundary inserts [`STAGGERED_MARKER_GAP`] of
    /// rail space and a centered chip. Every entry keeps the global sort
    /// order — this is a staggered timeline, not shortest-column-first
    /// masonry.
    pub fn staggered(
        indices: &[usize],
        width: f32,
        label: impl Fn(usize, usize) -> Option<String>,
    ) -> StaggeredLayout {
        let card_width = ((width - STAGGERED_MARGIN * 2. - STAGGERED_RAIL_GAP * 2.) / 2.)
            .max(STAGGERED_MIN_COLUMN);
        let cover_width = (card_width * 0.24).clamp(56., 98.);
        let card_height = cover_width * 1.5 + 26.;
        let pitch = card_height + STAGGERED_GAP;
        // Even positions fill the left column, odd the right; the right column
        // starts half a pitch down so neighbours never line up.
        let mut cursor = [STAGGERED_TOP, STAGGERED_TOP + pitch / 2.];
        let mut previous: Option<String> = None;
        let mut markers = Vec::new();
        let mut cards = Vec::with_capacity(indices.len());
        for (position, &index) in indices.iter().enumerate() {
            let group = label(index, position);
            let boundary = if position == 0 {
                group.is_some()
            } else {
                group != previous
            };
            previous = group.clone();
            if boundary {
                cursor[0] += STAGGERED_MARKER_GAP;
                cursor[1] += STAGGERED_MARKER_GAP;
                if let Some(text) = group {
                    markers.push((cursor[0].min(cursor[1]) - STAGGERED_MARKER_GAP / 2., text));
                }
            }
            let column = position % 2;
            let y = cursor[column];
            cursor[column] += pitch;
            cards.push(StaggeredCard {
                index,
                rect: CardRect {
                    x: if column == 0 {
                        STAGGERED_MARGIN
                    } else {
                        width - STAGGERED_MARGIN - card_width
                    },
                    y,
                    width: card_width,
                    height: card_height,
                },
                side: if column == 0 {
                    StaggeredSide::Left
                } else {
                    StaggeredSide::Right
                },
                node_y: y + card_height / 2.,
            });
        }
        let bottom = cards
            .iter()
            .map(|card| card.rect.y + card.rect.height)
            .fold(0_f32, f32::max);
        let (rail_top, rail_bottom) = match cards.first() {
            Some(_) => {
                let first = cards
                    .iter()
                    .map(|card| card.node_y)
                    .fold(f32::MAX, f32::min);
                let last = cards
                    .iter()
                    .map(|card| card.node_y)
                    .fold(f32::MIN, f32::max);
                (
                    first.min(markers.first().map_or(f32::MAX, |marker| marker.0))
                        - STAGGERED_RAIL_OVERHANG,
                    last + STAGGERED_RAIL_OVERHANG,
                )
            }
            None => (0., 0.),
        };
        StaggeredLayout {
            cards,
            markers,
            height: bottom + STAGGERED_BOTTOM,
            rail_x: width / 2.,
            rail_top,
            rail_bottom,
            card_width,
            card_height,
            cover_width,
            compact: card_width < STAGGERED_COMPACT,
        }
    }

    pub fn classic(indices: &[usize], width: f32) -> Self {
        let columns = ((width - 36.) / 310.).floor().max(1.) as usize;
        Self::grid(indices, width, columns, 18., 14., 235.)
    }

    fn grid(
        indices: &[usize],
        width: f32,
        columns: usize,
        padding: f32,
        gap: f32,
        height: f32,
    ) -> Self {
        let card_width =
            ((width - padding * 2. - (columns - 1) as f32 * gap) / columns as f32).max(1.);
        let rows = indices.len().div_ceil(columns);
        Self {
            cards: indices
                .iter()
                .enumerate()
                .map(|(position, &index)| {
                    (
                        index,
                        CardRect {
                            x: padding + (position % columns) as f32 * (card_width + gap),
                            y: padding + (position / columns) as f32 * (height + gap),
                            width: card_width,
                            height,
                        },
                    )
                })
                .collect(),
            height: padding * 2. + rows as f32 * (height + gap) - if rows > 0 { gap } else { 0. },
            cover_width: card_width,
        }
    }
}

#[derive(Clone, Debug)]
struct Choice {
    positions: Vec<usize>,
    cost: i64,
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
struct Capacity {
    used: usize,
    count: usize,
}

/// Compact rows of one- and two-column covers with bounded local reordering,
/// mirroring `LibraryCoverGrid.pack` in WhiskyCore.
fn pack(spans: &[u32], columns: usize) -> Vec<Vec<usize>> {
    let mut consumed = vec![false; spans.len()];
    let mut head = 0;
    let mut rows = Vec::new();
    let mut previous_landscape_offsets = BTreeSet::new();
    let window = 12.min((columns + 2).max(4));
    while head < spans.len() {
        let mut candidates = Vec::with_capacity(window);
        let mut cursor = head;
        while cursor < spans.len() && candidates.len() < window {
            if !consumed[cursor] {
                candidates.push(cursor);
            }
            cursor += 1;
        }
        let selected = select_row(&candidates, spans, columns, &previous_landscape_offsets);
        let row = stagger_row(selected, spans, &previous_landscape_offsets);
        previous_landscape_offsets = landscape_offsets(&row, spans);
        for &index in &row {
            consumed[index] = true;
        }
        while head < spans.len() && consumed[head] {
            head += 1;
        }
        rows.push(row);
    }
    rows
}

/// Each row includes the oldest pending item. A small knapsack DP then
/// fills the row with nearby entries, minimizing inversions and adjacent-row
/// landscape alignment among equally full choices.
fn select_row(
    candidates: &[usize],
    spans: &[u32],
    columns: usize,
    previous_landscape_offsets: &BTreeSet<usize>,
) -> Vec<usize> {
    let first_span = spans[candidates[0]] as usize;
    let first_penalty = i64::from(first_span > 1 && previous_landscape_offsets.contains(&0)) * 2;
    let first = Capacity {
        used: first_span,
        count: 1,
    };
    let mut choices = BTreeMap::from([(
        first,
        Choice {
            positions: vec![0],
            cost: first_penalty,
        },
    )]);
    for position in 1..candidates.len() {
        let mut updated = choices.clone();
        let span = spans[candidates[position]] as usize;
        for (&capacity, choice) in &choices {
            let start_column = capacity.used;
            let used = start_column + span;
            if used > columns {
                continue;
            }
            let key = Capacity {
                used,
                count: capacity.count + 1,
            };
            let overlap_penalty =
                i64::from(span > 1 && previous_landscape_offsets.contains(&start_column)) * 2;
            let mut positions = choice.positions.clone();
            positions.push(position);
            let proposal = Choice {
                positions,
                cost: choice.cost + (position as i64 - capacity.count as i64) + overlap_penalty,
            };
            match updated.get(&key) {
                Some(existing) => {
                    if precedes(&proposal, existing) {
                        updated.insert(key, proposal);
                    }
                }
                None => {
                    updated.insert(key, proposal);
                }
            }
        }
        choices = updated;
    }
    let mut best_capacity = first;
    let mut best = choices
        .get(&first)
        .cloned()
        .unwrap_or(Choice {
            positions: vec![0],
            cost: first_penalty,
        });
    for (&capacity, choice) in &choices {
        if capacity.used > best_capacity.used
            || (capacity.used == best_capacity.used && precedes(choice, &best))
        {
            best_capacity = capacity;
            best = choice.clone();
        }
    }
    best.positions.iter().map(|&position| candidates[position]).collect()
}

/// Shifts a wide card within `row[1..]` when it would land on the exact same
/// column index as a wide card in the preceding row, staggering visual weight.
fn stagger_row(
    row: Vec<usize>,
    spans: &[u32],
    previous_landscape_offsets: &BTreeSet<usize>,
) -> Vec<usize> {
    if row.len() <= 2 || previous_landscape_offsets.is_empty() {
        return row;
    }
    let current_offsets = landscape_offsets(&row, spans);
    if current_offsets.is_disjoint(previous_landscape_offsets) {
        return row;
    }
    let Some(wide_position) = (1..row.len()).find(|&position| spans[row[position]] > 1) else {
        return row;
    };
    let mut best_order = row.clone();
    let mut best_clearance = -1i64;
    for target in 1..row.len() {
        if target == wide_position {
            continue;
        }
        let mut candidate = row.clone();
        let item = candidate.remove(wide_position);
        candidate.insert(target, item);
        let offsets = landscape_offsets(&candidate, spans);
        if !offsets.is_disjoint(previous_landscape_offsets) {
            continue;
        }
        let clearance = offsets
            .iter()
            .map(|&offset| {
                previous_landscape_offsets
                    .iter()
                    .map(|previous| (offset as i64 - *previous as i64).abs())
                    .min()
                    .unwrap_or(0)
            })
            .min()
            .unwrap_or(0);
        if clearance > best_clearance {
            best_clearance = clearance;
            best_order = candidate;
        }
    }
    best_order
}

fn landscape_offsets(row: &[usize], spans: &[u32]) -> BTreeSet<usize> {
    let mut offsets = BTreeSet::new();
    let mut column = 0;
    for &index in row {
        let span = spans[index] as usize;
        if span > 1 {
            offsets.insert(column);
        }
        column += span;
    }
    offsets
}

fn precedes(lhs: &Choice, rhs: &Choice) -> bool {
    lhs.cost < rhs.cost || (lhs.cost == rhs.cost && lhs.positions < rhs.positions)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;

    /// The staggered contract: every card stays inside the row, alternates
    /// left/right in order, aligns its node to its own centre, never overlaps,
    /// and the columns keep their half-pitch offset.
    fn check_staggered(layout: &StaggeredLayout, indices: &[usize], width: f32) {
        assert_eq!(
            layout
                .cards
                .iter()
                .map(|card| card.index)
                .collect::<BTreeSet<_>>(),
            indices.iter().copied().collect()
        );
        assert_eq!(layout.cards.len(), indices.len());
        for (position, card) in layout.cards.iter().enumerate() {
            let rect = card.rect;
            assert!(rect.x.is_finite() && rect.y.is_finite());
            assert!(rect.width > 0. && rect.height > 0.);
            assert!(rect.x + rect.width <= width - STAGGERED_MARGIN + 0.01);
            assert!(rect.y + rect.height <= layout.height + 0.01);
            // Node sits on the rail at the card's vertical centre.
            assert!((card.node_y - (rect.y + rect.height / 2.)).abs() < 0.01);
            // The card never reaches the rail: the connector has its band.
            let edge = match card.side {
                StaggeredSide::Left => rect.x + rect.width,
                StaggeredSide::Right => rect.x,
            };
            assert!((layout.rail_x - edge).abs() > 4.);
            assert_eq!(
                card.side,
                if position % 2 == 0 {
                    StaggeredSide::Left
                } else {
                    StaggeredSide::Right
                }
            );
            for other in &layout.cards[position + 1..] {
                let other = other.rect;
                let overlaps = rect.x < other.x + other.width - 0.01
                    && rect.x + rect.width > other.x + 0.01
                    && rect.y < other.y + other.height - 0.01
                    && rect.y + rect.height > other.y + 0.01;
                assert!(!overlaps, "overlapping targets: {rect:?}, {other:?}");
            }
        }
        // Same-column neighbours are exactly one pitch apart plus a whole
        // number of marker gaps opened by group boundaries in between.
        let pitch = layout.card_height + STAGGERED_GAP;
        for pair in layout.cards.windows(2) {
            let dy = pair[1].rect.y - pair[0].rect.y;
            let gaps = (dy - pitch / 2.) / STAGGERED_MARKER_GAP;
            assert!(dy >= pitch / 2. - 0.01 && (gaps - gaps.round()).abs() < 0.01);
        }
        for pair in layout.cards.windows(3) {
            let dy = pair[2].rect.y - pair[0].rect.y;
            let gaps = (dy - pitch) / STAGGERED_MARKER_GAP;
            assert!(
                dy >= pitch - 0.01 && (gaps - gaps.round()).abs() < 0.01 && gaps <= 2.01,
                "same-column spacing must be pitch plus marker gaps: {dy}"
            );
        }
        for (index, (_, _)) in layout.markers.iter().enumerate() {
            assert!(index < layout.cards.len());
        }
    }

    #[test]
    fn staggered_alternates_columns_and_centres_the_rail() {
        let indices: Vec<usize> = (0..6).collect();
        let layout = LibraryLayout::staggered(&indices, 1080., |_, _| None);
        assert_eq!(layout.rail_x, 540.);
        for (position, card) in layout.cards.iter().enumerate() {
            assert_eq!(
                card.side,
                if position % 2 == 0 {
                    StaggeredSide::Left
                } else {
                    StaggeredSide::Right
                }
            );
        }
        // Right column hangs half a pitch below the left.
        let pitch = layout.card_height + STAGGERED_GAP;
        assert!((layout.cards[1].rect.y - layout.cards[0].rect.y - pitch / 2.).abs() < 0.01);
        // Column inner edges keep the rail gap on both sides.
        let left = layout.cards[0].rect;
        assert!((left.x + left.width - (layout.rail_x - STAGGERED_RAIL_GAP)).abs() < 0.01);
        let right = layout.cards[1].rect;
        assert!((right.x - (layout.rail_x + STAGGERED_RAIL_GAP)).abs() < 0.01);
        // The rail outlives the outermost nodes but not the content.
        assert!(layout.rail_top < layout.cards[0].node_y);
        assert!(layout.rail_bottom > layout.cards[5].node_y);
        assert!(layout.rail_bottom <= layout.height);
    }

    #[test]
    fn staggered_markers_open_rail_space_and_shift_later_cards() {
        let indices: Vec<usize> = (0..6).collect();
        let plain = LibraryLayout::staggered(&indices, 1080., |_, _| None);
        let grouped = LibraryLayout::staggered(&indices, 1080., |i, _| {
            Some(if i < 3 { "今天" } else { "更早" }.to_owned())
        });
        assert_eq!(grouped.markers.len(), 2);
        assert_eq!(grouped.markers[0].1, "今天");
        assert_eq!(grouped.markers[1].1, "更早");
        // Both boundaries (the leading chip and the group change) push the
        // rest of the timeline down one marker gap each.
        let shifted = grouped.cards[3].rect.y - plain.cards[3].rect.y;
        assert!((shifted - 2. * STAGGERED_MARKER_GAP).abs() < 0.01);
        // Same-column spacing across a boundary gains exactly one marker gap.
        let pitch = grouped.card_height + STAGGERED_GAP;
        assert!(
            (grouped.cards[4].rect.y - grouped.cards[2].rect.y - pitch - STAGGERED_MARKER_GAP)
                .abs()
                < 0.01
        );
    }

    #[test]
    fn staggered_handles_empty_and_missing_labels() {
        let empty = LibraryLayout::staggered(&[], 1080., |_, _| None);
        assert!(empty.cards.is_empty());
        assert!(empty.markers.is_empty());
        assert_eq!(empty.rail_top, empty.rail_bottom);
        // A mixed run: an unlabeled card joins the previous group.
        let mixed = LibraryLayout::staggered(&(0..3).collect::<Vec<_>>(), 1080., |i, _| match i {
            0 => Some("今天".to_owned()),
            _ => None,
        });
        assert_eq!(
            mixed.markers.len(),
            1,
            "only the leading label marks a group"
        );
    }

    fn check(layout: &LibraryLayout, indices: &[usize], width: f32) {
        assert_eq!(
            layout
                .cards
                .iter()
                .map(|(id, _)| *id)
                .collect::<BTreeSet<_>>(),
            indices.iter().copied().collect()
        );
        assert_eq!(layout.cards.len(), indices.len());
        for (position, (_, rect)) in layout.cards.iter().enumerate() {
            assert!(rect.x.is_finite() && rect.y.is_finite());
            assert!(rect.width > 0. && rect.height > 0.);
            assert!(rect.x + rect.width <= width + 0.01);
            assert!(rect.y + rect.height <= layout.height + 0.01);
            for (_, other) in &layout.cards[position + 1..] {
                let overlaps = rect.x < other.x + other.width - 0.01
                    && rect.x + rect.width > other.x + 0.01
                    && rect.y < other.y + other.height - 0.01
                    && rect.y + rect.height > other.y + 0.01;
                assert!(!overlaps, "overlapping targets: {rect:?}, {other:?}");
            }
        }
    }

    #[test]
    fn layouts_keep_every_game_in_bounds_across_column_breakpoints() {
        for width in [
            200., 599., 600., 763., 764., 999., 1000., 1001., 1080., 1600.,
        ] {
            for count in [0, 1, 2, 9, 35, 100] {
                let indices: Vec<_> = (0..count).collect();
                check(
                    &shelf(&indices, width, |i| i % 3 == 0),
                    &indices,
                    width,
                );
                check(
                    &shelf(&indices, width, |_| true),
                    &indices,
                    width,
                );
                check(&LibraryLayout::classic(&indices, width), &indices, width);
                check(&LibraryLayout::timeline(&indices, width), &indices, width);
            }
        }
        for width in [560., 640., 800., 1080., 1600.] {
            for count in [0, 1, 2, 3, 9, 35, 100] {
                let indices: Vec<_> = (0..count).collect();
                let layout =
                    LibraryLayout::staggered(&indices, width, |i, _| {
                        (i % 5 == 0).then(|| i.to_string())
                    });
                check_staggered(&layout, &indices, width);
            }
        }
    }

    #[test]
    fn mixed_shelf_preserves_baseline_packing_and_padding() {
        let layout = shelf(&[0, 1, 2, 3, 4], 480., |i| i == 1 || i == 2);
        // Three columns: portrait + landscape, landscape + portrait, portrait.
        assert_eq!(
            layout.cards.iter().map(|(id, _)| *id).collect::<Vec<_>>(),
            [0, 1, 2, 3, 4]
        );
        let a = layout.cards[0].1;
        let b = layout.cards[1].1;
        assert_eq!((a.x, a.y), (18., 18.));
        assert!((b.width - (a.width * 2. + 12.)).abs() < 0.01);
        assert!((layout.height - (36. + 3. * a.height + 24.)).abs() < 0.01);
    }

    #[test]
    fn cover_levels_divide_the_row_exactly() {
        for width in [200., 500., 700., 1000., 1600., 2400.] {
            let available = shelf_available(width);
            let levels = cover_levels(available);
            assert!(!levels.is_empty());
            for pair in levels.windows(2) {
                assert!(pair[0] < pair[1]);
            }
            for &level in &levels {
                let columns = ((available + SHELF_GAP) / (level + SHELF_GAP)).round();
                let filled = columns * level + (columns - 1.) * SHELF_GAP;
                assert!((filled - available).abs() < 0.01);
                assert!(level >= MIN_COVER_WIDTH - 0.01 && level <= MAX_COVER_WIDTH + 0.01);
            }
        }
    }

    #[test]
    fn chosen_cover_width_snaps_to_the_nearest_flush_level() {
        // 964 usable: five columns fill at 183.2, the level nearest 180.
        let layout = LibraryLayout::shelf_with_width(&[0, 1, 2, 3, 4], 1000., 180., |_| false);
        let unit = 976. / 5. - 12.;
        assert!((layout.cover_width - unit).abs() < 0.01);
        assert_eq!(layout.cards.len(), 5);
        // Flush on both edges: first card at the margin, last card at the far margin.
        assert!((layout.cards[0].1.x - 18.).abs() < 0.01);
        assert!((layout.cards[0].1.height - unit * 1.5).abs() < 0.01);
        assert!(
            (layout.cards[4].1.x + layout.cards[4].1.width - (1000. - 18.)).abs() < 0.01
        );
    }

    #[test]
    fn chosen_cover_width_only_lands_on_flush_levels() {
        // Every chosen size snaps to a level the row divides exactly, so a full
        // row always reaches both edges no matter where the control lands.
        for width in [700., 1000., 1600.] {
            let levels = cover_levels(shelf_available(width));
            for step in 0 ..= 105 {
                let chosen = 110. + step as f32 * 2.;
                let layout =
                    LibraryLayout::shelf_with_width(&(0..24).collect::<Vec<_>>(), width, chosen, |_| false);
                assert!(levels.iter().any(|level| (layout.cover_width - level).abs() < 0.01));
                assert!((layout.cards[0].1.x - 18.).abs() < 0.01);
                for (_, card) in &layout.cards {
                    assert!(card.x + card.width <= width - 18. + 0.01);
                }
            }
        }
    }

    #[test]
    fn automatic_width_still_fills_the_row() {
        let layout = shelf(&[0, 1, 2], 480., |_| false);
        assert!((layout.cover_width - (480. - 36. - 24.) / 3.).abs() < 0.01);
        assert!((layout.cards[0].1.x - 18.).abs() < 0.01);
        assert!((layout.cards[2].1.x + layout.cards[2].1.width - (480. - 18.)).abs() < 0.01);
    }

    #[test]
    fn chosen_cover_width_is_clamped_to_the_supported_range() {
        assert_eq!(chosen_cover_width(40.), Some(MIN_COVER_WIDTH));
        assert_eq!(chosen_cover_width(9_000.), Some(MAX_COVER_WIDTH));
        assert_eq!(chosen_cover_width(AUTOMATIC_COVER_WIDTH), None);
        assert_eq!(chosen_cover_width(-5.), None);
        assert_eq!(chosen_cover_width(f32::NAN), None);
    }

    #[test]
    fn reordering_and_filtering_keep_identity_attached_to_the_game() {
        let before = LibraryLayout::classic(&[7, 2, 9, 4], 1080.);
        let after = LibraryLayout::classic(&[4, 9, 2, 7], 1080.);
        assert_eq!(before.cards[0].1, after.cards[0].1);
        assert_eq!((before.cards[0].0, after.cards[0].0), (7, 4));
        let filtered = LibraryLayout::classic(&[9, 7], 1080.);
        assert_eq!(
            filtered.cards.iter().map(|(id, _)| *id).collect::<Vec<_>>(),
            [9, 7]
        );

        let shelf_filtered = shelf(&[9, 7], 1080., |_| false);
        assert_eq!(
            shelf_filtered.cards.iter().map(|(id, _)| *id).collect::<Vec<_>>(),
            [9, 7]
        );
    }

    fn mixed_spans(landscape: &[bool], columns: usize) -> Vec<u32> {
        landscape
            .iter()
            .map(|&wide| if wide { columns.min(2) as u32 } else { 1 })
            .collect()
    }

    #[test]
    fn rows_cover_every_entry_and_respect_column_capacity() {
        let landscape = [false, true, false, true, true, false, false, true];
        for columns in [1, 2, 3, 6, 9] {
            let spans = mixed_spans(&landscape, columns);
            let rows = pack(&spans, columns);
            let mut seen: Vec<usize> = rows.iter().flatten().copied().collect();
            seen.sort_unstable();
            assert_eq!(seen, (0..landscape.len()).collect::<Vec<_>>());
            if columns == 1 {
                assert_eq!(
                    rows.iter().flatten().copied().collect::<Vec<_>>(),
                    (0..landscape.len()).collect::<Vec<_>>()
                );
            }
            let mut remaining: BTreeSet<usize> = (0..landscape.len()).collect();
            for row in rows {
                assert_eq!(row.first().copied(), remaining.iter().next().copied());
                assert!(row.iter().map(|&index| spans[index] as usize).sum::<usize>() <= columns);
                for &index in &row {
                    assert_eq!(spans[index], if landscape[index] { columns.min(2) as u32 } else { 1 });
                }
                remaining.retain(|index| !row.contains(index));
            }
        }
    }

    #[test]
    fn staggers_consecutive_row_landscape_columns() {
        // Two 6-column rows each with 4 portraits and 1 landscape at the tail:
        // row 0 places the wide cover at column 4; row 1 shifts its wide cover
        // away from column 4.
        let landscape = [
            false, false, false, false, true, //
            false, false, false, false, true,
        ];
        let rows = pack(&mixed_spans(&landscape, 6), 6);
        assert_eq!(rows[0], vec![0, 1, 2, 3, 4]);
        assert_eq!(*rows[1].first().unwrap(), 5);
        assert_ne!(*rows[1].last().unwrap(), 9);
        assert_eq!(
            rows[1].iter().copied().collect::<BTreeSet<_>>(),
            (5..=9).collect()
        );
    }

    #[test]
    fn fills_screenshot_gap_with_nearby_portrait() {
        let mut landscape = [false; 21];
        landscape[4] = true;
        landscape[14] = true;
        let rows = pack(&mixed_spans(&landscape, 8), 8);
        assert_eq!(rows[0], (0..=6).collect::<Vec<_>>());
        assert_eq!(rows[1], vec![7, 8, 9, 10, 11, 12, 13, 15]);
        assert_eq!(*rows[2].first().unwrap(), 14);
        let narrow = pack(&mixed_spans(&[false, true, true, false], 2), 2);
        assert_eq!(narrow, vec![vec![0, 3], vec![1], vec![2]]);
    }

    #[test]
    fn prefers_sorted_rows_and_bounds_lookahead() {
        let sorted = pack(&mixed_spans(&[false, true, true, false], 3), 3);
        assert_eq!(sorted, vec![vec![0, 1], vec![2, 3]]);
        let distant = {
            let mut landscape = vec![false];
            landscape.extend(std::iter::repeat_n(true, 10));
            landscape.push(false);
            landscape
        };
        let rows = pack(&mixed_spans(&distant, 2), 2);
        assert_eq!(rows[0], vec![0]);
        assert_eq!(
            rows.iter().flatten().copied().collect::<Vec<_>>(),
            (0..distant.len()).collect::<Vec<_>>()
        );
    }

    #[test]
    fn dynamic_programming_maximizes_row_fill() {
        for pattern in 0..128u32 {
            let landscape: Vec<bool> = (0..7).map(|bit| pattern & (1 << bit) != 0).collect();
            for columns in 1..=4 {
                let spans = mixed_spans(&landscape, columns);
                let rows = pack(&spans, columns);
                let window = 12.min((columns + 2).max(4));
                let mut pending: Vec<usize> = (0..landscape.len()).collect();
                for row in rows {
                    let window: Vec<usize> = pending.iter().copied().take(window).collect();
                    let mut best_used = 0;
                    for mask in 1..(1usize << window.len()) {
                        if mask & 1 == 0 {
                            continue;
                        }
                        let used: usize = (0..window.len())
                            .filter(|bit| mask & (1 << bit) != 0)
                            .map(|bit| spans[window[bit]] as usize)
                            .sum();
                        if used <= columns {
                            best_used = best_used.max(used);
                        }
                    }
                    let used: usize = row.iter().map(|&index| spans[index] as usize).sum();
                    assert_eq!(
                        used, best_used,
                        "pattern {pattern}, columns {columns}, row {row:?}"
                    );
                    pending.retain(|index| !row.contains(index));
                }
                assert!(pending.is_empty());
            }
        }
    }

    /// The automatic shelf, as every call site outside the size control gets it.
    fn shelf(indices: &[usize], width: f32, landscape: impl Fn(usize) -> bool) -> LibraryLayout {
        LibraryLayout::shelf_with_width(indices, width, AUTOMATIC_COVER_WIDTH, landscape)
    }

    #[test]
    fn wide_shelf_covers_include_the_gutter_and_share_height() {
        // 464 of usable width → three columns, matching WhiskyCore at width 464.
        let layout = shelf(&[0, 1, 2], 500., |index| index == 0 || index == 2);
        let (_, portrait) = layout.cards[1];
        let (_, landscape) = layout.cards[0];
        let (_, second_row) = layout.cards[2];
        assert!((landscape.width - (portrait.width * 2. + 12.)).abs() < 0.01);
        assert_eq!(landscape.height, portrait.height);
        assert_eq!((landscape.x, landscape.y), (18., 18.));
        assert!((portrait.x - (18. + landscape.width + 12.)).abs() < 0.01);
        assert!((second_row.y - (18. + portrait.height + 12.)).abs() < 0.01);
    }
}
