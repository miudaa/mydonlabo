# 寿司ガチャのお祝い文字を、フォントから SVG（アウトライン化した画像）にするスクリプト
# フォントのファイル自体はサイトに置かず、文字の形だけを画像にして使います。
# 使い方: python make_gacha_text.py <大江戸勘亭流.otf> <スーラ.otf> <出力フォルダ>
import sys
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.transformPen import TransformPen

def layout(font_path, lines, line_gap=1.08, track=0.0):
    f = TTFont(font_path); gs = f.getGlyphSet(); cmap = f.getBestCmap(); upm = f['head'].unitsPerEm
    paths, minx, miny, maxx, maxy = [], 1e9, 1e9, -1e9, -1e9
    widths = []
    for line in lines:
        w = sum(f['hmtx'][cmap[ord(c)]][0] for c in line) + track * upm * (len(line) - 1)
        widths.append(w)
    W = max(widths)
    for li, line in enumerate(lines):
        x = (W - widths[li]) / 2; y = li * upm * line_gap
        for c in line:
            g = cmap[ord(c)]
            # 位置と上下反転を座標そのものに焼き込む（グラデーションの向きがずれないように）
            pen = SVGPathPen(gs, ntos=lambda v: f'{v:.0f}'); gs[g].draw(TransformPen(pen, (1, 0, 0, -1, x, y))); d = pen.getCommands()
            bp = BoundsPen(gs); gs[g].draw(bp)
            if d:
                paths.append(f'<path d="{d}"/>')
                if bp.bounds:
                    a, b, c2, d2 = bp.bounds
                    minx, maxx = min(minx, x + a), max(maxx, x + c2); miny, maxy = min(miny, y - d2), max(maxy, y - b)
            x += f['hmtx'][g][0] + track * upm
    return ''.join(paths), (minx, miny, maxx, maxy), upm

def svg(font_path, lines, out, kind):
    body, (x0, y0, x1, y1), upm = layout(font_path, lines, 1.05 if kind == 'title' else 1.35, -0.02 if kind == 'title' else 0.02)
    if kind == 'title':
        o, m = upm * 0.17, upm * 0.085            # 外側の黒・内側の茶の縁取りの太さ
        defs = ('<linearGradient id="g" x1="0" y1="0" x2="0" y2="1">'
                '<stop offset=".1" stop-color="#fffbd0"/><stop offset=".34" stop-color="#ffe14a"/><stop offset=".55" stop-color="#ffb21e"/>'
                '<stop offset=".75" stop-color="#ff8a0a"/><stop offset="1" stop-color="#d4520a"/></linearGradient>')
        layers = (f'<g fill="#140700" stroke="#140700" stroke-width="{o*2:.0f}" stroke-linejoin="round">{body}</g>'
                  f'<g fill="#b54a06" stroke="#b54a06" stroke-width="{m*2:.0f}" stroke-linejoin="round">{body}</g>'
                  f'<g fill="url(#g)" stroke="#fff3b0" stroke-width="{upm*0.012:.0f}">{body}</g>')
        pad = o * 1.1
        # グラデーションは1行の高さ（1.05em）ごとに繰り返す。複数行でも各行が同じ色の並びになる
        defs = defs.replace('<linearGradient id="g" x1="0" y1="0" x2="0" y2="1">',
                            f'<linearGradient id="g" gradientUnits="userSpaceOnUse" x1="0" y1="{-upm*0.9:.0f}" x2="0" y2="{upm*0.15:.0f}" spreadMethod="repeat">')
    else:
        o = upm * 0.11
        defs = ''
        layers = (f'<g fill="#a8440b" stroke="#a8440b" stroke-width="{o*2:.0f}" stroke-linejoin="round">{body}</g>'
                  f'<g fill="#ffffff">{body}</g>')
        pad = o * 1.1
    vb = f'{x0-pad:.0f} {y0-pad:.0f} {x1-x0+pad*2:.0f} {y1-y0+pad*2:.0f}'
    open(out, 'w', encoding='utf-8').write(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vb}"><defs>{defs}</defs>{layers}</svg>')
    print(out, vb)

if __name__ == '__main__':
    head, body, outdir = sys.argv[1], sys.argv[2], sys.argv[3].rstrip('/')
    svg(head, ['まぐろたたき納豆'], f'{outdir}/gacha_title.svg', 'title')
    svg(head, ['まぐろ', 'たたき', '納豆'], f'{outdir}/gacha_title_v.svg', 'title')
    svg(body, ['寿司ガチャ 0.5% 大当たり！'], f'{outdir}/gacha_sub.svg', 'sub')
    svg(body, ['おめでとうございます！', '200回に1回のレアネタを引き当てました'], f'{outdir}/gacha_msg.svg', 'sub')
