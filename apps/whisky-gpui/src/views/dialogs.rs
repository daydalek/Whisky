//! Modal sheets: run settings, scan folders, winetricks, create bottle, and diagnostics.

use gpui_kit::component::button::{Button, ButtonVariants};
use gpui_kit::component::input::{Input, InputState};
use gpui_kit::component::spinner::Spinner;
use gpui_kit::component::{Disableable, Sizable};
use gpui_kit::component::switch::Switch;
use gpui_kit::{prelude::*, *};

use super::Command;
use crate::bridge::dto::FoldersDto;
use crate::bridge::{BridgeStatus, FolderEdit};
use crate::controls::*;
use crate::runtime::ClipboardDecision;
use crate::scan::{self, JobStatus};
use crate::state::{PreviewSheet, ScanState, WhiskyApp};
use crate::theme::{MUTED, OVERLAY, RADIUS_LG, SURFACE, SURFACE_BORDER};

impl WhiskyApp {
    fn run_settings(&self, index: usize, cx: &Context<Self>) -> AnyElement {
        self.form(
            "run-settings-scroll",
            vec![
                self.section(
                    "run-config",
                    "运行设置",
                    vec![
                        self.info(
                            "程序",
                            self.game(index)
                                .map(|game| game.title.clone())
                                .unwrap_or_default(),
                        ),
                        self.choice(
                            "locale",
                            "区域设置",
                            &[
                                "继承容器",
                                "日语（日本）",
                                "简体中文（中国）",
                                "英语（美国）",
                            ],
                            cx,
                        ),
                        self.field("arguments", "启动参数"),
                    ],
                    cx,
                ),
                self.section(
                    "env-presets",
                    "环境预设",
                    vec![self.choice(
                        "environment-preset",
                        "预设",
                        &["默认", "日语游戏", "旧版视觉小说", "自定义"],
                        cx,
                    )],
                    cx,
                ),
                self.section(
                    "environment",
                    "环境变量",
                    vec![
                        row()
                            .gap(px(10.))
                            .child(
                                div()
                                    .flex_1()
                                    .child(Input::new(&self.preview.inputs["env-key"])),
                            )
                            .child(
                                div()
                                    .flex_1()
                                    .child(Input::new(&self.preview.inputs["env-value"])),
                            )
                            .into_any_element(),
                        self.action("add-env", "添加环境变量", Command::Notice, cx),
                    ],
                    cx,
                ),
                self.section(
                    "overrides",
                    "程序专属覆盖",
                    vec![
                        self.toggle(
                            "override-graphics",
                            "覆盖图形设置",
                            "关闭时继承容器设置。",
                            cx,
                        ),
                        self.choice(
                            "program-backend",
                            "图形后端",
                            &["继承容器", "D3DMetal", "DXVK", "WineD3D"],
                            cx,
                        ),
                        self.toggle("override-sync", "覆盖同步设置", "", cx),
                        self.toggle("override-input", "覆盖输入设置", "", cx),
                        self.toggle("override-display", "覆盖显示设置", "", cx),
                        self.action(
                            "program-dll",
                            "DLL 覆盖…",
                            Command::Sheet(PreviewSheet::Dll),
                            cx,
                        ),
                    ],
                    cx,
                ),
                self.section(
                    "run-diagnostics",
                    "诊断",
                    vec![
                        self.info("最近一次运行", "正常退出 · 8 分钟"),
                        self.action(
                            "run-troubleshoot",
                            "故障排查…",
                            Command::Sheet(PreviewSheet::Diagnostics),
                            cx,
                        ),
                    ],
                    cx,
                ),
                self.section(
                    "console",
                    "控制台与运行历史",
                    vec![
                        self.info("今天 19:39", "退出代码 0"),
                        muted("[wine] Program started\n[wine] Process exited successfully")
                            .font_family("monospace")
                            .p(px(12.))
                            .into_any_element(),
                    ],
                    cx,
                ),
            ],
        )
    }
    /// Scan folders for one bottle. Roots, assignment, exclusion and the
    /// executable are all `folders.*` calls; the scan itself is a bridge job.
    fn scan_settings(&mut self, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        if self.demo {
            return self.demo_scan_settings(cx);
        }
        let Some(container) = self.scan_container() else {
            return self.form(
                "scan-settings-scroll",
                vec![self.section(
                    "scan-folders",
                    "扫描文件夹",
                    vec![muted("请先在侧边栏选择一个容器。").into_any_element()],
                    cx,
                )],
            );
        };
        let mut rows: Vec<AnyElement> = Vec::new();
        match self.folders.get(&container).cloned() {
            Some(folders) => {
                rows.push(self.info(
                    "自动读取元数据",
                    if folders.automatic_metadata {
                        "已启用"
                    } else {
                        "已关闭"
                    },
                ));
                if folders.roots.is_empty() {
                    rows.push(muted("尚未添加扫描文件夹").into_any_element());
                }
                for root in folders.roots.clone() {
                    rows.push(self.scan_root_row(&container, &folders, &root, window, cx));
                }
                rows.push(
                    row()
                        .gap(px(10.))
                        .py(px(10.))
                        .child(
                            div()
                                .flex_1()
                                .child(Input::new(&self.preview.inputs["scan-path"])),
                        )
                        .child(
                            Button::new("scan-add")
                                .label("添加文件夹")
                                .on_click(cx.listener(|this, _, _, cx| {
                                    let path =
                                        this.preview.inputs["scan-path"].read(cx).value().to_string();
                                    this.add_scan_root(&path, cx);
                                })),
                        )
                        .into_any_element(),
                );
            }
            None if self.folders_pending.contains(&container) => rows.push(
                row()
                    .gap(px(8.))
                    .py(px(10.))
                    .child(Spinner::new().with_size(px(14.)))
                    .child(muted("正在读取扫描文件夹…"))
                    .into_any_element(),
            ),
            None => {
                let reason = self
                    .folders_error
                    .get(&container)
                    .cloned()
                    .unwrap_or_else(|| "尚未读取扫描文件夹。".to_owned());
                rows.push(muted(reason).into_any_element());
                rows.push(
                    row()
                        .py(px(8.))
                        .child(
                            Button::new("scan-folders-retry")
                                .label("重试")
                                .on_click(cx.listener(|this, _, _, cx| this.reload_folders(cx))),
                        )
                        .into_any_element(),
                );
            }
        }
        rows.extend(self.scan_controls(&container, cx));
        self.form(
            "scan-settings-scroll",
            vec![self.section("scan-folders", "扫描文件夹", rows, cx)],
        )
    }

    fn scan_root_row(
        &mut self,
        container: &str,
        folders: &FoldersDto,
        root: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let assigned = folders.is_assigned(root);
        let excluded = folders.is_excluded(root);
        let executable = folders.executable_for(root).unwrap_or_default().to_owned();
        let display = if executable.is_empty() {
            "未设置可执行文件".to_owned()
        } else {
            executable.clone()
        };
        let input = self.folder_input(root, &executable, window, cx);
        let assign_root = root.to_owned();
        let exclude_root = root.to_owned();
        let remove_root = root.to_owned();
        let executable_root = root.to_owned();
        let executable_key = format!("scan-exe:{root}");
        col()
            .gap(px(8.))
            .py(px(10.))
            .child(
                row()
                    .gap(px(10.))
                    .child(
                        col()
                            .flex_1()
                            .min_w_0()
                            .gap(px(4.))
                            .child(div().truncate().child(root.to_owned()))
                            .child(muted(display).truncate()),
                    )
                    .child(
                        Switch::new(format!("scan-assign:{root}"))
                            .label("游戏库")
                            .checked(assigned)
                            .on_change(cx.listener(move |this, checked, _, cx| {
                                this.edit_folder(
                                    FolderEdit::Assign {
                                        path: assign_root.clone(),
                                        assigned: *checked,
                                    },
                                    cx,
                                );
                            })),
                    )
                    .child(
                        Switch::new(format!("scan-exclude:{root}"))
                            .label("排除")
                            .checked(excluded)
                            .on_change(cx.listener(move |this, checked, _, cx| {
                                this.edit_folder(
                                    FolderEdit::Exclude {
                                        path: exclude_root.clone(),
                                        excluded: *checked,
                                    },
                                    cx,
                                );
                            })),
                    )
                    .child(
                        Button::new(format!("scan-remove:{root}"))
                            .label("−")
                            .ghost()
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.edit_folder(
                                    FolderEdit::RemoveRoot(remove_root.clone()),
                                    cx,
                                );
                            })),
                    ),
            )
            .child(
                row()
                    .gap(px(10.))
                    .child(div().flex_1().child(Input::new(&input)))
                    .child(
                        Button::new(format!("scan-exe:{root}"))
                            .label("设置可执行文件")
                            .on_click(cx.listener(move |this, _, _, cx| {
                                let text = this
                                    .preview
                                    .folder_inputs
                                    .get(&executable_key)
                                    .map(|input| input.read(cx).value().to_string())
                                    .unwrap_or_default();
                                let executable = (!text.trim().is_empty())
                                    .then(|| text.trim().to_owned());
                                this.edit_folder(
                                    FolderEdit::Executable {
                                        path: executable_root.clone(),
                                        executable,
                                    },
                                    cx,
                                );
                            })),
                    ),
            )
            .child(muted(format!("容器：{container}")).text_size(px(10.)))
            .into_any_element()
    }

    fn folder_input(
        &mut self,
        root: &str,
        value: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Entity<InputState> {
        let key = format!("scan-exe:{root}");
        if let Some(input) = self.preview.folder_inputs.get(&key) {
            return input.clone();
        }
        let entity = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder("/路径/游戏.exe")
                .default_value(value.to_owned())
        });
        self.preview.folder_inputs.insert(key, entity.clone());
        entity
    }

    /// Start / progress / cancel, using the sheet's existing spinner treatment.
    fn scan_controls(&self, container: &str, cx: &Context<Self>) -> Vec<AnyElement> {
        let scan = self.scan_for(container);
        let elsewhere = self
            .scan
            .as_ref()
            .is_some_and(|scan| scan.container != container && scan.running());
        let mut rows: Vec<AnyElement> = Vec::new();
        if let Some(state) = scan {
            let status = state.status.unwrap_or(JobStatus::Queued);
            let label = scan::progress_label(status, state.stage.as_deref());
            let counts = state
                .total
                .map(|total| format!("{} / {total}", state.loaded))
                .unwrap_or_default();
            let mut line = row()
                .gap(px(8.))
                .py(px(10.))
                .child(if state.running() {
                    Spinner::new().with_size(px(14.)).into_any_element()
                } else {
                    div().into_any_element()
                })
                .child(div().child(label));
            if !counts.is_empty() {
                line = line.child(muted(counts));
            }
            rows.push(line.into_any_element());
            if let Some(error) = &state.error {
                rows.push(muted(error.clone()).into_any_element());
            }
        }
        if scan.is_some_and(ScanState::running) {
            rows.push(
                row()
                    .py(px(6.))
                    .child(
                        Button::new("scan-cancel")
                            .label("取消扫描")
                            .on_click(cx.listener(|this, _, _, cx| this.cancel_scan(cx))),
                    )
                    .into_any_element(),
            );
        } else {
            rows.push(
                row()
                    .gap(px(10.))
                    .py(px(6.))
                    .child(
                        Button::new("scan-start")
                            .label(if scan.is_some() { "再次扫描" } else { "立即扫描" })
                            .primary()
                            .disabled(elsewhere)
                            .on_click(cx.listener(|this, _, _, cx| this.start_scan(cx))),
                    )
                    .when(elsewhere, |d| d.child(muted("另一个容器的扫描正在进行")))
                    .into_any_element(),
            );
        }
        rows
    }

    fn demo_scan_settings(&self, cx: &Context<Self>) -> AnyElement {
        self.form(
            "scan-settings-scroll",
            vec![self.section(
                "scan-folders",
                "扫描文件夹",
                vec![
                    self.info("~/Games", "递归扫描"),
                    self.field("scan-path", "添加文件夹"),
                    self.action("scan-add", "添加文件夹", Command::Notice, cx),
                ],
                cx,
            )],
        )
    }

    /// Every `.exe` the helper found under the folder, newest section first.
    /// Choosing one records it; Play opened the picker, so it also starts.
    fn executable_picker(&self, cx: &Context<Self>) -> AnyElement {
        let Some(picker) = self.executable_picker.as_ref() else {
            return self.form(
                "executable-scroll",
                vec![self.section(
                    "executable-empty",
                    "启动程序",
                    vec![self.info("没有找到可启动的程序", "该文件夹下没有 .exe")],
                    cx,
                )],
            );
        };
        let folder = picker.folder.clone();
        let mut rows: Vec<AnyElement> = Vec::new();
        if picker.candidates.is_empty() {
            rows.push(
                row()
                    .gap(px(10.))
                    .py(px(14.))
                    .justify_center()
                    .child(Spinner::new().with_size(px(14.)))
                    .child(muted("正在递归扫描该文件夹下的可执行程序…"))
                    .into_any_element(),
            );
        }
        for (i, candidate) in picker.candidates.iter().enumerate() {
            let path = candidate.path.clone();
            let view = cx.entity().downgrade();
            let location = candidate.location(&folder);
            let is_root = location == "根目录";
            let row_id = SharedString::from(format!("exe-candidate-{}", i));
            rows.push(
                row()
                    .id(row_id)
                    .w_full()
                    .p(px(10.))
                    .my(px(3.))
                    .gap(px(12.))
                    .rounded(px(8.))
                    .bg(rgba(0xffffff05))
                    .border_1()
                    .border_color(rgba(0xffffff08))
                    .cursor_pointer()
                    .hover(|d| d.bg(rgba(0xffffff10)).border_color(rgba(0xffffff18)))
                    .on_click(move |_, _, cx| {
                        let _ = view.update(cx, |this, cx| {
                            this.choose_executable(&path, cx);
                        });
                    })
                    .child(
                        div()
                            .size(px(36.))
                            .rounded(px(7.))
                            .bg(gradient(0xffffff14, 0xffffff06))
                            .border_1()
                            .border_color(rgba(0xffffff0d))
                            .flex()
                            .items_center()
                            .justify_center()
                            .child(icon("package", 16.).text_color(rgb(if is_root { 0xff891b } else { 0x97979b }))),
                    )
                    .child(
                        col()
                            .flex_1()
                            .min_w_0()
                            .gap(px(2.))
                            .child(
                                row()
                                    .gap(px(6.))
                                    .items_center()
                                    .child(
                                        div()
                                            .font_weight(FontWeight::MEDIUM)
                                            .text_size(px(13.))
                                            .truncate()
                                            .child(candidate.name.clone()),
                                    )
                                    .when(is_root, |d| {
                                        d.child(
                                            div()
                                                .px(px(6.))
                                                .py(px(1.))
                                                .rounded(px(4.))
                                                .bg(rgba(0xff891b22))
                                                .text_size(px(10.))
                                                .text_color(rgb(0xff891b))
                                                .child("主程序"),
                                        )
                                    }),
                            )
                            .child(
                                div()
                                    .text_size(px(11.))
                                    .text_color(rgb(0x97979b))
                                    .truncate()
                                    .child(location),
                            ),
                    )
                    .child(
                        row()
                            .gap(px(4.))
                            .items_center()
                            .child(muted("选择"))
                            .child(muted("›")),
                    )
                    .into_any_element(),
            );
        }
        self.form(
            "executable-scroll",
            vec![
                self.section(
                    "executable-folder",
                    "游戏目录",
                    vec![self.info(&picker.title, &folder)],
                    cx,
                ),
                self.section("executable-list", "选择可执行程序 (.exe)", rows, cx),
            ],
        )
    }

    pub(crate) fn preview_sheet(
        &mut self,
        sheet: PreviewSheet,
        width: f32,
        height: f32,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let title = match sheet {
            PreviewSheet::RunSettings(_) => "运行设置",
            PreviewSheet::Scan => "管理扫描文件夹",
            PreviewSheet::Executable => "选择启动程序",
            PreviewSheet::Winetricks => "Winetricks",
            PreviewSheet::CreateBottle => "创建容器",
            PreviewSheet::Diagnostics => "故障排查",
            PreviewSheet::Audio => "音频故障排查",
            PreviewSheet::Dll => "DLL 覆盖",
            PreviewSheet::Graphics => "高级图形设置",
        };
        let content = match sheet {
            PreviewSheet::RunSettings(i) => self.run_settings(i, cx),
            PreviewSheet::Scan => self.scan_settings(window, cx),
            PreviewSheet::Executable => self.executable_picker(cx),
            PreviewSheet::Winetricks => self.form(
                "winetricks-scroll",
                vec![
                    self.field("dependency-search", "搜索组件"),
                    self.section(
                        "tricks",
                        "可用组件",
                        [
                            ("vcrun2022", "Visual C++ 2015–2022"),
                            ("d3dx9", "DirectX 9"),
                            ("lavfilters", "LAV Filters"),
                            ("cjkfonts", "中日韩字体"),
                            ("dotnet48", ".NET Framework 4.8"),
                        ]
                        .into_iter()
                        .map(|(key, label)| self.toggle(key, label, "", cx))
                        .collect(),
                        cx,
                    ),
                ],
            ),
            PreviewSheet::CreateBottle => self.form(
                "create-bottle-scroll",
                vec![self.section(
                    "create",
                    "新容器",
                    vec![
                        self.field("bottle-name", "名称"),
                        self.choice(
                            "create-windows",
                            "Windows 版本",
                            &["Windows 11", "Windows 10", "Windows 7"],
                            cx,
                        ),
                        self.info("位置", "~/Library/Containers/Whisky/Bottles"),
                        self.info("架构", "64 位"),
                    ],
                    cx,
                )],
            ),
            PreviewSheet::Dll => self.form(
                "dll-scroll",
                vec![self.section(
                    "dll-overrides",
                    "DLL 覆盖",
                    vec![
                        self.info("d3dcompiler_47", "原生优先，内建后备"),
                        self.field("dll-name", "添加覆盖"),
                        self.choice(
                            "dll-mode",
                            "加载顺序",
                            &[
                                "原生优先，内建后备",
                                "内建优先，原生后备",
                                "仅原生",
                                "仅内建",
                                "禁用",
                            ],
                            cx,
                        ),
                    ],
                    cx,
                )],
            ),
            PreviewSheet::Graphics => self.form(
                "graphics-scroll",
                vec![self.section(
                    "advanced-graphics",
                    "图形调试",
                    vec![
                        self.toggle("metal-hud", "Metal HUD", "", cx),
                        self.toggle("metal-trace", "Metal 跟踪", "", cx),
                        self.toggle("dxvk-async", "DXVK Async", "", cx),
                        self.choice("dxvk-hud", "DXVK HUD", &["关闭", "FPS", "完整"], cx),
                        self.toggle("dxr", "光线追踪（DXR）", "", cx),
                    ],
                    cx,
                )],
            ),
            PreviewSheet::Audio => self.form(
                "audio-wizard-scroll",
                vec![self.section(
                    "audio-check",
                    "检查音频输出",
                    vec![
                        self.info("1. 输出设备", "系统默认输出"),
                        self.info("2. 采样率", "48,000 Hz"),
                        self.info("3. 游戏音频组件", "等待测试"),
                        self.action("test-audio", "播放测试音频", Command::Notice, cx),
                    ],
                    cx,
                )],
            ),
            PreviewSheet::Diagnostics => self.form(
                "diagnostics-scroll",
                vec![self.section(
                    "guided-diagnostics",
                    "引导式故障排查",
                    vec![
                        self.choice(
                            "diagnosis-symptom",
                            "遇到了什么问题？",
                            &[
                                "游戏无法启动",
                                "黑屏或画面异常",
                                "没有声音",
                                "文字乱码",
                                "游戏运行缓慢",
                            ],
                            cx,
                        ),
                        self.info("最近一次运行", "正常退出"),
                        self.action("analyze", "分析运行日志", Command::Notice, cx),
                        self.action(
                            "audio-link",
                            "音频故障排查…",
                            Command::Sheet(PreviewSheet::Audio),
                            cx,
                        ),
                    ],
                    cx,
                )],
            ),
        };
        let pw = (width - 64.).min(740.);
        let ph = (height - 64.).min(700.);
        div()
            .absolute()
            .inset_0()
            .occlude()
            .on_scroll_wheel(|_, _, cx| cx.stop_propagation())
            .bg(rgba(0x00000088))
            .child(
                div()
                    .id("settings-dismiss")
                    .absolute()
                    .inset_0()
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.preview.sheet = None;
                        this.preview.sheet_history.clear();
                        cx.notify();
                    })),
            )
            .child(
                col()
                    .absolute()
                    .left(px((width - pw) / 2.))
                    .top(px((height - ph) / 2.))
                    .w(px(pw))
                    .h(px(ph))
                    .rounded(px(14.))
                    .overflow_hidden()
                    .bg(rgb(0x29292c))
                    .border_1()
                    .border_color(rgba(0xffffff23))
                    .shadow_xl()
                    .child(
                        row()
                            .flex_shrink_0()
                            .h(px(54.))
                            .px(px(18.))
                            .gap(px(12.))
                            .border_b_1()
                            .border_color(rgba(0xffffff0c))
                            .when(!self.preview.sheet_history.is_empty(), |d| {
                                d.child(Button::new("sheet-back").label("‹").ghost().on_click(
                                    cx.listener(|this, _, _, cx| {
                                        this.preview.sheet = this.preview.sheet_history.pop();
                                        cx.notify();
                                    }),
                                ))
                            })
                            .child(
                                div()
                                    .flex_1()
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .child(title),
                            )
                            .child(Button::new("sheet-close").label("×").ghost().on_click(
                                cx.listener(|this, _, _, cx| {
                                    this.preview.sheet = None;
                                    this.preview.sheet_history.clear();
                                    cx.notify();
                                }),
                            )),
                    )
                    .child(div().flex_1().min_h_0().child(content))
                    .child(
                        row()
                            .flex_shrink_0()
                            .justify_end()
                            .gap(px(8.))
                            .px(px(18.))
                            .py(px(13.))
                            .border_t_1()
                            .border_color(rgba(0xffffff0c))
                            .when(matches!(sheet, PreviewSheet::RunSettings(_)), |d| {
                                d.child(self.action(
                                    "shortcut",
                                    "创建快捷方式",
                                    Command::Notice,
                                    cx,
                                ))
                                .child(self.action(
                                    "reveal",
                                    "在访达中显示",
                                    Command::Notice,
                                    cx,
                                ))
                            })
                            .child(
                                Button::new("sheet-done")
                                    .label(if matches!(sheet, PreviewSheet::CreateBottle) {
                                        "创建"
                                    } else if matches!(sheet, PreviewSheet::Winetricks) {
                                        "安装选中组件"
                                    } else {
                                        "完成"
                                    })
                                    .primary()
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.preview.sheet = None;
                                        this.preview.sheet_history.clear();
                                        cx.notify();
                                    })),
                            ),
                    ),
            )
            .into_any_element()
    }
    /// Clipboard preflight. The helper refuses to launch until it is told
    /// whether to keep or clear the clipboard, so this sheet sits between the
    /// first and second `runtime.launch` call.
    ///
    /// `LaunchInteractionBroker.resolve` accepts exactly `clear` and `keep`;
    /// both continue the launch. Dismissing sends nothing, so nothing starts.
    pub(crate) fn clipboard_dialog(
        &self,
        width: f32,
        height: f32,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let Some(prompt) = &self.clipboard_prompt else {
            return div().into_any_element();
        };
        let content = if prompt.content_type.is_empty() {
            "未知内容".to_owned()
        } else {
            prompt.content_type.clone()
        };
        let detail = format!(
            "启动前检测到剪贴板中有 {content}（{}）。Wine 可能读取剪贴板，请选择如何处理。",
            clipboard_size(prompt.size_bytes)
        );
        let pw = 460_f32.min(width - 48.);
        let ph = 290_f32.min(height - 48.);
        div()
            .absolute()
            .inset_0()
            .occlude()
            .on_scroll_wheel(|_, _, cx| cx.stop_propagation())
            .bg(rgba(OVERLAY))
            .child(
                div()
                    .id("clipboard-dismiss")
                    .absolute()
                    .inset_0()
                    .on_click(cx.listener(|this, _, _, cx| this.dismiss_clipboard(cx))),
            )
            .child(
                col()
                    .absolute()
                    .left(px((width - pw) / 2.))
                    .top(px((height - ph) / 2.))
                    .w(px(pw))
                    .h(px(ph))
                    .rounded(px(RADIUS_LG))
                    .overflow_hidden()
                    .bg(rgb(SURFACE))
                    .border_1()
                    .border_color(rgba(SURFACE_BORDER))
                    .shadow_xl()
                    .child(
                        row()
                            .flex_shrink_0()
                            .h(px(46.))
                            .px(px(16.))
                            .gap(px(12.))
                            .border_b_1()
                            .border_color(rgba(SURFACE_BORDER))
                            .child(
                                div()
                                    .flex_1()
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .child("剪贴板内容"),
                            )
                            .child(
                                Button::new("clipboard-close")
                                    .label("×")
                                    .ghost()
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.dismiss_clipboard(cx);
                                    })),
                            ),
                    )
                    .child(
                        col()
                            .flex_1()
                            .min_h_0()
                            .px(px(18.))
                            .py(px(14.))
                            .gap(px(10.))
                            .child(muted(detail).line_height(relative(1.5)).line_clamp(3))
                            .when_some(prompt.preview.clone(), |d, preview| {
                                d.child(
                                    div()
                                        .flex_shrink_0()
                                        .p(px(10.))
                                        .rounded(px(8.))
                                        .bg(rgba(0xffffff0a))
                                        .font_family("monospace")
                                        .text_size(px(11.))
                                        .text_color(rgb(MUTED))
                                        .line_clamp(4)
                                        .child(preview),
                                )
                            }),
                    )
                    .child(
                        row()
                            .flex_shrink_0()
                            .justify_end()
                            .gap(px(8.))
                            .px(px(16.))
                            .py(px(12.))
                            .border_t_1()
                            .border_color(rgba(SURFACE_BORDER))
                            .child(Button::new("clipboard-cancel").label("取消").ghost().on_click(
                                cx.listener(|this, _, _, cx| this.dismiss_clipboard(cx)),
                            ))
                            .child(
                                Button::new("clipboard-keep")
                                    .label("保留并启动")
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.resolve_clipboard(ClipboardDecision::Keep, cx);
                                    })),
                            )
                            .child(
                                Button::new("clipboard-clear")
                                    .label("清空并启动")
                                    .primary()
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.resolve_clipboard(ClipboardDecision::Clear, cx);
                                    })),
                            ),
                    ),
            )
            .into_any_element()
    }

    pub(crate) fn bridge_status_dialog(
        &self,
        width: f32,
        height: f32,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let (title, detail) = match &self.bridge_status {
            BridgeStatus::Failed { reason, retryable } => (
                "Bridge unavailable",
                if *retryable {
                    reason.clone()
                } else {
                    format!("{reason}\n\nRetrying may not help until the helper is rebuilt.")
                },
            ),
            BridgeStatus::Connected {
                helper,
                version,
                methods,
            } => (
                "Bridge connected",
                format!("{helper}\n{version} · {methods} methods"),
            ),
            BridgeStatus::Stopped => ("Bridge stopped", "The helper is no longer running.".into()),
            BridgeStatus::Locating | BridgeStatus::Starting => (
                "Connecting",
                "The bridge helper is starting.".into(),
            ),
        };
        let retry = matches!(self.bridge_status, BridgeStatus::Failed { .. });
        let pw = 440_f32.min(width - 48.);
        let ph = 210_f32.min(height - 48.);
        div()
            .absolute()
            .inset_0()
            .occlude()
            .on_scroll_wheel(|_, _, cx| cx.stop_propagation())
            .bg(rgba(OVERLAY))
            .child(
                div()
                    .id("bridge-dialog-dismiss")
                    .absolute()
                    .inset_0()
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.bridge_dialog = false;
                        cx.notify();
                    })),
            )
            .child(
                col()
                    .absolute()
                    .left(px((width - pw) / 2.))
                    .top(px((height - ph) / 2.))
                    .w(px(pw))
                    .h(px(ph))
                    .rounded(px(RADIUS_LG))
                    .overflow_hidden()
                    .bg(rgb(SURFACE))
                    .border_1()
                    .border_color(rgba(SURFACE_BORDER))
                    .shadow_xl()
                    .child(
                        row()
                            .flex_shrink_0()
                            .h(px(46.))
                            .px(px(16.))
                            .gap(px(12.))
                            .border_b_1()
                            .border_color(rgba(SURFACE_BORDER))
                            .child(div().flex_1().font_weight(FontWeight::SEMIBOLD).child(title))
                            .child(
                                Button::new("bridge-dialog-close")
                                    .label("×")
                                    .ghost()
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.bridge_dialog = false;
                                        cx.notify();
                                    })),
                            ),
                    )
                    .child(
                        col()
                            .flex_1()
                            .min_h_0()
                            .px(px(18.))
                            .py(px(14.))
                            .gap(px(10.))
                            .child(
                                muted(detail)
                                    .line_height(relative(1.5))
                                    .line_clamp(4),
                            ),
                    )
                    .child(
                        row()
                            .flex_shrink_0()
                            .justify_end()
                            .gap(px(8.))
                            .px(px(16.))
                            .py(px(12.))
                            .border_t_1()
                            .border_color(rgba(SURFACE_BORDER))
                            .child(
                                Button::new("bridge-dialog-done")
                                    .label("关闭")
                                    .ghost()
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.bridge_dialog = false;
                                        cx.notify();
                                    })),
                            )
                            .when(retry, |d| {
                                d.child(
                                    Button::new("bridge-retry")
                                        .label("Retry")
                                        .primary()
                                        .on_click(cx.listener(|this, _, _, cx| {
                                            this.bridge_retry(cx);
                                        })),
                                )
                            }),
                    ),
            )
            .into_any_element()
    }
}

/// Bytes as the sheet shows them. The helper reports the raw byte count.
fn clipboard_size(bytes: i64) -> String {
    if bytes <= 0 {
        return "大小未知".to_owned();
    }
    if bytes < 1024 {
        return format!("{bytes} 字节");
    }
    format!("{:.1} KB", bytes as f64 / 1024.)
}
