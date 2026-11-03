//! Daily play journal. Cumulative legacy time is never assigned to invented dates.

use std::collections::BTreeMap;
use chrono::{Datelike, Duration, Local, NaiveDate};
use gpui_kit::component::{
    Disableable, Sizable,
    button::{Button, ButtonVariants},
    progress::Progress,
};
use gpui_kit::{prelude::*, *};

use super::Command;
use crate::controls::*;
use crate::model::Game;
use crate::state::{PreviewPage, WhiskyApp};
use crate::theme;

#[derive(Default)]
struct Journal {
    days: BTreeMap<NaiveDate, Vec<(usize, f64)>>,
    lifetime: u64,
}

impl Journal {
    fn build(games: &[Game], today: NaiveDate) -> Self {
        let mut journal = Self::default();
        for (index, game) in games.iter().enumerate().filter(|(_, game)| !game.is_launcher) {
            journal.lifetime = journal.lifetime.saturating_add(game.play_time.unwrap_or(0));
            for (key, &seconds) in &game.daily_play_time {
                let Ok(date) = NaiveDate::parse_from_str(key, "%Y-%m-%d") else { continue };
                if date > today || !seconds.is_finite() || seconds <= 0. {
                    continue;
                }
                journal.days.entry(date).or_default().push((index, seconds));
            }
        }
        for games in journal.days.values_mut() {
            games.sort_by(|a, b| b.1.total_cmp(&a.1).then(a.0.cmp(&b.0)));
        }
        journal
    }

    fn seconds(&self, date: NaiveDate) -> f64 {
        self.days.get(&date).map_or(0., |games| games.iter().map(|(_, seconds)| seconds).sum())
    }
}

fn duration(seconds: f64) -> String {
    let minutes = (seconds.max(0.) / 60.).floor() as u64;
    if seconds > 0. && minutes == 0 {
        "不足 1 分钟".into()
    } else if minutes < 60 {
        format!("{minutes} 分钟")
    } else {
        format!("{} 小时 {} 分钟", minutes / 60, minutes % 60)
    }
}

fn panel() -> Div {
    col().gap(px(16.)).p(px(22.)).rounded(px(16.))
        .bg(rgba(theme::section_bg()))
        .border_1().border_color(rgba(theme::section_border()))
}

fn heading(text: impl Into<SharedString>) -> Div {
    div().text_size(px(17.)).font_weight(FontWeight::SEMIBOLD).child(text.into())
}

fn intensity(seconds: f64) -> f32 {
    if seconds <= 0. { 0.06 }
    else if seconds < 1800. { 0.24 }
    else if seconds < 3600. { 0.45 }
    else if seconds < 7200. { 0.7 }
    else { 1. }
}

impl WhiskyApp {
    pub(crate) fn statistics_page(&self, width: f32, cx: &Context<Self>) -> AnyElement {
        let today = Local::now().date_naive();
        let journal = Journal::build(self.games(), today);
        let selected = self.preview.statistics_day.unwrap_or(today).min(today);
        // Monday-first calendar: 26 complete columns, with future cells disabled.
        let start = today - Duration::days(today.weekday().num_days_from_monday() as i64 + 25 * 7);
        let week_start = today - Duration::days(6);
        let weekly: f64 = journal.days.range(week_start..=today)
            .flat_map(|(_, games)| games).map(|(_, seconds)| seconds).sum();
        let active = journal.days.range(start..=today).count();
        let daily_games = journal.days.get(&selected).cloned().unwrap_or_default();

        let mut calendar = row().items_start().gap(px(5.));
        calendar = calendar.child(col().gap(px(5.)).pt(px(24.))
            .children(["一", "二", "三", "四", "五", "六", "日"].map(|day| {
                muted(day).h(px(18.)).w(px(18.)).text_size(px(10.))
            })));
        for week in 0..26 {
            let first = start + Duration::weeks(week);
            let label = if week == 0 || first.month() != (first - Duration::weeks(1)).month() {
                format!("{}月", first.month())
            } else { String::new() };
            let mut column = col().gap(px(5.)).child(muted(label).text_size(px(10.)).h(px(19.)));
            for day in 0..7 {
                let date = first + Duration::days(day);
                let seconds = journal.seconds(date);
                let count = journal.days.get(&date).map_or(0, Vec::len);
                column = column.child(
                    Button::new(SharedString::from(format!("play-day-{date}")))
                        .ghost().label("").p_0().w(px(18.)).h(px(18.)).rounded(px(4.))
                        .bg(rgb(theme::ACCENT).opacity(intensity(seconds)))
                        .border_1().border_color(if date == selected {
                            rgb(theme::ACCENT).into()
                        } else { rgba(0x00000000) })
                        .disabled(date > today)
                        .tooltip(format!("{date} · {count} 款游戏 · {}", duration(seconds)))
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.preview.statistics_day = Some(date);
                            cx.notify();
                        })),
                );
            }
            calendar = calendar.child(column);
        }

        let summaries = [
            ("累计游玩", duration(journal.lifetime as f64), "包含旧版累计记录"),
            ("最近 7 天", duration(weekly), "已记录的每日游玩时间"),
            ("活跃天数", format!("{active} 天"), "最近 26 周"),
            ("今天", duration(journal.seconds(today)), "每段冒险都值得记住"),
        ];
        let summary = div().grid().grid_cols(if width < 960. { 2 } else { 4 }).gap(px(12.)).children(
            summaries.into_iter().map(|(label, value, subtitle)| {
                panel().min_w_0().gap(px(8.))
                    .child(muted(label))
                    .child(div().text_size(px(25.)).font_weight(FontWeight::BOLD).child(value))
                    .child(muted(subtitle).text_size(px(11.)))
            }),
        );

        let mut details = panel().child(
            row().justify_between().gap(px(12.))
                .child(col().gap(px(5.)).child(heading(format!("{selected}")))
                    .child(muted(format!("{} 款游戏 · {}", daily_games.len(), duration(journal.seconds(selected))))))
                .child(Button::new("statistics-today").label("回到今天").ghost()
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.preview.statistics_day = None;
                        cx.notify();
                    }))),
        );
        if daily_games.is_empty() {
            details = details.child(col().items_center().gap(px(10.)).py(px(30.))
                .child(icon("package", 30.).text_color(rgb(theme::muted_color())))
                .child(heading("这一天，还没有留下游玩足迹"))
                .child(muted("从游戏库开始一段新冒险，游玩时间会自动记录。"))
                .child(self.action("statistics-library", "前往游戏库", Command::Page(PreviewPage::Library), cx)));
        }
        let total = journal.seconds(selected).max(1.);
        for (index, seconds) in daily_games {
            let game = &self.games()[index];
            let primary = self.primary_action(index);
            let mut entry = row().gap(px(16.)).py(px(10.));
            entry = entry.child(match self.artwork(index) {
                Some(path) => self.artwork_image(path).w(px(48.)).h(px(62.)).rounded(px(7.))
                    .object_fit(ObjectFit::Cover).into_any_element(),
                None => div().w(px(48.)).h(px(62.)).rounded(px(7.)).bg(rgba(theme::badge_bg()))
                    .flex().items_center().justify_center().child(icon("package", 22.)).into_any_element(),
            });
            details = details.child(entry
                .child(col().flex_1().min_w_0().gap(px(8.))
                    .child(row().justify_between().gap(px(12.))
                        .child(div().truncate().font_weight(FontWeight::SEMIBOLD).child(game.title.clone()))
                        .child(muted(duration(seconds))))
                    .child(Progress::new(("statistics-progress", index))
                        .value((seconds / total * 100.) as f32).small()
                        .color(rgb(theme::ACCENT))
                        .accessibility_label(format!("{} 当日时长占比", game.title)))
                    .child(muted(self.bottles.iter().find(|b| b.path == game.container)
                        .map_or("容器不可用", |b| b.name.as_str()).to_owned()).text_size(px(11.))))
                .child(Button::new(("statistics-resume", index))
                    .label(if self.demo || primary.label == "Play" { "继续游玩" } else { primary.label })
                    .primary().disabled(!self.demo && !primary.enabled)
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.command(Command::Runtime(index), cx);
                    }))));
        }
        self.preview_scroll("statistics-scroll",
            col().w_full().p(px(26.)).gap(px(22.))
                .child(row().justify_between().gap(px(12.)).flex_wrap()
                    .child(col().gap(px(6.)).child(div().text_size(px(28.)).font_weight(FontWeight::BOLD).child("游玩足迹"))
                        .child(muted("把每一天的冒险，连成属于你的故事。")))
                    .child(self.action("statistics-refresh", "刷新记录", Command::RefreshLibrary, cx)))
                .child(summary)
                .child(panel()
                    .child(row().justify_between().flex_wrap().gap(px(8.))
                        .child(heading("游玩日历"))
                        .child(muted(format!("{} — {}", start.format("%Y.%m.%d"), today.format("%Y.%m.%d")))))
                    .child(div().id("statistics-calendar-scroll").overflow_x_scroll().child(calendar))
                    .child(row().justify_end().gap(px(6.)).child(muted("少"))
                        .children([0., 600., 1800., 3600., 7200.].map(|seconds| {
                            div().size(px(12.)).rounded(px(3.)).bg(rgb(theme::ACCENT).opacity(intensity(seconds)))
                        })).child(muted("多")))
                    .child(muted("点击日期查看明细 · 颜色按每日时长分级：半小时 / 1 小时 / 2 小时")))
                .child(details)
                .child(muted("每日明细从此版本开始记录，旧版累计时长不会被分配到历史日期。日期按记录时的本地时区划分；统计范围为当前库中的游戏，不含启动器。"))
        )
    }
}

#[cfg(test)]
mod tests {
    use super::{Journal, duration};
    use std::collections::BTreeMap;
    use chrono::NaiveDate;
    use crate::model::demo_data;

    #[test]
    fn journal_keeps_legacy_time_separate_and_rejects_bad_days() {
        let today = NaiveDate::from_ymd_opt(2026, 10, 30).unwrap();
        let mut game = demo_data()[0].clone();
        game.play_time = Some(7200);
        game.daily_play_time = BTreeMap::from([
            ("2026-10-30".into(), 1200.),
            ("2026-10-29".into(), 600.),
            ("2026-10-31".into(), 100.),
            ("invalid".into(), 100.),
            ("2026-10-28".into(), f64::NAN),
            ("2026-10-27".into(), -1.),
        ]);
        let journal = Journal::build(&[game.clone()], today);
        assert_eq!(journal.lifetime, 7200);
        assert_eq!(journal.days.len(), 2);
        assert_eq!(journal.seconds(today), 1200.);
        game.is_launcher = true;
        assert!(Journal::build(&[game], today).days.is_empty());
    }

    #[test]
    fn sub_minute_play_is_not_displayed_as_zero() {
        assert_eq!(duration(30.), "不足 1 分钟");
        assert_eq!(duration(0.), "0 分钟");
        assert_eq!(duration(3660.), "1 小时 1 分钟");
    }
}
