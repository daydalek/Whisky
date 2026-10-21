//! Target geometry for the existing three library presentations.
//! Animation state belongs to GPUI Base, keyed by game identity in `main.rs`.

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
        let mut pending = indices.to_vec();
        let mut cards = Vec::with_capacity(indices.len());
        let mut row = 0;
        while !pending.is_empty() {
            let mut used = 0;
            while used < columns && !pending.is_empty() {
                let capacity = columns - used;
                let position = pending
                    .iter()
                    .take(10)
                    .position(|&i| !landscape(i) || capacity >= 2 || columns == 1);
                let Some(position) = position else { break };
                let index = pending.remove(position);
                let span = if landscape(index) && columns >= 2 {
                    2
                } else {
                    1
                };
                cards.push((
                    index,
                    CardRect {
                        x: 18. + used as f32 * (unit + 12.),
                        y: 18. + row as f32 * (card_height + 12.),
                        width: unit * span as f32 + 12. * (span - 1) as f32,
                        height: card_height,
                    },
                ));
                used += span;
            }
            row += 1;
        }
        Self {
            cards,
            height: 36. + row as f32 * (card_height + 12.) - if row > 0 { 12. } else { 0. },
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
    }
}
