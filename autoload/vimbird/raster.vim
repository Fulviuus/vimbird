vim9script

import './glyphs.vim'
import './png.vim'

const GLYPH_HEIGHT = 5
const GLYPH_WIDTH = 4

def ColorPairs(): list<list<number>>
  var table: list<list<number>> = [[]]
  for color in range(1, 15)
    var pixels: list<number> = []
    for bits in range(16)
      var pair = 0
      for shift in [3, 2, 1, 0]
        pair = (pair << 4) + (and(bits >> shift, 1) * color)
      endfor
      pixels->add(pair)
    endfor
    table->add(pixels)
  endfor
  return table
enddef

const color_pairs = ColorPairs()

def RGB(color: number): list<number>
  return [color >> 16, and(color >> 8, 255), and(color, 255)]
enddef

def PaletteIndex(palette: list<number>, rgb: number): number
  var existing = index(palette, rgb)
  if existing >= 0
    return existing + 1
  endif
  if len(palette) < 15
    palette->add(rgb)
    return len(palette)
  endif
  var target = RGB(rgb)
  var closest = 0
  var best_distance = 3 * 256 * 256
  for index in range(len(palette))
    var candidate = RGB(palette[index])
    var distance = 0
    for channel in range(3)
      var delta = candidate[channel] - target[channel]
      distance += delta * delta
    endfor
    if distance < best_distance
      best_distance = distance
      closest = index
    endif
  endfor
  return closest + 1
enddef

def SyntaxColor(colors: dict<any>, lnum: number, byte_col: number): number
  var group = string(synID(lnum, byte_col, true))
  if !has_key(colors.groups, group)
    var foreground = synIDattr(synIDtrans(str2nr(group)), 'fg#', 'gui')
    colors.groups[group] = foreground =~# '^#[0-9a-fA-F]\{6}$'
      ? PaletteIndex(colors.palette, str2nr(foreground[1 :], 16))
      : 1
  endif
  return colors.groups[group]
enddef

export def Bands(rows: number, pixels_per_row: number): number
  var density = max([1, get(g:, 'vimbird_lines_per_cell', 6)])
  return rows * min([density, pixels_per_row / 3])
enddef

# A number holds one byte of each of the five scanlines for two glyphs.
# Composing glyphs this way avoids painting each pixel in Vim script.
def Paint(text: string, columns: number, tabstop: number, row: blob, stride: number, colors: dict<any>, lnum: number, shifts: list<number>)
  var colored = colors.enabled
  var atlas = glyphs.atlases[len(shifts)]
  var bytes = colored ? [] : repeat([0], (columns + 1) / 2)
  var x = 0
  var byte_col = 1
  for char in str2list(text)
    var ascii = char < 128
    var utf = ascii ? '' : nr2char(char)
    if char == 9
      x += tabstop - x % tabstop
    elseif char == 32
      x += 1
    else
      var glyph = atlas[ascii ? char : 63]
      if colored
        var pairs = color_pairs[SyntaxColor(colors, lnum, byte_col)]
        var offset = 1 + x * 2
        for shift in shifts
          var pair = pairs[and(glyph >> shift, 15)]
          row[offset] = pair >> 8
          row[offset + 1] = and(pair, 255)
          offset += stride
        endfor
      else
        bytes[x / 2] += glyph << (x % 2 == 0 ? 4 : 0)
      endif
      x += ascii ? 1 : strdisplaywidth(utf, x)
    endif
    byte_col += ascii ? 1 : strlen(utf)
    if x >= columns
      break
    endif
  endfor
  var offset = 1
  for packed in bytes
    var dest = offset
    for shift in shifts
      row[dest] = and(packed >> shift, 255)
      dest += stride
    endfor
    offset += 1
  endfor
enddef

var cache_key: list<any> = []
var cached_lines: dict<any> = {}
var blank_bands: dict<list<any>> = {}
var cache_colors: dict<any> = {}

export def Render(first_line: number, width: number, rows: number, pixels_per_row: number, ink: number, identity: list<any> = [], overview_count: number = 0): blob
  var colored = has('syntax_items')
  var depth = colored ? 4 : 1
  var stride = 1 + (width * depth + 7) / 8
  var columns = width / GLYPH_WIDTH
  var bands = Bands(rows, pixels_per_row)
  var tabstop = &l:tabstop
  var key = [bufnr(), b:changedtick, colored, width, rows, pixels_per_row, ink, bands, tabstop, overview_count] + identity
  if cache_key != key
    cache_key = key
    cached_lines = {}
    blank_bands = {}
    cache_colors = {enabled: colored, groups: {'0': 1}, palette: [ink]}
  endif
  # The palette remains stable while scrolling, so cached pixels keep their
  # color indices. Retain at most one extra screen on either side.
  for lnum in keys(cached_lines)
    var line = str2nr(lnum)
    if overview_count == 0 && (line < first_line - bands || line >= first_line + bands * 2)
      remove(cached_lines, lnum)
    endif
  endfor
  var last_line = line('$')
  var ink_rows = min([GLYPH_HEIGHT, rows * pixels_per_row / bands - 1])
  var shifts = map(range(ink_rows), (_, y) => 8 * (ink_rows - 1 - y))
  var blocks: list<list<any>> = []
  for band in range(bands)
    var height = (band + 1) * rows * pixels_per_row / bands - band * rows * pixels_per_row / bands
    var lnum = first_line + band
    if overview_count > bands
      var first = band * overview_count / bands + 1
      var last = (band + 1) * overview_count / bands
      lnum = (first + last) / 2
    endif
    var line_key = string(lnum)
    var block = get(cached_lines, line_key, [])
    if !has_key(cached_lines, line_key) && lnum <= last_line
      var text = getline(lnum)
      if !empty(text)
        var pixels = repeat(0z00, stride * ink_rows)
        Paint(strpart(text, 0, columns * 4), columns, tabstop, pixels, stride, cache_colors, lnum, shifts)
        block = png.Band(pixels)
      endif
      cached_lines[line_key] = block
    endif
    if !empty(block)
      blocks->add(block)
      height -= ink_rows
    endif
    # Separate padding keeps the glyph block reusable even when moving
    # between bands whose heights differ by one physical pixel.
    var height_key = string(height)
    if !has_key(blank_bands, height_key)
      blank_bands[height_key] = png.Band(repeat(0z00, height * stride))
    endif
    blocks->add(blank_bands[height_key])
  endfor
  var palette = 0z
  for rgb in cache_colors.palette
    palette += list2blob(RGB(rgb))
  endfor
  return png.Encode(width, rows * pixels_per_row, palette, blocks, depth)
enddef
