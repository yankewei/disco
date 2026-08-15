//! Markdown rendering for GPUI.
//!
//! Parses Markdown text via `pulldown-cmark` and maps the resulting event
//! stream onto GPUI DOM elements. Supported constructs: headings, paragraphs,
//! fenced code blocks, inline code, bold / italic, ordered & unordered lists,
//! links, block-quotes, and tables.
//!
//! Known fidelity limits: nested lists are flattened into their outermost
//! list, hard line breaks render as in-paragraph newlines, and code blocks or
//! headings nested inside list items / block-quotes are hoisted to top-level
//! blocks. HTML events are dropped entirely.
//!
//! Parsing ([`parse_blocks`]) is separated from element construction
//! ([`render_blocks`]) so callers can cache the parsed block list across
//! frames and only rebuild elements.

use gpui::prelude::FluentBuilder;
use gpui::{
    FontStyle, FontWeight, InteractiveText, ParentElement, Styled, StyledText, TextAlign,
    TextStyle, UnderlineStyle, div, px, rgb,
};
use pulldown_cmark::{Alignment, CodeBlockKind, Event, HeadingLevel, Options, Parser, Tag, TagEnd};

use crate::AppAppearance;

const MONO_FONT: &str = "SF Mono";

/// Renders a Markdown string as a vertical stack of GPUI elements.
#[cfg(test)]
pub fn render_markdown(text: &str, palette: AppAppearance) -> gpui::Div {
    render_blocks(&parse_blocks(text), palette)
}

/// Parses Markdown text into the renderable [`Block`] model.
///
/// This is the expensive step (full pulldown-cmark pass); cache its result
/// while the source text is unchanged and feed it to [`render_blocks`].
pub(crate) fn parse_blocks(text: &str) -> Vec<Block> {
    let mut options = Options::empty();
    options.insert(Options::ENABLE_STRIKETHROUGH);
    options.insert(Options::ENABLE_TABLES);
    collect_blocks(Parser::new_ext(text, options))
}

/// Builds the GPUI element stack for already-parsed blocks.
pub(crate) fn render_blocks(blocks: &[Block], palette: AppAppearance) -> gpui::Div {
    div()
        .flex()
        .flex_col()
        .gap(px(8.))
        .children(blocks.iter().map(|block| render_block(block, palette)))
}

/// Cheap content fingerprint used to key parse caches and derive element ids.
pub(crate) fn text_hash(text: &str) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    text.hash(&mut hasher);
    hasher.finish()
}

// ---------------------------------------------------------------------------
// Block model
// ---------------------------------------------------------------------------

#[derive(Debug)]
pub(crate) enum Block {
    Heading {
        level: u32,
        text: String,
    },
    Paragraph {
        segments: Vec<InlineSegment>,
    },
    Code {
        language: Option<String>,
        code: String,
    },
    List {
        ordered: bool,
        items: Vec<Vec<InlineSegment>>,
    },
    Quote {
        text: String,
    },
    Table {
        header: Vec<Vec<InlineSegment>>,
        rows: Vec<Vec<Vec<InlineSegment>>>,
        alignments: Vec<TextAlign>,
    },
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) enum InlineSegment {
    Text(String),
    Bold(String),
    Italic(String),
    Code(String),
    Link { text: String, url: String },
}

// ---------------------------------------------------------------------------
// Parsing: event stream -> block list
// ---------------------------------------------------------------------------

fn collect_blocks<'a>(parser: Parser<'a>) -> Vec<Block> {
    let mut blocks: Vec<Block> = Vec::new();
    let mut in_heading: Option<u32> = None;
    let mut heading_text = String::new();
    let mut in_code_block: Option<Option<String>> = None;
    let mut code_text = String::new();
    let mut in_paragraph = false;
    let mut paragraph_segments: Vec<InlineSegment> = Vec::new();
    let mut in_list: Option<bool> = None; // Some(ordered)
    let mut list_depth: u32 = 0;
    let mut list_items: Vec<Vec<InlineSegment>> = Vec::new();
    let mut current_item_segments: Vec<InlineSegment> = Vec::new();
    let mut in_blockquote = false;
    let mut blockquote_text = String::new();
    // Table state
    let mut table_header: Vec<Vec<InlineSegment>> = Vec::new();
    let mut table_rows: Vec<Vec<Vec<InlineSegment>>> = Vec::new();
    let mut current_row_cells: Vec<Vec<InlineSegment>> = Vec::new();
    let mut in_table_cell = false;
    let mut current_cell: Vec<InlineSegment> = Vec::new();
    let mut table_alignments: Vec<TextAlign> = Vec::new();
    // Inline state
    let mut bold_depth: u32 = 0;
    let mut italic_depth: u32 = 0;
    let mut in_link: Option<String> = None; // url
    let mut link_text = String::new();

    for event in parser {
        match event {
            // -- Block starts -------------------------------------------------
            Event::Start(Tag::Heading { level, .. }) => {
                in_heading = Some(heading_level_to_u32(level));
                heading_text.clear();
            }
            Event::Start(Tag::CodeBlock(kind)) => {
                let lang = match kind {
                    CodeBlockKind::Fenced(info) if !info.is_empty() => Some(info.to_string()),
                    _ => None,
                };
                in_code_block = Some(lang);
                code_text.clear();
            }
            Event::Start(Tag::Paragraph) => {
                if in_blockquote {
                    continue;
                }
                if in_list.is_some() {
                    continue;
                }
                in_paragraph = true;
                paragraph_segments.clear();
            }
            Event::Start(Tag::List(ordered)) => {
                list_depth += 1;
                if list_depth == 1 {
                    in_list = Some(ordered.is_some());
                    list_items.clear();
                }
            }
            Event::Start(Tag::Item) => {
                current_item_segments.clear();
            }
            Event::Start(Tag::BlockQuote(_)) => {
                in_blockquote = true;
                blockquote_text.clear();
            }
            Event::Start(Tag::Table(alignments)) => {
                table_header.clear();
                table_rows.clear();
                table_alignments = alignments
                    .iter()
                    .map(|alignment| match alignment {
                        Alignment::Center => TextAlign::Center,
                        Alignment::Right => TextAlign::Right,
                        Alignment::Left | Alignment::None => TextAlign::Left,
                    })
                    .collect();
            }
            Event::Start(Tag::TableHead) => {}
            Event::Start(Tag::TableRow) => current_row_cells.clear(),
            Event::Start(Tag::TableCell) => {
                in_table_cell = true;
                current_cell.clear();
            }
            Event::Start(Tag::Link { dest_url, .. }) => {
                in_link = Some(dest_url.to_string());
                link_text.clear();
            }
            Event::Start(Tag::Strong) => bold_depth += 1,
            Event::Start(Tag::Emphasis) => italic_depth += 1,

            // -- Inline content -----------------------------------------------
            Event::Text(text) => {
                if let Some(_lang) = &in_code_block {
                    code_text.push_str(&text);
                } else if in_heading.is_some() {
                    heading_text.push_str(&text);
                } else if in_blockquote {
                    blockquote_text.push_str(&text);
                } else if in_link.is_some() {
                    link_text.push_str(&text);
                } else {
                    let target = inline_target(
                        in_table_cell,
                        in_list.is_some(),
                        &mut paragraph_segments,
                        &mut current_item_segments,
                        &mut current_cell,
                    );
                    if bold_depth > 0 {
                        target.push(InlineSegment::Bold(text.to_string()));
                    } else if italic_depth > 0 {
                        target.push(InlineSegment::Italic(text.to_string()));
                    } else {
                        target.push(InlineSegment::Text(text.to_string()));
                    }
                }
            }
            Event::Code(code) => {
                let target = inline_target(
                    in_table_cell,
                    in_list.is_some(),
                    &mut paragraph_segments,
                    &mut current_item_segments,
                    &mut current_cell,
                );
                target.push(InlineSegment::Code(code.to_string()));
            }
            break_event @ (Event::SoftBreak | Event::HardBreak) => {
                let is_hard_break = matches!(break_event, Event::HardBreak);
                if in_code_block.is_some() {
                    code_text.push('\n');
                } else if in_heading.is_some() {
                    heading_text.push(' ');
                } else if in_blockquote {
                    blockquote_text.push('\n');
                } else {
                    let target = inline_target(
                        in_table_cell,
                        in_list.is_some(),
                        &mut paragraph_segments,
                        &mut current_item_segments,
                        &mut current_cell,
                    );
                    // A hard break (two trailing spaces) keeps its newline so
                    // forced line breaks survive rendering; a soft break is
                    // just whitespace in CommonMark.
                    target.push(InlineSegment::Text(if is_hard_break {
                        "\n".into()
                    } else {
                        " ".into()
                    }));
                }
            }

            // -- Block / inline ends ------------------------------------------
            Event::End(TagEnd::Heading(_)) => {
                if let Some(level) = in_heading.take() {
                    blocks.push(Block::Heading {
                        level,
                        text: heading_text.clone(),
                    });
                }
            }
            Event::End(TagEnd::CodeBlock) => {
                let lang = in_code_block.take().flatten();
                blocks.push(Block::Code {
                    language: lang,
                    code: code_text.trim_end().to_string(),
                });
            }
            Event::End(TagEnd::Paragraph) => {
                if in_paragraph {
                    in_paragraph = false;
                    if !paragraph_segments.is_empty() {
                        blocks.push(Block::Paragraph {
                            segments: paragraph_segments.clone(),
                        });
                    }
                }
            }
            Event::End(TagEnd::List(_)) => {
                list_depth = list_depth.saturating_sub(1);
                if list_depth == 0
                    && let Some(ordered) = in_list.take()
                    && !list_items.is_empty()
                {
                    blocks.push(Block::List {
                        ordered,
                        items: list_items.clone(),
                    });
                }
            }
            Event::End(TagEnd::Item) => {
                if in_list.is_some() && list_depth == 1 {
                    list_items.push(current_item_segments.clone());
                    current_item_segments.clear();
                }
            }
            Event::End(TagEnd::BlockQuote(_)) => {
                in_blockquote = false;
                if !blockquote_text.is_empty() {
                    blocks.push(Block::Quote {
                        text: blockquote_text.trim().to_string(),
                    });
                }
            }
            Event::End(TagEnd::Link) => {
                if let Some(url) = in_link.take() {
                    let target = inline_target(
                        in_table_cell,
                        in_list.is_some(),
                        &mut paragraph_segments,
                        &mut current_item_segments,
                        &mut current_cell,
                    );
                    target.push(InlineSegment::Link {
                        text: link_text.clone(),
                        url: url.to_string(),
                    });
                    link_text.clear();
                }
            }
            Event::End(TagEnd::TableCell) => {
                in_table_cell = false;
                current_row_cells.push(std::mem::take(&mut current_cell));
            }
            Event::End(TagEnd::TableRow) => {
                table_rows.push(std::mem::take(&mut current_row_cells));
            }
            Event::End(TagEnd::TableHead) => {
                // Header cells are direct children of `TableHead` — no row
                // wrapper, so the header is the row collected so far.
                table_header = std::mem::take(&mut current_row_cells);
            }
            Event::End(TagEnd::Table) => {
                in_table_cell = false;
                if !table_header.is_empty() {
                    blocks.push(Block::Table {
                        header: table_header.clone(),
                        rows: table_rows.clone(),
                        alignments: table_alignments.clone(),
                    });
                }
            }
            Event::End(TagEnd::Strong) => bold_depth = bold_depth.saturating_sub(1),
            Event::End(TagEnd::Emphasis) => italic_depth = italic_depth.saturating_sub(1),

            _ => {}
        }
    }

    blocks
}

fn heading_level_to_u32(level: HeadingLevel) -> u32 {
    match level {
        HeadingLevel::H1 => 1,
        HeadingLevel::H2 => 2,
        HeadingLevel::H3 => 3,
        HeadingLevel::H4 => 4,
        HeadingLevel::H5 => 5,
        HeadingLevel::H6 => 6,
    }
}

/// Routes inline content to the sink of the innermost active container:
/// table cell > list item > paragraph.
fn inline_target<'a>(
    in_table_cell: bool,
    in_list: bool,
    paragraph: &'a mut Vec<InlineSegment>,
    list_item: &'a mut Vec<InlineSegment>,
    cell: &'a mut Vec<InlineSegment>,
) -> &'a mut Vec<InlineSegment> {
    if in_table_cell {
        cell
    } else if in_list {
        list_item
    } else {
        paragraph
    }
}

// ---------------------------------------------------------------------------
// Rendering: blocks -> GPUI elements
// ---------------------------------------------------------------------------

fn render_block(block: &Block, palette: AppAppearance) -> gpui::Div {
    match block {
        Block::Heading { level, text } => render_heading(*level, text, palette),
        Block::Paragraph { segments } => render_paragraph(segments, palette),
        Block::Code { language, code } => render_code_block(language.as_deref(), code, palette),
        Block::List { ordered, items } => render_list(*ordered, items, palette),
        Block::Quote { text } => render_blockquote(text, palette),
        Block::Table {
            header,
            rows,
            alignments,
        } => render_table(header, rows, alignments, palette),
    }
}

fn render_heading(level: u32, text: &str, palette: AppAppearance) -> gpui::Div {
    let (size, weight) = match level {
        1 => (px(20.), FontWeight::BOLD),
        2 => (px(17.), FontWeight::BOLD),
        3 => (px(15.), FontWeight::SEMIBOLD),
        4 => (px(14.), FontWeight::SEMIBOLD),
        _ => (px(13.), FontWeight::MEDIUM),
    };
    div()
        .text_size(size)
        .font_weight(weight)
        .text_color(rgb(palette.text))
        .child(text.to_string())
}

fn render_paragraph(segments: &[InlineSegment], palette: AppAppearance) -> gpui::Div {
    div().child(styled_segments(segments, palette))
}

/// Builds one run of shaped text from inline segments, so bold/italic/code/link
/// styling flows inline within a paragraph instead of stacking as block rows.
fn styled_segments(segments: &[InlineSegment], palette: AppAppearance) -> gpui::Div {
    styled_segments_with_weight(segments, palette, None)
}

/// Like [`styled_segments`], but forces every run to a font weight — used by
/// table header cells.
fn styled_segments_with_weight(
    segments: &[InlineSegment],
    palette: AppAppearance,
    weight: Option<FontWeight>,
) -> gpui::Div {
    let base = TextStyle {
        color: rgb(palette.text).into(),
        font_size: px(13.5).into(),
        line_height: px(22.).into(),
        ..Default::default()
    };
    let base = match weight {
        Some(weight) => TextStyle {
            font_weight: weight,
            ..base
        },
        None => base,
    };

    let mut text = String::new();
    let mut runs = Vec::new();
    // Link ranges are indexed in the same order their URLs are collected, so
    // the click listener can resolve the clicked range back to its URL.
    let mut link_urls: Vec<String> = Vec::new();
    let mut link_ranges: Vec<std::ops::Range<usize>> = Vec::new();
    for segment in segments {
        let mut is_link = false;
        let (content, style) = match segment {
            InlineSegment::Text(content) => (content.as_str(), base.clone()),
            InlineSegment::Bold(content) => (
                content.as_str(),
                TextStyle {
                    font_weight: FontWeight::BOLD,
                    ..base.clone()
                },
            ),
            InlineSegment::Italic(content) => (
                content.as_str(),
                TextStyle {
                    font_style: FontStyle::Italic,
                    ..base.clone()
                },
            ),
            InlineSegment::Code(content) => (
                content.as_str(),
                TextStyle {
                    font_family: MONO_FONT.into(),
                    background_color: Some(rgb(palette.surface_subtle).into()),
                    ..base.clone()
                },
            ),
            InlineSegment::Link { text, url } => {
                is_link = true;
                link_urls.push(url.clone());
                (
                    text.as_str(),
                    TextStyle {
                        color: rgb(palette.blue).into(),
                        underline: Some(UnderlineStyle {
                            color: Some(rgb(palette.blue).into()),
                            thickness: px(1.),
                            wavy: false,
                        }),
                        ..base.clone()
                    },
                )
            }
        };
        let start = text.len();
        runs.push(style.to_run(content.len()));
        text.push_str(content);
        if is_link {
            link_ranges.push(start..text.len());
        }
    }

    if link_urls.is_empty() {
        return div().child(StyledText::new(text).with_runs(runs));
    }
    // Derive the element id from the text so repeated paragraphs in one tree
    // still get mostly distinct ids for interaction state.
    let id = text_hash(&text) as usize;
    div().child(
        InteractiveText::new(id, StyledText::new(text).with_runs(runs)).on_click(
            link_ranges,
            move |index, _, cx| {
                if let Some(url) = link_urls.get(index) {
                    cx.open_url(url);
                }
            },
        ),
    )
}

fn render_code_block(language: Option<&str>, code: &str, palette: AppAppearance) -> gpui::Div {
    let mut block = div()
        .rounded(px(9.))
        .overflow_hidden()
        .bg(rgb(palette.surface_subtle));

    // Language label header
    if let Some(lang) = language {
        block = block.child(
            div()
                .px_3()
                .py_1()
                .text_size(px(11.))
                .font_weight(FontWeight::MEDIUM)
                .text_color(rgb(palette.muted))
                .border_b_1()
                .border_color(rgb(palette.border))
                .child(lang.to_string()),
        );
    }

    // Code content
    block = block.child(
        div()
            .px_3()
            .py_2()
            .font_family(MONO_FONT)
            .text_size(px(12.))
            .line_height(px(18.))
            .text_color(rgb(palette.text))
            .overflow_hidden()
            .child(code.to_string()),
    );

    block
}

fn render_list(ordered: bool, items: &[Vec<InlineSegment>], palette: AppAppearance) -> gpui::Div {
    let mut container = div().flex().flex_col().gap(px(4.));

    for (index, item_segments) in items.iter().enumerate() {
        let prefix = if ordered {
            format!("{}.", index + 1)
        } else {
            "•".to_string()
        };

        let row = div()
            .flex()
            .gap(px(8.))
            .child(
                div()
                    .min_w(px(16.))
                    .text_size(px(13.5))
                    .line_height(px(22.))
                    .text_color(rgb(palette.muted))
                    .child(prefix),
            )
            .child(
                div()
                    .flex_grow()
                    .child(styled_segments(item_segments, palette)),
            );
        container = container.child(row);
    }

    container
}

fn render_blockquote(text: &str, palette: AppAppearance) -> gpui::Div {
    div()
        .pl_3()
        .border_l_2()
        .border_color(rgb(palette.border_strong))
        .text_size(px(13.5))
        .line_height(px(22.))
        .text_color(rgb(palette.muted))
        .child(text.to_string())
}

fn render_table(
    header: &[Vec<InlineSegment>],
    rows: &[Vec<Vec<InlineSegment>>],
    alignments: &[TextAlign],
    palette: AppAppearance,
) -> gpui::Div {
    let column_count = header.len();
    let mut table = div()
        .rounded(px(9.))
        .overflow_hidden()
        .border_1()
        .border_color(rgb(palette.border));

    let header_row =
        div()
            .flex()
            .bg(rgb(palette.surface_subtle))
            .children(header.iter().enumerate().map(|(index, cell)| {
                render_table_cell(cell, index, column_count, alignments, palette, true)
            }));
    table = table.child(header_row);

    for row in rows {
        let mut cells: Vec<&[InlineSegment]> = row.iter().map(Vec::as_slice).collect();
        // Pad ragged rows so every column keeps its width.
        cells.resize(column_count, &[]);
        let row_div = div()
            .flex()
            .border_t_1()
            .border_color(rgb(palette.border))
            .children(cells.into_iter().enumerate().map(|(index, cell)| {
                render_table_cell(cell, index, column_count, alignments, palette, false)
            }));
        table = table.child(row_div);
    }

    table
}

fn render_table_cell(
    cell: &[InlineSegment],
    index: usize,
    column_count: usize,
    alignments: &[TextAlign],
    palette: AppAppearance,
    is_header: bool,
) -> gpui::Div {
    let align = alignments.get(index).copied().unwrap_or(TextAlign::Left);
    let content = if is_header {
        styled_segments_with_weight(cell, palette, Some(FontWeight::SEMIBOLD))
    } else {
        styled_segments(cell, palette)
    };
    div()
        .flex_grow()
        .min_w(px(0.))
        .px_2()
        .py_1()
        .text_size(px(12.5))
        .line_height(px(18.))
        .text_align(align)
        .when(index + 1 < column_count, |cell_div| {
            cell_div.border_r_1().border_color(rgb(palette.border))
        })
        .child(content)
}

#[cfg(test)]
mod tests {
    use super::{Block, InlineSegment, parse_blocks, render_markdown};
    use crate::AppAppearance;
    use gpui::{InteractiveElement, ParentElement, Styled, WindowAppearance, point, size};

    fn parse(text: &str) -> Vec<Block> {
        parse_blocks(text)
    }

    #[test]
    fn fenced_code_blocks_carry_language_and_body() {
        let blocks = parse("```rust\nfn main() {}\n```");
        assert_eq!(blocks.len(), 1);
        match &blocks[0] {
            Block::Code { language, code } => {
                assert_eq!(language.as_deref(), Some("rust"));
                assert_eq!(code, "fn main() {}");
            }
            other => panic!("expected a code block, got {other:?}"),
        }
    }

    #[test]
    fn paragraphs_collect_bold_and_inline_code_segments() {
        let blocks = parse("Run **cargo test** with `--verbose`.");
        assert_eq!(blocks.len(), 1);
        match &blocks[0] {
            Block::Paragraph { segments } => {
                assert!(segments.contains(&InlineSegment::Bold("cargo test".into())));
                assert!(segments.contains(&InlineSegment::Code("--verbose".into())));
            }
            other => panic!("expected a paragraph, got {other:?}"),
        }
    }

    #[test]
    fn ordered_lists_keep_their_items() {
        let blocks = parse("1. First\n2. Second");
        assert_eq!(blocks.len(), 1);
        match &blocks[0] {
            Block::List { ordered, items } => {
                assert!(ordered);
                assert_eq!(items.len(), 2);
            }
            other => panic!("expected a list, got {other:?}"),
        }
    }

    #[test]
    fn quotes_collect_their_text() {
        let blocks = parse("> quoted words");
        assert_eq!(blocks.len(), 1);
        match &blocks[0] {
            Block::Quote { text } => assert_eq!(text, "quoted words"),
            other => panic!("expected a quote, got {other:?}"),
        }
    }

    #[test]
    fn links_keep_their_url() {
        let blocks = parse("See [the docs](https://example.com/docs) for details.");
        assert_eq!(blocks.len(), 1);
        match &blocks[0] {
            Block::Paragraph { segments } => {
                assert!(segments.contains(&InlineSegment::Link {
                    text: "the docs".into(),
                    url: "https://example.com/docs".into(),
                }));
            }
            other => panic!("expected a paragraph, got {other:?}"),
        }
    }

    #[test]
    fn hard_breaks_become_newlines_inside_paragraphs() {
        // Two trailing spaces form a CommonMark hard break.
        let blocks = parse("first line  \nsecond line");
        assert_eq!(blocks.len(), 1);
        match &blocks[0] {
            Block::Paragraph { segments } => {
                assert!(segments.contains(&InlineSegment::Text("\n".into())));
            }
            other => panic!("expected a paragraph, got {other:?}"),
        }
    }

    #[test]
    fn tables_collect_header_cells_and_rows() {
        let blocks = parse(
            "| 层 | Crates |\n|---|---|\n| Layer 0 | disco-domain |\n| Layer 1 | disco-kernel |",
        );
        assert_eq!(blocks.len(), 1);
        match &blocks[0] {
            Block::Table {
                header,
                rows,
                alignments,
            } => {
                assert_eq!(header.len(), 2);
                assert_eq!(header[0], vec![InlineSegment::Text("层".into())]);
                assert_eq!(header[1], vec![InlineSegment::Text("Crates".into())]);
                assert_eq!(rows.len(), 2);
                assert_eq!(rows[0].len(), 2);
                assert_eq!(rows[1][1], vec![InlineSegment::Text("disco-kernel".into())]);
                assert_eq!(alignments.len(), 2);
            }
            other => panic!("expected a table, got {other:?}"),
        }
    }

    #[test]
    fn table_cells_keep_inline_formatting() {
        let blocks = parse("| **name** | `cmd` |\n|---|---|\n| a | b |");
        assert_eq!(blocks.len(), 1);
        match &blocks[0] {
            Block::Table { header, .. } => {
                assert_eq!(header[0], vec![InlineSegment::Bold("name".into())]);
                assert_eq!(header[1], vec![InlineSegment::Code("cmd".into())]);
            }
            other => panic!("expected a table, got {other:?}"),
        }
    }

    #[gpui::test]
    fn long_paragraphs_wrap_within_the_available_width(cx: &mut gpui::TestAppContext) {
        let cx = cx.add_empty_window();
        let palette = AppAppearance::for_window(WindowAppearance::Light);
        let text = "这是一段足够长的分析文本，用来验证段落会在给定宽度内自动换行。 ".repeat(12);
        cx.draw(
            point(gpui::px(0.), gpui::px(0.)),
            size(gpui::px(400.), gpui::px(4000.)),
            |_, _| {
                gpui::div()
                    .debug_selector(|| "markdown-root".to_string())
                    .child(render_markdown(&text, palette))
            },
        );
        let bounds = cx
            .debug_bounds("markdown-root")
            .expect("the markdown root should have been painted");
        // One unwrapped line measures ~22px; wrapped text over 400px is far taller.
        assert!(
            bounds.size.height > gpui::px(120.),
            "expected the paragraph to wrap, but it measured {:?}",
            bounds.size
        );
    }

    #[gpui::test]
    fn markdown_wraps_inside_the_chat_container_chain(cx: &mut gpui::TestAppContext) {
        let cx = cx.add_empty_window();
        let palette = AppAppearance::for_window(WindowAppearance::Light);
        let text = "这是一段足够长的分析文本，用来验证段落会在给定宽度内自动换行。 ".repeat(12);
        // Mirrors the fixed chat page: the scroll region hands the column a
        // concrete pixel width (Render::render computes it from the viewport),
        // because scroll children measure against unbounded width. The scroll
        // container itself is skipped here: its stateful scroll listener needs
        // a view entity that element-level test drawing does not provide.
        cx.draw(
            point(gpui::px(0.), gpui::px(0.)),
            size(gpui::px(900.), gpui::px(700.)),
            |_, _| {
                gpui::div()
                    .w(gpui::px(900.))
                    .h(gpui::px(700.))
                    .px(gpui::px(28.))
                    .py(gpui::px(20.))
                    .flex()
                    .flex_col()
                    .child(
                        gpui::div()
                            .w(gpui::px(760.))
                            .mx_auto()
                            .flex()
                            .flex_col()
                            .gap(gpui::px(32.))
                            .child(
                                gpui::div()
                                    .min_w(gpui::px(0.))
                                    .w_full()
                                    .flex()
                                    .flex_col()
                                    .gap(gpui::px(8.))
                                    .child(
                                        gpui::div()
                                            .debug_selector(|| "chat-markdown".to_string())
                                            .child(render_markdown(&text, palette)),
                                    ),
                            ),
                    )
            },
        );
        let bounds = cx
            .debug_bounds("chat-markdown")
            .expect("the markdown block should have been painted");
        assert!(
            bounds.size.height > gpui::px(120.),
            "expected the paragraph to wrap inside the chat chain, but it measured {:?}",
            bounds.size
        );
    }
}
