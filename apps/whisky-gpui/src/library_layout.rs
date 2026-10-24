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
}

impl LibraryLayout {
    pub fn shelf(indices: &[usize], width: f32, landscape: impl Fn(usize) -> bool) -> Self {
        let available = (width - 36.).max(1.);
        let columns = ((available + 12.) / 152.).floor().max(1.) as usize;
        let unit = (available - (columns - 1) as f32 * 12.) / columns as f32;
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
                        x: 18. + column as f32 * (unit + 12.),
                        y: 18. + row_index as f32 * (card_height + 12.),
                        width: unit * span as f32 + 12. * (span - 1) as f32,
                        height: card_height,
                    },
                ));
                column += span;
            }
        }
        Self {
            cards,
            height: 36. + rows.len() as f32 * (card_height + 12.)
                - if rows.is_empty() { 0. } else { 12. },
        }
    }

    pub fn timeline(indices: &[usize], width: f32) -> Self {
        let cover_width = if width > 1000. { 145. } else { 125. };
        Self::grid(indices, width, 1, 24., 12., cover_width * 1.5 + 26.)
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
                    &LibraryLayout::shelf(&indices, width, |i| i % 3 == 0),
                    &indices,
                    width,
                );
                check(
                    &LibraryLayout::shelf(&indices, width, |_| true),
                    &indices,
                    width,
                );
                check(&LibraryLayout::classic(&indices, width), &indices, width);
                check(&LibraryLayout::timeline(&indices, width), &indices, width);
            }
        }
    }

    #[test]
    fn mixed_shelf_preserves_baseline_packing_and_padding() {
        let layout = LibraryLayout::shelf(&[0, 1, 2, 3, 4], 480., |i| i == 1 || i == 2);
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

        let shelf_filtered = LibraryLayout::shelf(&[9, 7], 1080., |_| false);
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

    #[test]
    fn wide_shelf_covers_include_the_gutter_and_share_height() {
        // 464 of usable width → three columns, matching WhiskyCore at width 464.
        let layout = LibraryLayout::shelf(&[0, 1, 2], 500., |index| index == 0 || index == 2);
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
