vim9script

import './vimbird/kitty.vim'
import './vimbird/raster.vim'
import './vimbird/markers.vim'

const PIXELS_PER_COL = 12
const MAX_WIDTH = 40
const EDIT_IDLE_MS = 75
# Kitty associates placeholders with a 24-bit image ID encoded as RGB.
const image_id = 0x010000 + rand() % 0xfe0000
var uploaded: list<any> = []
var uploaded_image = 0z
var palette_revision = 0
var refresh_revision = 0
var last_frame: dict<any> = {}
var appearance: list<any> = []
var last_edit: list<any> = []
var update_timer = -1
var frame_timer = -1

def Report(message: string)
  echohl WarningMsg
  echomsg 'Vimbird: ' .. message
  echohl None
enddef

def Highlights()
  execute printf('highlight VimbirdPixels guifg=#%06x guibg=NONE gui=NONE', image_id)
  var background = Background()
  var ink = Ink()
  var accent = background >= 0 ? Mix(background, ink, 28) : ink
  var bg = background >= 0 ? printf('#%06x', background) : 'NONE'
  execute printf('highlight VimbirdSeparator guifg=#%06x guibg=%s gui=NONE', accent, bg)
  var track = background >= 0 ? accent : 0x777777
  execute printf('highlight VimbirdViewport guifg=#%06x guibg=#%06x gui=NONE', track, track)
  var opacity = min([30, max([0, get(g:, 'vimbird_viewport_opacity', 12)])])
  var tint = background >= 0 ? printf('#%06x', Mix(background, ink, opacity)) : 'NONE'
  # The transparent parts of the PNG expose this cell background. The RGB
  # foreground still identifies the cached image and preserves glyph colors.
  execute printf('highlight VimbirdViewportPixels guifg=#%06x guibg=%s gui=NONE', image_id, tint)
  var search_color = HighlightColor('Search', 'bg', ink)
  var marker = background >= 0 ? Mix(background, search_color, 75) : search_color
  execute printf('highlight VimbirdSearch guibg=#%06x gui=NONE', marker)
  for [group, theme, fallback] in [
    ['VimbirdGitAdd', 'GitGutterAdd', 0x45a974],
    ['VimbirdGitChange', 'GitGutterChange', 0x638de0],
    ['VimbirdGitDelete', 'GitGutterDelete', 0xd76a70],
    ['VimbirdQuickfix', 'QuickFixLine', 0x73a6a8],
    ['VimbirdWarning', 'WarningMsg', 0xd6a24a],
    ['VimbirdError', 'ErrorMsg', 0xe06a72],
  ]
    var color = HighlightColor(theme, 'fg', fallback)
    execute printf('highlight %s guibg=#%06x gui=NONE', group, color)
  endfor
  highlight default link VimbirdBackground Normal
enddef

def Mix(background: number, ink: number, opacity: number): number
  var rgb = 0
  for shift in [16, 8, 0]
    var base = and(background >> shift, 255)
    var accent = and(ink >> shift, 255)
    rgb += ((base * (100 - opacity) + accent * opacity + 50) / 100) << shift
  endfor
  return rgb
enddef

def Background(): number
  return HighlightColor('Normal', 'bg', TerminalColor(v:termrbgresp, -1))
enddef

def HighlightColor(group: string, part: string, fallback: number): number
  var color = synIDattr(synIDtrans(hlID(group)), part .. '#', 'gui')
  return color =~# '^#[0-9a-fA-F]\{6}$'
    ? str2nr(color[1 :], 16)
    : fallback
enddef

def TerminalColor(response: string, fallback: number): number
  var channels = matchlist(response, 'rgb:\(\x\+\)/\(\x\+\)/\(\x\+\)')
  if empty(channels)
    return fallback
  endif
  var rgb = 0
  for channel in channels[1 : 3]
    var value = str2nr(channel, 16)
    rgb = (rgb << 8) + (len(channel) == 1 ? value * 17 : value >> (4 * (len(channel) - 2)))
  endfor
  return rgb
enddef

def Ink(): number
  return HighlightColor('Normal', 'fg',
    TerminalColor(v:termrfgresp, &background == 'dark' ? 0xadb7c7 : 0x48556b))
enddef

def PaletteChanged()
  appearance = []
  Request()
enddef

def SourceWindow(win: number): bool
  return win > 0 && win_gettype(win) ==# '' && !getwinvar(win, '&previewwindow')
    && getbufvar(winbufnr(win), '&buftype') ==# ''
enddef

def Release()
  if empty(uploaded)
    return
  endif
  uploaded = []
  uploaded_image = 0z
  silent! kitty.Delete(image_id)
enddef

def Divider(state: dict<any>, visible: bool)
  if !visible
    if state.divider > 0
      popup_close(state.divider)
      state.divider = 0
    endif
    return
  endif
  var [row, col] = win_screenpos(state.win)
  var height = winheight(state.win)
  var glyph = get(g:, 'vimbird_separator', '│')
  if strchars(glyph) != 1 || strdisplaywidth(glyph) != 1
    glyph = ' '
  endif
  var group = get(g:, 'vimbird_separator_highlight', 'VimbirdSeparator')
  if !hlexists(group)
    group = 'VimbirdSeparator'
  endif
  var key = [row, col, height, glyph, group]
  if key == state.divider_key && !empty(popup_getpos(state.divider))
    return
  endif
  # Cover the native split border so its theme attributes cannot paint a
  # bright gutter. Other splits keep their own separator settings.
  var options = {line: row, col: col - 1, minwidth: 1, maxwidth: 1,
    minheight: height, maxheight: height, fixed: true, posinvert: false,
    wrap: false, scrollbar: false, zindex: 1, highlight: group}
  var text = repeat([glyph], height)
  if empty(popup_getpos(state.divider))
    state.divider = popup_create(text, options)
  else
    popup_setoptions(state.divider, options)
    popup_settext(state.divider, text)
  endif
  state.divider_key = key
enddef

def SetTiles(state: dict<any>, columns: number, rows: number)
  if state.tiles == [columns, rows]
    return
  endif
  var buf = state.buf
  setbufvar(buf, '&modifiable', 1)
  try
    var lines = rows > 0 ? kitty.Tiles(columns, rows) : ['']
    setbufline(buf, 1, lines)
    deletebufline(buf, len(lines) + 1, '$')
    win_execute(state.win, 'normal! gg0')
  finally
    setbufvar(buf, '&modifiable', 0)
  endtry
  state.tiles = [columns, rows]
enddef

# Map the editor's progress through the file to the viewport's travel
# through the minimap, then choose the source range that aligns the two.
def PageStart(page: number, first: number, last: number, count: number, capacity: number): number
  if count <= capacity
    return 1
  endif
  var span = last - first + 1
  var offset = (first - 1) * (capacity - span) / (count - span)
  var target = min([count - capacity + 1, first - offset])
  # Hold nearby placements to avoid a bitmap rebuild on each line scroll.
  if first > 1 && last < count && abs(page - target) <= 6 && page <= first && last < page + capacity
    return page
  endif
  return target
enddef

def Viewport(state: dict<any>, rows: number, first: number, last: number, count: number)
  var top = 1 + max([0, first - state.page]) * rows / state.capacity
  var bottom = 1 + min([state.capacity - 1, last - state.page]) * rows / state.capacity
  var track_top = markers.Row(first, rows, count)
  var track_bottom = markers.Row(last, rows, count)
  if state.overview && count > state.capacity
    top = track_top
    bottom = track_bottom
  endif
  var overlay = get(g:, 'vimbird_viewport_highlight', 1)
    && get(g:, 'vimbird_viewport_opacity', 12) > 0 && Background() >= 0
  if state.viewport == [top, bottom, overlay, track_top, track_bottom]
    return
  endif
  if state.match > 0
    matchdelete(state.match, state.win)
  endif
  if state.overlay_match > 0
    matchdelete(state.overlay_match, state.win)
    state.overlay_match = -1
  endif
  var pattern = printf('\%%>%dl\%%<%dl', top - 1, bottom + 1)
  var window = {window: state.win}
  var track = printf('\%%>%dl\%%<%dl\%%1c.', track_top - 1, track_bottom + 1)
  state.match = matchadd('VimbirdViewport', track, 5, -1, window)
  if overlay && top <= bottom
    state.overlay_match = matchadd('VimbirdViewportPixels', pattern .. '\%>1c.', 11, -1, window)
  endif
  state.viewport = [top, bottom, overlay, track_top, track_bottom]
enddef

def FindSearchRows(rows: number, count: number, pattern: string)
  var state = t:vimbird
  var view = winsaveview()
  var started = reltime()
  var positions: list<list<number>> = []
  try
    cursor(1, 1)
    while true
      var remaining = 15 - float2nr(reltimefloat(reltime(started)) * 1000)
      if remaining <= 0
        break
      endif
      var [lnum, _] = searchpos(pattern, 'Wc', 0, remaining)
      if lnum == 0
        break
      endif
      var row = markers.Row(lnum, rows, count)
      state.search_rows[string(row)] = lnum
      positions->add([row, 1, 1])
      var next = row * count / rows + 1
      if next > count
        break
      endif
      cursor(next, 1)
    endwhile
  catch /^Vim/
    # A pending or invalid search pattern has no markers.
  finally
    winrestview(view)
  endtry
  if !empty(positions)
    state.search_match = matchaddpos('VimbirdSearch', positions, 15, -1, {window: state.win})
  endif
enddef

def SearchMarkers(state: dict<any>, rows: number, count: number, buf: number, tick: number)
  var pattern = get(g:, 'vimbird_search_markers', 1) && v:hlsearch ? getreg('/') : ''
  var key = [buf, tick, rows, pattern, &ignorecase, &smartcase, &magic]
  if state.search_key == key
    return
  endif
  state.search_key = key
  state.search_rows = {}
  if state.search_match > 0
    matchdelete(state.search_match, state.win)
    state.search_match = -1
  endif
  if !empty(pattern)
    win_execute(state.source, printf('call %sFindSearchRows(%d, %d, getreg("/"))', expand('<SID>'), rows, count))
  endif
enddef

def DrawInSource(key: list<any>, page: number, force: bool)
  var started = reltime()
  var [_, columns, rows, width, pixel_rows, ink] = key[0 : 5]
  if force
    refresh_revision += 1
  endif
  var image = raster.Render(page, width, rows, pixel_rows, ink,
    [key[6], palette_revision, key[8], refresh_revision], key[-3])
  if force || uploaded[1 : 2] != [columns, rows] || image != uploaded_image
    var build_ms = reltimefloat(reltime(started)) * 1000
    last_frame = kitty.Upload(image_id, image, columns, rows)
    last_frame.build_ms = build_ms
    last_frame.total_ms = reltimefloat(reltime(started)) * 1000
    uploaded_image = image
  endif
  uploaded = key
enddef

def Sync(force: bool = false)
  var state = get(t:, 'vimbird', {})
  if empty(state)
    Release()
    return
  endif
  if winbufnr(state.win) != state.buf
    Close()
    return
  endif
  if SourceWindow(win_getid()) && win_getid() != state.win
    state.source = win_getid()
  endif
  if winnr('$') == 1
    Close()
    return
  endif
  var columns = min([MAX_WIDTH, winwidth(state.win)]) - 1
  var rows = min([kitty.MAX_ROWS, winheight(state.win)])
  if !SourceWindow(state.source) || columns < 1 || rows < 1 || !&termguicolors
    Divider(state, false)
    SetTiles(state, 0, 0)
    Release()
    return
  endif

  # Vim can pick its default dark or light highlights after the terminal
  # answers OSC 11, after an early :Vimbird has already drawn the minimap.
  var current_appearance = [&background, v:termrbgresp, v:termrfgresp]
  if appearance != current_appearance
    appearance = current_appearance
    palette_revision += 1
    Highlights()
  endif
  var opacity = get(g:, 'vimbird_viewport_opacity', 12)
  if state.opacity != opacity
    state.opacity = opacity
    Highlights()
  endif
  Divider(state, true)
  var buf = winbufnr(state.source)
  var count = getbufinfo(buf)[0].linecount
  var cell = exists('*getcellpixels') ? getcellpixels() : []
  var native_size = len(cell) == 2 && cell[0] >= 4 && cell[1] >= 3
  var pixels_per_col = native_size ? cell[0] : PIXELS_PER_COL
  var pixel_rows = native_size ? cell[1] : PIXELS_PER_COL * 2
  var first = max([1, line('w0', state.source)])
  var last = min([count, max([first, line('w$', state.source)])])
  var capacity = raster.Bands(rows, pixel_rows)
  var anchor_first = first
  var anchor_last = last
  if last - first + 1 > capacity
    # Folds can put more source lines in the editor than the minimap fits.
    anchor_first = max([first, line('.', state.source)])
    anchor_last = anchor_first
  endif
  var old_page = state.page_buf == buf && state.capacity == capacity ? state.page : 0
  var overview_count = state.overview && count > capacity ? count : 0
  state.page = overview_count > 0 ? 1 : PageStart(old_page, anchor_first, anchor_last, count, capacity)
  state.capacity = capacity
  state.page_buf = buf
  var ink = Ink()
  var key = [buf, columns, rows, columns * pixels_per_col, pixel_rows, ink, getbufvar(buf, '&tabstop'), state.source,
    palette_revision, getwinvar(state.source, '&syntax'), capacity, overview_count, state.page, getbufvar(buf, 'changedtick')]
  SetTiles(state, columns, rows)
  Viewport(state, rows, first, last, count)
  SearchMarkers(state, rows, count, buf, key[-1])
  markers.RefreshGit(state, buf, Request)
  markers.Draw(state, rows, count, buf)

  if !force && uploaded == key
    return
  endif
  # Wait for a short typing pause before running the syntax engine. Changes
  # to the source, theme, or geometry take effect immediately.
  if !force && !empty(last_edit) && uploaded[0 : -2] == key[0 : -2]
    var remaining = EDIT_IDLE_MS - float2nr(reltimefloat(reltime(last_edit)) * 1000)
    if remaining > 0
      if frame_timer < 0
        frame_timer = timer_start(remaining, Frame)
      endif
      return
    endif
  endif
  if win_getid() == state.source
    DrawInSource(key, state.page, force)
  else
    # synID() reads the syntax rules of the current window.
    win_execute(state.source, printf('call %sDrawInSource(%s, %d, %s)', expand('<SID>'), string(key), state.page, string(force)))
  endif
enddef

def Update(_timer: number)
  update_timer = -1
  try
    Sync()
  catch
    Close()
    Report(v:exception)
  endtry
enddef

def Frame(_timer: number)
  frame_timer = -1
  Request()
enddef

def Request()
  if exists('t:vimbird') && update_timer < 0
    update_timer = timer_start(0, Update)
  endif
enddef

def Edited(buf: number)
  var state = get(t:, 'vimbird', {})
  if !empty(state) && winbufnr(state.source) == buf
    last_edit = reltime()
    Request()
  endif
enddef

def WindowClosed(id: number)
  var state = get(t:, 'vimbird', {})
  if !empty(state) && id == state.win
    markers.Stop(state)
    Divider(state, false)
    unlet t:vimbird
    Release()
  endif
  Request()
enddef

def BeforeQuit()
  var state = get(t:, 'vimbird', {})
  if !empty(state) && win_getid() != state.win && winnr('$') == 2
    Close()
  endif
enddef

def Jump(row: number)
  var state = get(t:, 'vimbird', {})
  if empty(state) || !SourceWindow(state.source) || row < 1 || state.tiles[1] < row
    return
  endif
  var count = line('$', state.source)
  var target = state.overview && count > state.capacity
    ? (2 * row - 1) * count / (2 * state.tiles[1]) + 1
    : state.page + (row - 1) * state.capacity / state.tiles[1]
  GoTo(state.source, target)
enddef

def GoTo(source: number, target: number)
  if SourceWindow(source) && win_gotoid(source)
    cursor(target, 1)
    normal! zz
  endif
enddef

export def Select()
  Jump(line('.'))
enddef

def JumpToSearch(source: number, row: number, rows: number, fallback: number)
  if !SourceWindow(source) || !win_gotoid(source)
    return
  endif
  var count = line('$')
  var first = (row - 1) * count / rows + 1
  var last = row * count / rows
  var center = (first + last) / 2
  var target = fallback
  cursor(center, 1)
  try
    for flags in ['bnWc', 'nWc']
      var [lnum, _] = searchpos(getreg('/'), flags, flags[0] ==# 'b' ? first : last, 5)
      if lnum >= first && lnum <= last && abs(lnum - center) < abs(target - center)
        target = lnum
      endif
    endfor
  catch /^Vim/
    # The cached marker still points at a match from the last completed scan.
  endtry
  GoTo(source, target)
enddef

export def MouseKey(action: string): string
  var state = get(t:, 'vimbird', {})
  var key = action ==# 'click' ? "\<LeftMouse>" : (action ==# 'drag' ? "\<LeftDrag>" : "\<LeftRelease>")
  if empty(state)
    return key
  endif
  var pos = getmousepos()
  if (action ==# 'click' && pos.winid == state.win && pos.winrow <= state.tiles[1])
      || (action !=# 'click' && state.dragging)
    return printf("\<Cmd>call vimbird#Mouse('%s')\<CR>", action)
  endif
  return key
enddef

export def Mouse(action: string)
  var state = get(t:, 'vimbird', {})
  if empty(state)
    return
  endif
  if action ==# 'release'
    state.dragging = false
    return
  endif
  var pos = getmousepos()
  var [top, _] = win_screenpos(state.win)
  var rows = state.tiles[1]
  var row = max([1, min([rows, pos.screenrow - top + 1])])
  if action ==# 'click'
    state.dragging = true
    if pos.wincol > 1
      Jump(row)
      return
    endif
  endif
  if action ==# 'click' && v:hlsearch && has_key(state.search_rows, string(row))
      && state.search_key[3] ==# getreg('/')
    JumpToSearch(state.source, row, rows, state.search_rows[string(row)])
    return
  endif
  var count = line('$', state.source)
  GoTo(state.source, 1 + (row - 1) * (count - 1) / max([1, rows - 1]))
enddef

export def RetryTransport()
  if empty(uploaded)
    return
  endif
  var started = reltime()
  last_frame = kitty.Upload(image_id, uploaded_image, uploaded[1], uploaded[2])
  last_frame.build_ms = 0.0
  last_frame.total_ms = reltimefloat(reltime(started)) * 1000
enddef

export def Stats()
  if empty(last_frame)
    echomsg 'Vimbird has not uploaded a frame'
    return
  endif
  echomsg printf('Vimbird last frame %.2f ms | raster and PNG %.2f ms | prepare %.2f ms | terminal write %.2f ms | %d bytes (%s)',
    last_frame.total_ms, last_frame.build_ms, last_frame.encode_ms, last_frame.write_ms, last_frame.bytes, last_frame.medium)
enddef

def RefreshMarkers()
  var state = get(t:, 'vimbird', {})
  if !empty(state)
    markers.RefreshGit(state, winbufnr(state.source), Request, true)
    Request()
  endif
enddef

export def Overview()
  if !exists('t:vimbird')
    Open()
  endif
  if exists('t:vimbird')
    t:vimbird.overview = !t:vimbird.overview
    Request()
  endif
enddef

def SetupEvents()
  augroup Vimbird
    autocmd!
    autocmd WinEnter,BufWinEnter,TabEnter,VimResized,WinScrolled,CursorMoved,CursorMovedI,CmdlineLeave * Request()
    autocmd BufWritePost,FocusGained * RefreshMarkers()
    autocmd QuickFixCmdPost * Request()
    autocmd TextChanged,TextChangedI,TextChangedP * Edited(str2nr(expand('<abuf>')))
    autocmd OptionSet tabstop,termguicolors,hlsearch,ignorecase,smartcase,magic Request()
    autocmd OptionSet background PaletteChanged()
    autocmd TermResponseAll osc,background,foreground Request()
    autocmd ColorScheme,Syntax * PaletteChanged()
    autocmd WinClosed * WindowClosed(str2nr(expand('<amatch>')))
    autocmd QuitPre * BeforeQuit()
    autocmd TabLeave,VimLeavePre,VimSuspend * Release()
    autocmd VimResume * Request()
  augroup END
enddef

export def Open()
  if exists('t:vimbird')
    return
  endif
  if !has('unix') || has('gui_running') || !exists('*base64_encode') || !has('timers') || !has('popupwin') || !has('num64') || &encoding !=# 'utf-8'
    Report('requires 64-bit terminal Vim 9.1+ with base64_encode(), timers, popup windows and UTF-8')
    return
  endif
  if $VIMBIRD_KITTY !=# '1' && &term !~# 'kitty\|ghostty' && $TERM_PROGRAM !=# 'ghostty'
    Report('requires a terminal that supports Kitty graphics Unicode placements')
    return
  endif
  if !empty($TMUX) || !empty($STY)
    Report('requires a direct terminal session')
    return
  endif
  if !&termguicolors || strdisplaywidth(nr2char(0x10eeee)) != 1
    Report('enable termguicolors and use single-width Unicode placeholders')
    return
  endif
  var source = win_getid()
  if !SourceWindow(source)
    Report('open the minimap from a file window')
    return
  endif
  var width = min([MAX_WIDTH, max([3, get(g:, 'vimbird_width', 18)])])
  if &columns < width + 5
    Report('the terminal is too narrow for the minimap')
    return
  endif

  Highlights()
  try
    execute 'noautocmd botright vertical :' .. width .. 'new'
    var side = win_getid()
    t:vimbird = {win: side, buf: bufnr(), source: source, tiles: [0, 0], viewport: [],
      match: -1, overlay_match: -1, search_key: [], search_match: -1, search_rows: {}, marker_key: [], marker_matches: [],
      quickfix_key: [], quickfix_positions: [], git_key: [], git_generation: 0, git_job: null_job,
      git_pending: [], git_ranges: [], overview: false, dragging: false, page: 1, capacity: 0, page_buf: 0, opacity: -1, divider: 0, divider_key: []}
    setlocal buftype=nofile bufhidden=wipe nobuflisted noswapfile noundofile
    setlocal nowrap nolist nonumber norelativenumber nospell nofoldenable foldcolumn=0 conceallevel=0
    setlocal signcolumn=no nocursorline nocursorcolumn colorcolumn= winfixwidth nomodifiable
    setlocal wincolor=VimbirdBackground statusline=Vimbird
    matchadd('VimbirdPixels', '\%>1c.', 10)
    nnoremap <silent><buffer> <CR> <Cmd>call vimbird#Select()<CR>
    noautocmd win_gotoid(source)
    SetupEvents()
    Sync(true)
  catch
    Close()
    Report(v:exception)
  endtry
enddef

export def Close()
  var state = get(t:, 'vimbird', {})
  if empty(state)
    return
  endif
  unlet t:vimbird
  markers.Stop(state)
  Divider(state, false)
  if winbufnr(state.win) == state.buf
    if winnr('$') > 1
      win_execute(state.win, 'close')
    else
      win_execute(state.win, 'enew')
    endif
  endif
  Release()
enddef

export def Toggle()
  if exists('t:vimbird')
    Close()
  else
    Open()
  endif
enddef

export def Refresh()
  if exists('t:vimbird')
    try
      Highlights()
      RefreshMarkers()
      Sync(true)
    catch
      Close()
      Report(v:exception)
    endtry
  endif
enddef
