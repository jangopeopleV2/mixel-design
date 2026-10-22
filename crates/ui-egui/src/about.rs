//! Help › About MIXEL Design: tabs About · Contributors · Models. About is the splash with the
//! original MIXEL mark, version, website and project links. Contributors and Models are the
//! compiled-in credits (`crate::credits`).

use designcraft_engine::links;
use egui::{Color32, Rect, Sense, Stroke, pos2, vec2};
use serde_json::json;

use crate::DesignApp;
use crate::theme::{Tokens, semibold};

/// MIXEL monogram colour.
pub const BRAND: Color32 = Color32::from_rgb(0x21, 0xb6, 0xa8);
/// The six existing MIXEL sibling buttons, each with its established product project URL.
pub const SIBLINGS: &[(&str, &str, &str)] = &[
    ("https://github.com/jangopeopleV2/mixel-photo", "MIXEL Photo", "image editing"),
    ("https://github.com/jangopeopleV2/mixel-vector", "MIXEL Vector", "vector illustration"),
    ("https://github.com/jangopeopleV2/mixel-film", "MIXEL Film", "video editing, color and sound"),
    ("https://github.com/jangopeopleV2/mixel-light", "MIXEL Light", "photo library and raw development"),
    ("https://github.com/jangopeopleV2/mixel-print", "MIXEL Print", "reading, organizing and protecting PDFs"),
    ("https://github.com/jangopeopleV2/mixel-effects", "MIXEL Effects", "motion graphics and visual effects"),
];

/// The About window's tabs, in `UiState::about_tab` order (`help.about {tab}` names them in lowercase).
pub const ABOUT_TABS: [&str; 3] = ["About", "Contributors", "Models"];

/// Original MIXEL monogram, drawn from simple line segments under MIT OR Apache-2.0.
pub fn paint_mark(ui: &egui::Ui, rect: Rect, color: Color32) {
    let side = rect.width().min(rect.height());
    let area = Rect::from_center_size(rect.center(), vec2(side, side));
    let point = |x: f32, y: f32| pos2(area.left() + side * x, area.top() + side * y);
    let vertices = [point(0.18, 0.82), point(0.18, 0.18), point(0.5, 0.53), point(0.82, 0.18), point(0.82, 0.82)];
    let stroke = Stroke::new(side * 0.11, color);
    for pair in vertices.windows(2) {
        ui.painter().line_segment([pair[0], pair[1]], stroke);
    }
}

/// A text link that opens `url`. Returns true when clicked.
fn link(ui: &mut egui::Ui, text: &str, url: &str, color: Color32) -> bool {
    let resp = ui.add(egui::Label::new(egui::RichText::new(text).size(13.0).color(color).underline()).sense(Sense::click()));
    let resp = resp.on_hover_text(url).on_hover_cursor(egui::CursorIcon::PointingHand);
    resp.clicked()
}

pub fn show(app: &mut DesignApp, ctx: &egui::Context) {
    if !app.ui.about {
        return;
    }
    let t = Tokens::get(ctx);
    let mut open: Option<&'static str> = None;
    let resp = egui::Modal::new(egui::Id::new("about")).show(ctx, |ui| {
        ui.set_width(if app.ui.about_tab == 0 { 460.0 } else { 640.0 });
        ui.horizontal(|ui| {
            for (i, l) in ABOUT_TABS.iter().enumerate() {
                let i = i as u8;
                if ui.selectable_label(app.ui.about_tab == i, crate::rtl::widget(ui, crate::i18n::tr(&app.ui.language, l))).clicked() {
                    app.ui.about_tab = i;
                }
            }
        });
        ui.separator();
        if app.ui.about_tab != 0 {
            let h = 400.0_f32.min(ctx.content_rect().height() * 0.7).max(160.0);
            ui.allocate_ui_with_layout(vec2(ui.available_width(), h), egui::Layout::top_down(egui::Align::Min), |ui| {
                ui.set_min_height(h);
                if app.ui.about_tab == 1 {
                    crate::credits::contributors_ui(ui);
                } else {
                    crate::credits::models_ui(ui);
                }
            });
            ui.separator();
            ui.vertical_centered(|ui| {
                if ui.button(crate::rtl::widget(ui, crate::i18n::tr(&app.ui.language, "  Close  "))).clicked() {
                    app.ui.about = false;
                }
            });
            return;
        }
        ui.vertical_centered(|ui| {
            ui.add_space(8.0);
            let (r, _) = ui.allocate_exact_size(vec2(72.0, 72.0), Sense::hover());
            paint_mark(ui, r, BRAND);
            ui.add_space(6.0);
            ui.label(crate::rtl::widget(
                ui,
                egui::RichText::new(crate::i18n::tr(&app.ui.language, "MIXEL Design")).font(semibold(26.0)).color(t.text_strong),
            ));
            crate::rtl::label(
                ui,
                egui::RichText::new(format!("{} {}", crate::i18n::tr(&app.ui.language, "Version"), env!("CARGO_PKG_VERSION")))
                    .size(12.0)
                    .color(t.text_dim),
            );
            ui.add_space(4.0);
            ui.label(crate::rtl::widget(
                ui,
                egui::RichText::new(crate::i18n::tr(&app.ui.language, "Page layout for print and screen — fast, open and scriptable."))
                    .size(13.0)
                    .color(t.text),
            ));
            ui.add_space(14.0);
            ui.horizontal(|ui| {
                // Centre the row of links.
                let w = 330.0;
                ui.add_space(((ui.available_width() - w) / 2.0).max(0.0));
                for (text, key) in
                    [("MIXEL Design page", "appPage"), ("GitHub", "github"), ("MIXEL Website", "website"), ("Report an issue", "issues")]
                {
                    if link(ui, text, links::get(key).unwrap_or_default(), t.accent) {
                        open = Some(key);
                    }
                    ui.add_space(6.0);
                }
            });
            ui.add_space(16.0);
            ui.separator();
            ui.add_space(6.0);
            ui.label(crate::rtl::widget(
                ui,
                egui::RichText::new(crate::i18n::tr(&app.ui.language, "MIXEL Creative Apps")).font(semibold(12.0)).color(t.text_strong),
            ));
            ui.add_space(4.0);
            ui.horizontal(|ui| {
                let pad = ui.spacing().button_padding.x * 2.0 + ui.spacing().item_spacing.x;
                let w: f32 = SIBLINGS
                    .iter()
                    .map(|(_, n, _)| ui.painter().layout_no_wrap(n.to_string(), egui::FontId::proportional(12.0), Color32::WHITE).size().x + pad)
                    .sum::<f32>()
                    - ui.spacing().item_spacing.x;
                ui.add_space(((ui.available_width() - w) / 2.0).max(0.0));
                for (url, name, what) in SIBLINGS {
                    let b =
                        ui.add(egui::Button::new(egui::RichText::new(*name).size(12.0)).corner_radius(10.0)).on_hover_text(format!("{what} — {url}"));
                    if b.clicked() {
                        app.ui.pending_urls.push((*url).to_string());
                    }
                }
            });
            ui.add_space(12.0);
            ui.label(crate::rtl::widget(
                ui,
                egui::RichText::new(crate::i18n::tr(&app.ui.language, "Open source. No telemetry.")).size(11.0).color(t.text_dim),
            ));
            ui.add_space(8.0);
            if ui.button(crate::rtl::widget(ui, crate::i18n::tr(&app.ui.language, "  Close  "))).clicked() {
                app.ui.about = false;
            }
        });
    });
    if resp.should_close() {
        app.ui.about = false;
    }
    if let Some(k) = open {
        let _ = app.run(&format!("help.{k}"), json!({}));
    }
}
