use crate::model::Game;

#[derive(Debug, Clone, Copy)]
pub(crate) struct GalleryLayout {
    pub(crate) stacked: bool,
    pub(crate) wall_width: f32,
    pub(crate) detail_width: f32,
    pub(crate) columns: usize,
    pub(crate) card_width: f32,
    pub(crate) card_height: f32,
}
impl GalleryLayout {
    pub(crate) fn new(width: f32) -> Self {
        let available = (width - 40.).max(1.);
        let stacked = available < 620.;
        let detail_width = if stacked {
            available
        } else {
            (available * 0.48).clamp(280., 520.)
        };
        let wall_width = if stacked {
            available
        } else {
            available - detail_width - 20.
        };
        let columns = ((wall_width + 12.) / 192.).floor().max(1.) as usize;
        let card_width = (wall_width - 12. * (columns - 1) as f32) / columns as f32;
        Self {
            stacked,
            wall_width,
            detail_width,
            columns,
            card_width,
            card_height: card_width * 4. / 3.,
        }
    }
}
pub(crate) fn selected_index(
    games: &[Game],
    indices: &[usize],
    selected: Option<&(String, String)>,
) -> Option<usize> {
    indices
        .iter()
        .copied()
        .find(|&index| {
            games.get(index).is_some_and(|game| {
                selected
                    .is_some_and(|(container, id)| game.container == *container && game.id == *id)
            })
        })
        .or_else(|| {
            indices
                .iter()
                .copied()
                .find(|&index| games.get(index).is_some())
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::demo_data;

    fn games() -> Vec<Game> {
        demo_data().to_vec()
    }

    #[test]
    fn layout_dimensions_are_positive_across_window_widths() {
        for width in [320., 480., 660., 800., 1000., 1440., 2200.] {
            let layout = GalleryLayout::new(width);
            assert!(layout.wall_width > 0., "wall_width at {width}");
            assert!(layout.detail_width > 0., "detail_width at {width}");
            assert!(layout.card_width > 0., "card_width at {width}");
            assert!(layout.card_height > 0., "card_height at {width}");
            assert!(layout.columns > 0, "columns at {width}");
        }
    }

    #[test]
    fn layout_stacks_below_the_two_pane_threshold() {
        assert!(GalleryLayout::new(480.).stacked);
        assert!(!GalleryLayout::new(660.).stacked);
        assert!(!GalleryLayout::new(1024.).stacked);
        assert_eq!(GalleryLayout::new(1024.).columns, 2);
        assert_eq!(GalleryLayout::new(800.).columns, 2);
    }

    #[test]
    fn card_columns_fill_the_wall_exactly() {
        for width in [320., 480., 660., 800., 1000., 1440., 2200.] {
            let layout = GalleryLayout::new(width);
            let used =
                layout.card_width * layout.columns as f32 + 12. * (layout.columns - 1) as f32;
            assert!(
                (used - layout.wall_width).abs() < 0.01,
                "columns do not fill the wall at {width}: {used} != {}",
                layout.wall_width
            );
        }
    }

    #[test]
    fn unstacked_panes_and_gap_fill_the_available_width() {
        for width in [660., 800., 1000., 1440., 2200.] {
            let layout = GalleryLayout::new(width);
            let used = layout.wall_width + 20. + layout.detail_width;
            assert!(
                (used - (width - 40.)).abs() < 0.01,
                "panes do not fill the window at {width}: {used} != {}",
                width - 40.
            );
        }
    }

    #[test]
    fn selection_falls_back_to_the_first_visible_index() {
        let games = games();
        assert_eq!(selected_index(&games, &[2, 0, 1], None), Some(2));
    }

    #[test]
    fn selection_survives_catalog_reordering() {
        let mut games = games();
        let selected = (games[2].container.clone(), games[2].id.clone());
        games.swap(0, 2);
        assert_eq!(selected_index(&games, &[0, 1, 2], Some(&selected)), Some(0));
    }

    #[test]
    fn selection_key_survives_index_reordering() {
        let games = games();
        let selected = (games[2].container.clone(), games[2].id.clone());
        assert_eq!(selected_index(&games, &[0, 1, 2], Some(&selected)), Some(2));
        assert_eq!(selected_index(&games, &[1, 2, 0], Some(&selected)), Some(2));
    }

    #[test]
    fn filtered_out_selection_falls_back_to_first_visible() {
        let games = games();
        let selected = (games[5].container.clone(), games[5].id.clone());
        assert_eq!(selected_index(&games, &[0, 1, 2], Some(&selected)), Some(0));
        let removed = ("demo:gone".to_owned(), "demo:gone".to_owned());
        assert_eq!(selected_index(&games, &[1, 2], Some(&removed)), Some(1));
    }

    #[test]
    fn selection_matches_on_container_and_id_together() {
        let mut games = games();
        games[10].id = games[0].id.clone();
        let selected = (games[10].container.clone(), games[10].id.clone());
        assert_eq!(selected_index(&games, &[0, 10], Some(&selected)), Some(10));
    }

    #[test]
    fn empty_or_out_of_range_indices_select_nothing() {
        let games = games();
        assert_eq!(selected_index(&games, &[], None), None);
        assert_eq!(selected_index(&games, &[usize::MAX], None), None);
        let selected = (games[0].container.clone(), games[0].id.clone());
        assert_eq!(selected_index(&games, &[usize::MAX], Some(&selected)), None);
    }
}
