#!/usr/bin/env python3
"""Builds the account-icon auto-association review table (Excel + PDF).

Input : build/icon_table/manifest.json + png/ (from tool/export_icon_table.dart)
Output: build/icon_table/帐屿-资产账户图标自动关联表.xlsx / .pdf

Requires openpyxl + Pillow on PYTHONPATH and a CJK TrueType font for the PDF:
  PYTHONPATH=<site> python3 tool/build_icon_table.py \
      --font-regular NotoSansSC-500.ttf --font-bold NotoSansSC-700.ttf
"""

from __future__ import annotations

import argparse
import json
import pathlib
from datetime import datetime

from openpyxl import Workbook
from openpyxl.drawing.image import Image as XlImage
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter
from openpyxl.worksheet.datavalidation import DataValidation
from PIL import Image, ImageDraw, ImageFont

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "build" / "icon_table"
TITLE = "帐屿-资产账户图标自动关联表"

OPINIONS = "✓ 正确,✗ 关联错误,↺ 换图标,＋ 补充关键词,－ 删除关键词,？ 待确认"

HEADER_FILL = PatternFill("solid", fgColor="E3F2F1")
INPUT_FILL = PatternFill("solid", fgColor="FFF8E1")
WARN_FILL = PatternFill("solid", fgColor="FDECEA")
THIN = Side(style="thin", color="D0D7DE")
BORDER = Border(left=THIN, right=THIN, top=THIN, bottom=THIN)
WRAP = Alignment(wrap_text=True, vertical="center")
CENTER = Alignment(horizontal="center", vertical="center", wrap_text=True)

ICON_PX = 36
ROW_PT = 32


def intro_lines(m: dict) -> list[tuple[str, str]]:
    rules = m["rules"]
    shadowed = sum(1 for r in rules if r["note"].startswith("⚠"))
    return [
        ("h", TITLE),
        ("p", f"生成时间：{m['generated_at'][:19].replace('T', ' ')}　　数据直接取自应用源码与真实渲染效果，图标即 App 内显示效果。"),
        ("h2", "一、自动关联是怎么工作的"),
        ("p", "新建/编辑账户时，如果你没有手动选择图标，App 会按账户名称自动挑一个图标。判断顺序如下（命中即停止）："),
        ("p", "1）手动上传的图片 / 文字徽章 / 手动选择的图标 —— 永远优先，不会被自动关联覆盖。"),
        ("p", "2）A 层「机构矢量图标」：名称里出现 18 家已审校银行的全称/简称/英文代码，或 微信、支付宝、抖音、小红书 → 显示对应品牌行标。"),
        ("p", "3）B 层「通用预设图标」：按 花呗、白条、余额宝、现金、公积金、公交卡 等关键词 → 显示通用彩色图标；名称含「银行/储蓄/工资卡」等兜底为银行卡图标。"),
        ("p", "4）都没命中 → 按账户类型兜底（资金账户=银行卡，信用账户=信用卡，借贷=借入/借出）。"),
        ("h2", "二、A 层的排除规则（这些名称不会被识别成银行）"),
        ("p", "· 花呗、白条、先享后付、信用购、借呗、微粒贷、金条、美团月付 → 保留各自专属信用图标。"),
        ("p", "· 余额宝 → 保留理财图标（除非名称里明确写了银行）。"),
        ("p", "· 含 保险/保单/车险/寿险/重疾险/医疗险/年金，且没有 银行/卡 等字样 → 保留保险图标（如「平安保险」不会变成平安银行）。"),
        ("p", "· 含 证券/基金/股票/定投/ETF，且没有 银行/卡 等字样 → 保留股票基金图标（如「招商证券」「华夏基金」）。"),
        ("p", "· 借贷账户不做机构识别。银行卡备忘页只识别银行，不识别支付/社交钱包。"),
        ("h2", "三、表格说明"),
        ("p", f"· 「自动关联规则」：共 {len(rules)} 条触发关键词。每行用「测试示例名称」真实跑一遍，展示 App 实际显示的图标。"
              f"其中 {shadowed} 条标红「被更高优先级规则覆盖」，表示这个关键词实际由更前面的规则决定图标（多为 B 层银行兜底词被 A 层品牌行标接管，属正常现象）。"),
        ("p", f"· 「银行图标库」：共 {len(m['banks'])} 款银行行标。前 18 款「已审校」参与自动关联，其余为扩展库，只能在选图标时手动搜索。"),
        ("p", f"· 「通用与支付图标」：共 {len(m['general'])} 款支付/社交/账户类型矢量图标与系统预设图标，可作为替换候选。"),
        ("h2", "四、怎么反馈"),
        ("p", "在黄色的「你的意见」列下拉选择（正确 / 关联错误 / 换图标 / 补充关键词 / 删除关键词），在「应改为」列写明想要的效果，"
              "例如：「应显示中国银行行标」「换成 银行图标库 第 35 行」「补充关键词：邮政卡」。改好后把文件发回或直接告诉我行号即可。"),
    ]


# ---------------------------------------------------------------- Excel ----


def style_header(ws, headers: list[str], widths: list[float]) -> None:
    for col, (h, w) in enumerate(zip(headers, widths), start=1):
        c = ws.cell(row=1, column=col, value=h)
        c.font = Font(bold=True)
        c.fill = HEADER_FILL
        c.alignment = CENTER
        c.border = BORDER
        ws.column_dimensions[get_column_letter(col)].width = w
    ws.row_dimensions[1].height = 24
    ws.freeze_panes = "C2"


def add_icon(ws, png: str, cell: str) -> None:
    img = XlImage(str(OUT / "png" / png))
    img.width = ICON_PX
    img.height = ICON_PX
    ws.add_image(img, cell)


def color_cell(cell, hex_color: str) -> None:
    rgb = hex_color.lstrip("#").upper()[-6:]
    cell.value = f"#{rgb}"
    cell.fill = PatternFill("solid", fgColor=rgb)
    r, g, b = (int(rgb[i : i + 2], 16) for i in (0, 2, 4))
    cell.font = Font(color="FFFFFF" if (r * 299 + g * 587 + b * 114) / 1000 < 150 else "000000", size=9)
    cell.alignment = CENTER


def write_table(ws, headers, widths, rows, icon_col: int, opinion_cols: tuple[int, int], fill_row) -> None:
    style_header(ws, headers, widths)
    dv = DataValidation(type="list", formula1=f'"{OPINIONS}"', allow_blank=True)
    ws.add_data_validation(dv)
    for i, row in enumerate(rows, start=2):
        ws.row_dimensions[i].height = ROW_PT
        fill_row(ws, i, row)
        for col in range(1, len(headers) + 1):
            c = ws.cell(row=i, column=col)
            c.border = BORDER
            if c.alignment is None or not c.alignment.wrap_text:
                c.alignment = WRAP
        add_icon(ws, row["png"], f"{get_column_letter(icon_col)}{i}")
        for col in opinion_cols:
            ws.cell(row=i, column=col).fill = INPUT_FILL
        dv.add(f"{get_column_letter(opinion_cols[0])}{i}")
    last = get_column_letter(len(headers))
    ws.auto_filter.ref = f"A1:{last}{len(rows) + 1}"


def build_xlsx(m: dict, path: pathlib.Path) -> None:
    wb = Workbook()
    intro = wb.active
    intro.title = "说明"
    intro.column_dimensions["A"].width = 120
    for r, (kind, text) in enumerate(intro_lines(m), start=1):
        c = intro.cell(row=r, column=1, value=text)
        c.alignment = Alignment(wrap_text=True, vertical="top")
        if kind == "h":
            c.font = Font(bold=True, size=16)
            intro.row_dimensions[r].height = 28
        elif kind == "h2":
            c.font = Font(bold=True, size=12, color="00695C")
            intro.row_dimensions[r].height = 22
        else:
            intro.row_dimensions[r].height = 18 * max(1, len(text) // 70 + 1)

    rules_ws = wb.create_sheet("自动关联规则")

    def fill_rule(ws, i, r):
        vals = [r["no"], None, r["keyword"], r["sample"], r["actual_name"], r["layer"], r["account_type"],
                r["target_name"], r["actual_key"], None, r["note"], None, None]
        for col, v in enumerate(vals, start=1):
            if v is not None:
                ws.cell(row=i, column=col, value=v)
        ws.cell(row=i, column=1).alignment = CENTER
        color_cell(ws.cell(row=i, column=10), r["color"])
        if r["note"].startswith("⚠"):
            ws.cell(row=i, column=11).fill = WARN_FILL

    write_table(
        rules_ws,
        ["序号", "实际图标", "触发关键词", "测试示例名称", "实际显示", "规则层级", "账户类型",
         "规则目标图标", "图标标识", "颜色", "备注", "你的意见", "应改为"],
        [6, 9, 14, 16, 16, 30, 10, 16, 30, 10, 40, 14, 28],
        m["rules"], icon_col=2, opinion_cols=(12, 13), fill_row=fill_rule,
    )

    banks_ws = wb.create_sheet("银行图标库")

    def fill_bank(ws, i, b):
        vals = [b["no"], None, b["name"], b["kind"], b["aliases"], b["key"], None, None, None]
        for col, v in enumerate(vals, start=1):
            if v is not None:
                ws.cell(row=i, column=col, value=v)
        ws.cell(row=i, column=1).alignment = CENTER
        color_cell(ws.cell(row=i, column=7), b["color"])

    write_table(
        banks_ws,
        ["序号", "图标", "名称", "分类", "别名 / 搜索词", "图标标识", "默认颜色", "你的意见", "应改为"],
        [6, 9, 22, 20, 30, 34, 10, 14, 28],
        m["banks"], icon_col=2, opinion_cols=(8, 9), fill_row=fill_bank,
    )

    gen_ws = wb.create_sheet("通用与支付图标")

    def fill_gen(ws, i, g):
        vals = [g["no"], None, g["name"], g["kind"], g["aliases"], g["key"], None, None, None]
        for col, v in enumerate(vals, start=1):
            if v is not None:
                ws.cell(row=i, column=col, value=v)
        ws.cell(row=i, column=1).alignment = CENTER
        color_cell(ws.cell(row=i, column=7), g["color"])

    write_table(
        gen_ws,
        ["序号", "图标", "名称", "分类", "别名 / 搜索词", "图标标识", "默认颜色", "你的意见", "应改为"],
        [6, 9, 20, 22, 30, 30, 10, 14, 28],
        m["general"], icon_col=2, opinion_cols=(8, 9), fill_row=fill_gen,
    )
    wb.save(path)


# ------------------------------------------------------------------ PDF ----

PAGE_W, PAGE_H = 1240, 1754  # A4 @150dpi
MARGIN = 60


class Pdf:
    def __init__(self, regular: str, bold: str):
        self.f = {
            "body": ImageFont.truetype(regular, 20),
            "small": ImageFont.truetype(regular, 17),
            "head": ImageFont.truetype(bold, 20),
            "h1": ImageFont.truetype(bold, 36),
            "h2": ImageFont.truetype(bold, 26),
        }
        self.pages: list[Image.Image] = []
        self.new_page()

    def new_page(self):
        self.page = Image.new("RGB", (PAGE_W, PAGE_H), "white")
        self.draw = ImageDraw.Draw(self.page)
        self.pages.append(self.page)
        self.y = MARGIN

    def wrap(self, text: str, font, width: int) -> list[str]:
        lines, cur = [], ""
        for ch in text:
            if ch == "\n":
                lines.append(cur)
                cur = ""
                continue
            if self.draw.textlength(cur + ch, font=font) > width and cur:
                lines.append(cur)
                cur = ch
            else:
                cur += ch
        lines.append(cur)
        return lines

    def paragraph(self, text: str, font_key="body", color="#1F2937", gap=8):
        font = self.f[font_key]
        lh = int(font.size * 1.5)
        for line in self.wrap(text, font, PAGE_W - 2 * MARGIN):
            if self.y + lh > PAGE_H - MARGIN:
                self.new_page()
            self.draw.text((MARGIN, self.y), line, font=font, fill=color)
            self.y += lh
        self.y += gap

    def table(self, title: str, cols: list[tuple[str, int, str]], rows: list[dict], cell_fn):
        """cols: (header, width, key) — key '__icon__' renders the png."""
        self.new_page()
        self.paragraph(title, "h2", "#00695C", gap=12)
        self.header(cols)
        for row in rows:
            cells = cell_fn(row)
            wrapped = [
                self.wrap(str(cells.get(key, "")), self.f["small"], w - 14) if key != "__icon__" else []
                for (_, w, key) in cols
            ]
            lh = int(self.f["small"].size * 1.4)
            h = max(64, max(len(x) for x in wrapped) * lh + 16)
            if self.y + h > PAGE_H - MARGIN:
                self.new_page()
                self.header(cols)
            x = MARGIN
            warn = str(cells.get("note", "")).startswith("⚠")
            for (header, w, key), lines in zip(cols, wrapped):
                fill = "#FDECEA" if warn and key == "note" else "white"
                self.draw.rectangle([x, self.y, x + w, self.y + h], fill=fill, outline="#D0D7DE")
                if key == "__icon__":
                    icon = Image.open(OUT / "png" / row["png"]).convert("RGBA").resize((52, 52), Image.LANCZOS)
                    self.page.paste(icon, (x + (w - 52) // 2, self.y + (h - 52) // 2), icon)
                else:
                    ty = self.y + (h - len(lines) * lh) // 2
                    for line in lines:
                        self.draw.text((x + 7, ty), line, font=self.f["small"], fill="#1F2937")
                        ty += lh
                x += w
            self.y += h

    def header(self, cols):
        x = MARGIN
        for header, w, _ in cols:
            self.draw.rectangle([x, self.y, x + w, self.y + 40], fill="#E3F2F1", outline="#D0D7DE")
            self.draw.text((x + 7, self.y + 9), header, font=self.f["head"], fill="#0F3D3A")
            x += w
        self.y += 40

    def save(self, path: pathlib.Path):
        total = len(self.pages)
        for i, p in enumerate(self.pages, start=1):
            d = ImageDraw.Draw(p)
            label = f"{TITLE}　第 {i} / {total} 页"
            d.text((MARGIN, PAGE_H - MARGIN + 18), label, font=self.f["small"], fill="#6B7280")
        self.pages[0].save(path, save_all=True, append_images=self.pages[1:], resolution=150)


def build_pdf(m: dict, path: pathlib.Path, regular: str, bold: str) -> None:
    pdf = Pdf(regular, bold)
    for kind, text in intro_lines(m):
        if kind == "h":
            pdf.paragraph(text, "h1", "#0F3D3A", gap=16)
        elif kind == "h2":
            pdf.y += 8
            pdf.paragraph(text, "h2", "#00695C", gap=6)
        else:
            pdf.paragraph(text)

    pdf.table(
        "自动关联规则（输入名称 → 实际显示）",
        [("序号", 70, "no"), ("图标", 90, "__icon__"), ("触发关键词", 170, "keyword"),
         ("实际显示", 170, "actual_name"), ("规则层级", 280, "layer"), ("备注", 340, "note")],
        m["rules"],
        lambda r: r,
    )
    pdf.table(
        "银行图标库",
        [("序号", 70, "no"), ("图标", 90, "__icon__"), ("名称", 250, "name"),
         ("分类", 220, "kind"), ("别名 / 搜索词", 490, "aliases")],
        m["banks"],
        lambda r: r,
    )
    pdf.table(
        "通用与支付图标",
        [("序号", 70, "no"), ("图标", 90, "__icon__"), ("名称", 250, "name"),
         ("分类", 280, "kind"), ("别名 / 搜索词", 430, "aliases")],
        m["general"],
        lambda r: r,
    )
    pdf.save(path)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--font-regular", required=True)
    ap.add_argument("--font-bold", required=True)
    args = ap.parse_args()
    manifest = json.loads((OUT / "manifest.json").read_text(encoding="utf-8"))
    xlsx = OUT / f"{TITLE}.xlsx"
    pdf = OUT / f"{TITLE}.pdf"
    build_xlsx(manifest, xlsx)
    build_pdf(manifest, pdf, args.font_regular, args.font_bold)
    print(xlsx, xlsx.stat().st_size)
    print(pdf, pdf.stat().st_size)


if __name__ == "__main__":
    main()
